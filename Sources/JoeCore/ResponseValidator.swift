import Foundation

public struct ResponseValidation: Codable, Sendable, Equatable {
    public let reasons: [String]
    public var isAllowed: Bool { reasons.isEmpty }
}
/// Conservative regression-tested screening, not a proof of clinical correctness.
public struct ResponseValidator: Sendable {
    public static let version = "joe.response-validator.v7"
    public init() {}
    public func validate(_ text: String, userText: String, decision: SafetyDecision,
                         snapshot: AssistantSnapshot, evidence: Set<ToolKind>) -> ResponseValidation {
        var reasons: [String] = []
        let lower = text.lowercased(); let intent = QuestionIntent(userText)
        func has(_ words: [String]) -> Bool { words.contains(where: lower.contains) }
        func matches(_ pattern: String) -> Bool { lower.range(of: pattern, options: .regularExpression) != nil }
        let language = ReplyLanguage(text: userText)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { reasons.append("empty_response") }
        if ReplyLanguage(text: text) != language { reasons.append("language_mismatch") }
        let endings = (try? NSRegularExpression(pattern: "[.!?。！？]+(?:\\s|$)").numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))) ?? 0
        let dayQuery = intent.calendar && !intent.glucose && !intent.forecast && !intent.insulin && !intent.dose && snapshot.calendarDay != nil
        if !dayQuery && !evidence.contains(.history) && (endings > 2 || text.count > (language == .chinese ? 260 : 650)) { reasons.append("not_brief") }
        if text.contains("**") || text.contains("```") || text.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation }) { reasons.append("format_mismatch") }
        if matches("\\b(take|inject|give|administer|increase|decrease|adjust|set|deliver|use|add|reduce|consider|try)\\b.{0,55}\\b(insulin|units?|bolus|basal|pump|u)\\b") ||
            matches("(\u{5efa}\u{8bae}|\u{5e94}\u{8be5}|\u{9700}\u{8981}|\u{53ef}\u{4ee5}|\u{8bf7}|\u{8bd5}\u{8bd5}).{0,20}(\u{6ce8}\u{5c04}|\u{6253}|\u{589e}\u{52a0}|\u{51cf}\u{5c11}|\u{8c03}\u{6574}|\u{80f0}\u{5c9b}\u{7d20}|\u{57fa}\u{7840}\u{7387}|\u{6cf5})") ||
            matches("(\u{6ce8}\u{5c04}|\u{6253}|\u{8865}|\u{52a0}).{0,8}[0-9\u{4e00}\u{4e8c}\u{4e09}\u{56db}\u{4e94}\u{516d}\u{4e03}\u{516b}\u{4e5d}\u{5341}]+.{0,4}(\u{5355}\u{4f4d}|u)") { reasons.append("treatment_recommendation") }
        if dayQuery, let day = snapshot.calendarDay {
            if !evidence.contains(.context) { reasons.append("calendar_without_tool") }
            if day.scope != .today && !text.contains(day.rangeHeader) { reasons.append("calendar_range_omitted") }
            if day.scope == .thisWeek && has(["today's events", "calendar for today", "今天的日程", "今天的事件"]) { reasons.append("calendar_range_mismatch") }
            let canonical = day.response(language: language, at: snapshot.now).lowercased()
            if day.status != .available || day.events.isEmpty || !day.isValid(at: snapshot.now) { reasons.append("calendar_unavailable") }
            for event in day.events {
                let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !title.isEmpty && !lower.contains(title) { reasons.append("calendar_event_omitted") }
            }
            if day.events.contains(where: { $0.allDay }) && !has(["all day", "全天"]) { reasons.append("calendar_time_omitted") }
            let timePattern = #"\b[0-2]?[0-9]:[0-5][0-9]\b"#
            let regex = try! NSRegularExpression(pattern: timePattern)
            let expectedTimes = regex.matches(in: canonical, range: NSRange(canonical.startIndex..., in: canonical)).compactMap { Range($0.range, in: canonical).map { String(canonical[$0]) } }
            if expectedTimes.contains(where: { !lower.contains($0) }) { reasons.append("calendar_time_omitted") }
            let dateRegex = try! NSRegularExpression(pattern: #"\d{4}-\d{2}-\d{2}"#)
            let expectedDates = dateRegex.matches(in: canonical, range: NSRange(canonical.startIndex..., in: canonical)).compactMap { Range($0.range, in: canonical).map { String(canonical[$0]) } }
            if day.scope != .today && expectedDates.contains(where: { !lower.contains($0) }) { reasons.append("calendar_date_omitted") }
            if day.scope == .thisWeek || day.scope == .tomorrow {
                let date = DateFormatter(); date.locale = Locale(identifier: "en_US_POSIX"); date.timeZone = day.timeZone; date.dateFormat = "yyyy-MM-dd"
                let clock = DateFormatter(); clock.locale = date.locale; clock.timeZone = day.timeZone; clock.dateFormat = "HH:mm"
                for event in day.events {
                    let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let rows = lower.components(separatedBy: "\n").filter { $0.contains(title) }
                    let eventDate = date.string(from: max(day.dayStart, event.start))
                    if !rows.contains(where: { row in row.contains(eventDate) && (event.allDay ? (row.contains("all day") || row.contains("全天")) : row.contains(clock.string(from: event.start)) && row.contains(clock.string(from: event.end))) }) {
                        reasons.append("calendar_event_date_time_mismatch")
                    }
                }
            }
            let supported = Self.numbers(canonical)
            if Self.numbers(text).contains(where: { !supported.contains($0) }) { reasons.append("unsupported_calendar_number") }
            if has(["i can check", "i will check", "i'll check", "open your calendar", "我可以查看", "我会查看"]) { reasons.append("calendar_promise_only") }
        }
        if matches("(glucose|blood sugar).{0,80}(because|due to|caused by)") || matches("(caused|causes|made).{0,50}(glucose|blood sugar)") || has(["\u{5bfc}\u{81f4}", "\u{80af}\u{5b9a}\u{662f}", "\u{4e00}\u{5b9a}\u{662f}"]) { reasons.append("causal_claim") }
        let mentionsForecast = has(["forecast", "predict", "\u{9884}\u{6d4b}"])
        let mentionsGlucose = has(["glucose", "blood sugar", "mg/dl", "\u{8840}\u{7cd6}"])
        // All tool glucose values are mg/dL; never accept a different unit with the same number.
        if mentionsGlucose && (matches(#"\b(?:mmol|mg|g)\s*/\s*(?:l|ml)\b"#) ||
            has(["\u{6beb}\u{514b}/\u{5347}", "\u{6beb}\u{514b}\u{6bcf}\u{5347}", "\u{6beb}\u{6469}\u{5c14}"])) {
            reasons.append("unsupported_glucose_unit")
        }
        let mentionsInsulin = has(["bolus", "basal", "insulin", "iob", "cob", "\u{80f0}\u{5c9b}\u{7d20}", "\u{57fa}\u{7840}\u{7387}"])
        let contextAssertion = matches("your.{0,30}(steps|sleep|heart rate|calendar|event|workout)") || matches("you (are at|slept|walked|have a class)") || matches("\u{4f60}.{0,12}(\u{7761}\u{4e86}|\u{8d70}\u{4e86}|\u{6b65}\u{6570}|\u{5728}\u{5bb6}|\u{5728}\u{5b66}\u{6821}|\u{6709}\u{8bfe}|\u{5fc3}\u{7387})")
        if mentionsGlucose && !evidence.contains(.glucose) && !evidence.contains(.forecast) && !evidence.contains(.history) { reasons.append("glucose_without_tool") }
        if mentionsInsulin && !evidence.contains(.insulin) { reasons.append("insulin_without_tool") }
        if contextAssertion && !evidence.contains(.context) { reasons.append("context_without_tool") }
        let deniesAccess = has(["don't have access", "do not have access", "no access", "cannot access", "can't access", "permission denied", "not authorized", "没有权限", "无权访问", "无法访问", "未授权", "没有访问权限"])
        if deniesAccess && (intent.context || has(["calendar", "location", "日历", "位置"])) {
            // Empty data is not evidence of denied permission. Even with known denial, use app-authored status text.
            reasons.append("unverified_access_claim")
        }
        let cgm = snapshot.currentGlucose; let forecast = snapshot.forecastResult
        let unavailableWords = has(["unknown", "unavailable", "no current", "not current", "cannot", "can't", "no reading", "missing", "\u{672a}\u{77e5}", "\u{4e0d}\u{53ef}\u{7528}", "\u{6ca1}\u{6709}", "\u{4e0d}\u{80fd}", "\u{7f3a}\u{5931}"])
        if mentionsGlucose && cgm.status != .fresh && !mentionsForecast && !unavailableWords && !has(["stale", "historical", "last reading", "\u{8fc7}\u{671f}", "\u{5386}\u{53f2}", "\u{4e0a}\u{6b21}"]) { reasons.append("stale_or_missing_as_current") }
        if mentionsForecast {
            if !evidence.contains(.forecast) { reasons.append("forecast_without_tool") }
            if forecast.available {
                if !has(["uncertain", "uncertainty", "error", "±", "\u{4e0d}\u{786e}\u{5b9a}", "\u{8bef}\u{5dee}"]) { reasons.append("forecast_without_uncertainty") }
            } else if !unavailableWords { reasons.append("unavailable_forecast_claim") }
        }
        if has(["iob", "cob"]) && !unavailableWords { reasons.append("unvalidated_iob_cob") }
        if mentionsGlucose && !intent.glucose && !intent.forecast && !intent.insulin && !intent.history && decision == .normal { reasons.append("unsolicited_normal_glucose") }
        if (mentionsGlucose || mentionsInsulin || mentionsForecast || contextAssertion) &&
            matches("\\b(zero|one|two|three|four|five|six|seven|eight|nine|ten|hundred|thousand)\\b") {
            reasons.append("unverifiable_written_number")
        }
        if has(["risk", "probability", "chance"]) && forecast.hypoRisk60m == nil && !unavailableWords { reasons.append("uncalibrated_risk_claim") }
        if cgm.status == .fresh, let current = cgm.glucoseMgDl, !mentionsForecast {
            if matches("your (glucose|blood sugar) is (low|very low)") && current >= snapshot.policy.lowGlucose { reasons.append("unsupported_low_label") }
            if matches("your (glucose|blood sugar) is (high|very high)") && current <= snapshot.policy.highGlucose { reasons.append("unsupported_high_label") }
        }
        if evidence.contains(.glucose), !mentionsForecast, let direction = cgm.direction {
            if has(["rising", "increasing"]) && !direction.hasPrefix("Rising") { reasons.append("unsupported_trend") }
            if has(["falling", "dropping"]) && !direction.hasPrefix("Falling") { reasons.append("unsupported_trend") }
            if has(["steady", "stable"]) && direction != "Steady" { reasons.append("unsupported_trend") }
        }
        // Strip only complete, source-backed timestamp tokens before validating other numbers.
        // Date/time digits must never authorize a fabricated dose with the same digits.
        var timestampTokens: [String] = []
        if evidence.contains(.glucose) { timestampTokens += [cgm.sourceLocalTime].compactMap { $0 } }
        if evidence.contains(.insulin) { timestampTokens += [snapshot.recentInsulin.latestBolusLocalTime].compactMap { $0 } }
        if evidence.contains(.forecast) { timestampTokens += [forecast.sourceLocalTime, forecast.generatedLocalTime, forecast.prediction30mLocalTime, forecast.prediction60mLocalTime].compactMap { $0 } }
        if evidence.contains(.context) { timestampTokens += [snapshot.currentContext.observedLocalTime, snapshot.currentContext.nextEventLocalTime].compactMap { $0 } }
        if evidence.contains(.history), let h = snapshot.glucoseHistory { timestampTokens += [h.windowStartLocal, h.windowEndLocal, h.latestLocalTime, h.minimumLocalTime, h.maximumLocalTime] + h.daily.map(\.localDate) }
        var numericText = lower
        for token in timestampTokens.sorted(by: { $0.count > $1.count }) { numericText = numericText.replacingOccurrences(of: token.lowercased(), with: " ") }
        if !dayQuery && numericText.range(of: #"\b\d+:\d+(?::\d+)?\b|\b\d{4}-\d{2}-\d{2}\b"#, options: .regularExpression) != nil { reasons.append("unsupported_event_time") }
        if has(["minutes ago", "minute ago", "hours ago", "hour ago", "days ago", "day ago", "分钟前", "小时前", "天前"]) || matches(#"\b\d+\s*(?:minutes?|hours?|days?)\s+ago\b|\bin\s+\d+\s+(?:minutes?|hours?)\b|[0-9一二三四五六七八九十]+(?:分钟|小时|天)[前后]"#) { reasons.append("relative_event_time") }
        let asksWhen = ["when", "what time", "什么时候", "几点", "何时"].contains(where: userText.lowercased().contains)
        if asksWhen, evidence.contains(.insulin), let time = snapshot.recentInsulin.latestBolusLocalTime, !lower.contains(time.lowercased()) { reasons.append("event_time_omitted") }
        if asksWhen, evidence.contains(.glucose), !evidence.contains(.forecast), !evidence.contains(.insulin), let time = cgm.sourceLocalTime, !lower.contains(time.lowercased()) { reasons.append("event_time_omitted") }
        let doseRegex = try! NSRegularExpression(pattern: #"([0-9]+(?:\.[0-9]+)?)\s*(?:u\b|units?\b|单位)"#)
        if !evidence.contains(.insulin) && doseRegex.firstMatch(in: numericText, range: NSRange(numericText.startIndex..., in: numericText)) != nil { reasons.append("insulin_without_tool") }
        if evidence.contains(.insulin) {
            let supportedDoses = [snapshot.recentInsulin.latestBolusUnits, snapshot.recentInsulin.basalRate].compactMap { $0 }
            let doses = doseRegex.matches(in: numericText, range: NSRange(numericText.startIndex..., in: numericText)).compactMap { Range($0.range(at: 1), in: numericText).flatMap { Double(numericText[$0]) } }
            if doses.contains(where: { n in !supportedDoses.contains(where: { abs(n-$0) < 0.000000001 }) }) { reasons.append("unsupported_insulin_amount") }
        }
        let numbers = Self.numbers(dayQuery ? text : numericText)
        var supported: [Double] = []
        if dayQuery, evidence.contains(.context), let day = snapshot.calendarDay {
            supported += Self.numbers(day.response(language: language, at: snapshot.now))
        }
        if evidence.contains(.history), let h = snapshot.glucoseHistory {
            supported += h.supportedNumbers
            if !has(["historical", "history", "delayed", "历史", "延迟"]) { reasons.append("history_without_delay_label") }
            if has(["right now", "currently", "当前血糖", "现在血糖", "time in range", "达标时间"]) { reasons.append("history_as_current_or_time_weighted") }
        }
        if evidence.contains(.glucose) { supported += [cgm.glucoseMgDl, cgm.ageMinutes.map(Double.init)].compactMap { $0 } }
        if evidence.contains(.forecast), forecast.available {
            supported += [forecast.predicted30m, forecast.predicted60m, forecast.uncertainty30m, forecast.uncertainty60m,
                          forecast.hypoRisk60m].compactMap { $0 }; supported += [30, 60, 90]
        }
        if evidence.contains(.insulin) {
            let i = snapshot.recentInsulin
            supported += [i.latestBolusUnits, i.basalRate, i.dataAgeMinutes.map(Double.init)].compactMap { $0 }
        }
        if evidence.contains(.context) {
            let c = snapshot.currentContext
            supported += [c.stepsLast30m, c.heartRate, c.sleepHoursLastNight, c.minutesUntilNextEvent.map(Double.init)].compactMap { $0 }
            supported.append(30)
        }
        if numbers.contains(where: { number in !supported.contains(where: { abs($0-number) <= 0.11 }) }) { reasons.append("unsupported_number") }
        if mentionsForecast && has(["current glucose", "glucose right now", "currently", "\u{5f53}\u{524d}\u{8840}\u{7cd6}", "\u{73b0}\u{5728}\u{8840}\u{7cd6}"]),
           let current = cgm.glucoseMgDl {
            let futureValues = [forecast.predicted30m, forecast.predicted60m].compactMap { $0 }.filter { abs($0-current) > 0.11 }
            if numbers.contains(where: { n in futureValues.contains(where: { abs(n-$0) <= 0.11 }) }) { reasons.append("prediction_as_current") }
        }
        return ResponseValidation(reasons: Array(Set(reasons)).sorted())
    }
    public static func numbers(_ text: String) -> [Double] {
        let regex = try! NSRegularExpression(pattern: "[0-9]+(?:\\.[0-9]+)?")
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range, in: text).flatMap { Double(text[$0]) }
        }
    }
}
