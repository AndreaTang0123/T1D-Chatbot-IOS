import Foundation

public struct ResponseValidation: Codable, Sendable, Equatable {
    public let reasons: [String]
    public var isAllowed: Bool { reasons.isEmpty }
}
/// Conservative regression-tested screening, not a proof of clinical correctness.
public struct ResponseValidator: Sendable {
    public static let version = "joe.response-validator.v2"
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
        if endings > 2 || text.count > (language == .chinese ? 260 : 650) { reasons.append("not_brief") }
        if text.contains("**") || text.contains("```") || text.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation }) { reasons.append("format_mismatch") }
        if matches("\\b(take|inject|give|administer|increase|decrease|adjust|set|deliver|use|add|reduce|consider|try)\\b.{0,55}\\b(insulin|units?|bolus|basal|pump|u)\\b") ||
            matches("(\u{5efa}\u{8bae}|\u{5e94}\u{8be5}|\u{9700}\u{8981}|\u{53ef}\u{4ee5}|\u{8bf7}|\u{8bd5}\u{8bd5}).{0,20}(\u{6ce8}\u{5c04}|\u{6253}|\u{589e}\u{52a0}|\u{51cf}\u{5c11}|\u{8c03}\u{6574}|\u{80f0}\u{5c9b}\u{7d20}|\u{57fa}\u{7840}\u{7387}|\u{6cf5})") ||
            matches("(\u{6ce8}\u{5c04}|\u{6253}|\u{8865}|\u{52a0}).{0,8}[0-9\u{4e00}\u{4e8c}\u{4e09}\u{56db}\u{4e94}\u{516d}\u{4e03}\u{516b}\u{4e5d}\u{5341}]+.{0,4}(\u{5355}\u{4f4d}|u)") { reasons.append("treatment_recommendation") }
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
        if mentionsGlucose && !evidence.contains(.glucose) && !evidence.contains(.forecast) { reasons.append("glucose_without_tool") }
        if mentionsInsulin && !evidence.contains(.insulin) { reasons.append("insulin_without_tool") }
        if contextAssertion && !evidence.contains(.context) { reasons.append("context_without_tool") }
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
        if mentionsGlucose && !intent.glucose && !intent.forecast && !intent.insulin && decision == .normal { reasons.append("unsolicited_normal_glucose") }
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
        let numbers = Self.numbers(text)
        var supported: [Double] = []
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
