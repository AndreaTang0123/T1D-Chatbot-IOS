import Foundation

public enum CalendarReplyStyle {
    public static func wantsCompleteList(_ question: String) -> Bool {
        let s = question.lowercased()
        return ["list all", "all events", "every event", "full list", "complete list", "full schedule", "full calendar", "everything on my calendar", "全部", "所有", "完整", "逐条"].contains(where: s.contains)
    }
    public static func dayLabels(_ day: CalendarDayResult) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = day.timeZone; formatter.dateFormat = "yyyy-MM-dd EEEE"
        return Set(day.events.map { formatter.string(from: $0.start) }).sorted().joined(separator: "; ")
    }
    public static func highlightFacts(_ day: CalendarDayResult, language: ReplyLanguage) -> String {
        let date = DateFormatter(); date.locale = Locale(identifier: "en_US_POSIX"); date.timeZone = day.timeZone; date.dateFormat = "yyyy-MM-dd"
        let clock = DateFormatter(); clock.locale = date.locale; clock.timeZone = day.timeZone; clock.dateFormat = "HH:mm"
        let zh = language == .chinese
        let scope: String
        switch day.scope {
        case .thisWeek: scope = (zh ? "本周" : "This week") + " (" + date.string(from: day.dayStart) + " through " + date.string(from: day.dayEnd.addingTimeInterval(-1)) + "). "
        case .tomorrow: scope = zh ? "明天，" : "Tomorrow, "
        default: scope = zh ? "今天，" : "Today, "
        }
        let timed = day.events.filter { !$0.allDay }
        let highlights = Array((timed.isEmpty ? day.events : timed).prefix(2))
        let facts = highlights.map { event in
            let eventDate = day.scope == .today ? "" : date.string(from: event.start) + " "
            let when = event.allDay ? (zh ? "全天" : "All day") : clock.string(from: event.start)
            let title = event.title.isEmpty ? (zh ? "无标题事件" : "Untitled event") : event.title
            return eventDate + title + (zh ? "，时间为" : " at ") + when + (zh ? "。" : ". ")
        }.joined()
        return scope + facts
    }

}
/// EventKit has no dedicated modern iCloud-provider flag. Unknown CalDAV accounts fail closed.
public enum ICloudCalendarScope {
    public static func includes(sourceType: String, title: String) -> Bool {
        sourceType == "mobileMe" || (sourceType == "calDAV" && title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "icloud")
    }
}

/// Highlights may omit events, but each named event must retain its actual local start/date.
public enum CalendarOverviewValidation {
    public static func reasons(text: String, day: CalendarDayResult) -> [String] {
        let lower = text.lowercased()
        let date = DateFormatter(); date.locale = Locale(identifier: "en_US_POSIX"); date.timeZone = day.timeZone; date.dateFormat = "yyyy-MM-dd"
        let clock = DateFormatter(); clock.locale = date.locale; clock.timeZone = day.timeZone; clock.dateFormat = "HH:mm"
        var reasons: [String] = []
        if day.scope == .thisWeek {
            let bounds = [date.string(from: day.dayStart), date.string(from: day.dayEnd.addingTimeInterval(-1))]
            if !bounds.allSatisfy(lower.contains) { reasons.append("calendar_range_omitted") }
        }
        if day.scope == .tomorrow && !["tomorrow", "明天", day.rangeHeader.lowercased()].contains(where: lower.contains) { reasons.append("calendar_range_omitted") }
        let groups = Dictionary(grouping: day.events, by: { event in
            let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return title.isEmpty ? (ReplyLanguage(text: text) == .chinese ? "无标题事件" : "untitled event") : title
        })
        let titles = groups.keys.filter { !$0.isEmpty && lower.contains($0) }
        if titles.isEmpty { reasons.append("calendar_event_omitted") }
        let sentences = lower.components(separatedBy: .newlines).flatMap { $0.components(separatedBy: ". ") }.flatMap { $0.components(separatedBy: "。") }
        for title in titles {
            let events = groups[title] ?? []
            let clauses = sentences.filter { $0.contains(title) }.filter { clause in
                // A later interpretation can refer to the same event without repeating its time.
                clause.range(of: #"(?<![0-9])[0-2]?[0-9]:[0-5][0-9](?![0-9])"#, options: .regularExpression) != nil || clause.contains("all day") || clause.contains("全天")
            }
            let valid = !clauses.isEmpty && clauses.allSatisfy { clause in
                // Separate sentences avoid accidentally authorizing swapped times in two highlighted events.
                let otherTitles = titles.filter { $0 != title && clause.contains($0) }
                let fact: String
                if !otherTitles.isEmpty, let titleRange = clause.range(of: title) {
                    let suffix = clause[titleRange.lowerBound...]
                    let end = otherTitles.compactMap { suffix.range(of: $0)?.lowerBound }.min() ?? suffix.endIndex
                    fact = String(suffix[..<end])
                } else { fact = clause }
                return events.contains { event in
                    let datePattern = try! NSRegularExpression(pattern: #"\d{4}-\d{2}-\d{2}"#)
                    let titleStart = fact.range(of: title)?.lowerBound ?? fact.startIndex
                    let prefix = String(fact[..<titleStart])
                    let precedingDate = datePattern.matches(in: prefix, range: NSRange(prefix.startIndex..., in: prefix)).last.flatMap { Range($0.range, in: prefix).map { String(prefix[$0]) } }
                    let suffix = String(fact[titleStart...])
                    let followingDate = datePattern.firstMatch(in: suffix, range: NSRange(suffix.startIndex..., in: suffix)).flatMap { Range($0.range, in: suffix).map { String(suffix[$0]) } }
                    let dayMatches = day.scope == .today || (precedingDate ?? followingDate) == date.string(from: event.start)
                    let timeMatches = event.allDay ? fact.contains("all day") || fact.contains("全天") : fact.contains(clock.string(from: event.start))
                    return dayMatches && timeMatches
                }
            }
            if !valid { reasons.append("calendar_event_date_time_mismatch") }
        }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = day.timeZone
        let weekdays = Set(day.events.map { calendar.component(.weekday, from: $0.start) })
        // Day-of-week claims are facts, not subjective schedule interpretation.
        let weekdayWords: [(Int, [String])] = [(1, ["sunday", "周日", "星期日", "星期天"]), (2, ["monday", "周一", "星期一"]), (3, ["tuesday", "周二", "星期二"]), (4, ["wednesday", "周三", "星期三"]), (5, ["thursday", "周四", "星期四"]), (6, ["friday", "周五", "星期五"]), (7, ["saturday", "周六", "星期六"])]
        var interpretation = lower
        for title in groups.keys where !title.isEmpty { interpretation = interpretation.replacingOccurrences(of: title, with: " ") }
        if !weekdays.contains(1) && !weekdays.contains(7) && ["weekend", "周末"].contains(where: interpretation.contains) { reasons.append("calendar_unsupported_weekday") }
        for (weekday, words) in weekdayWords where !weekdays.contains(weekday) {
            if words.contains(where: interpretation.contains) { reasons.append("calendar_unsupported_weekday") }
        }
        if ["nothing else", "no other commitments", "rest of your day is free", "其他时间都空闲", "没有其他安排"].contains(where: lower.contains) { reasons.append("calendar_unverified_free_time") }
        return reasons
    }
}
