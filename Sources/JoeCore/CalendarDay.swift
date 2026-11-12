import Foundation

public struct CalendarDayEvent: Codable, Sendable, Equatable {
    public let title: String
    public let start: Date
    public let end: Date
    public let allDay: Bool
    public init(title: String, start: Date, end: Date, allDay: Bool = false) {
        self.title = title.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        self.start = start; self.end = end; self.allDay = allDay
    }
}
public struct CalendarQueryRange: Sendable {
    public enum Scope: String, Codable, Sendable { case today, tomorrow, thisWeek, unsupported }
    public let scope: Scope
    public let start: Date
    public let end: Date
    public let queriedAt: Date
    public let timeZone: TimeZone
    public init(question: String, now: Date, timeZone: TimeZone = .current) {
        self.queriedAt = now; self.timeZone = timeZone
        let text = question.lowercased()
        let today = text.contains("today") || text.contains("今天")
        let tomorrow = text.contains("tomorrow") || text.contains("明天")
        let week = text.contains("this week") || text.contains("本周") || text.contains("这周") || text.contains("本星期") || text.contains("这星期")
        let excluded = ["coming week", "upcoming week", "remaining", "rest of", "剩余", "剩下", "未来", "过去", "yesterday", "next week", "last week", "next 7", "next seven", "month", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "昨天", "后天", "下周", "下星期", "上周", "上星期", "这个月", "下个月", "周一", "周二", "周三", "周四", "周五", "周六", "周日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日", "weekend", "周末", "january", "february", "march", "april", "june", "july", "august", "september", "october", "november", "december"]
        let explicitDate = text.range(of: #"\d{4}[-/]\d{1,2}[-/]\d{1,2}|\d{1,2}/\d{1,2}|\d+月|\b\d{4}\b|\b\d{1,2}(?:st|nd|rd|th)\b"#, options: .regularExpression) != nil
        let rangeText = text.replacingOccurrences(of: "日历", with: "calendar").replacingOccurrences(of: "日程", with: "schedule")
        if excluded.contains(where: rangeText.contains) || explicitDate || [today, tomorrow, week].filter({ $0 }).count > 1 { scope = .unsupported }
        else if today { scope = .today }
        else if tomorrow { scope = .tomorrow }
        else { scope = .thisWeek }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        cal.firstWeekday = 2; cal.minimumDaysInFirstWeek = 4
        let day = cal.startOfDay(for: now)
        switch scope {
        case .thisWeek:
            let monday = cal.date(byAdding: .day, value: -((cal.component(.weekday, from: day) + 5) % 7), to: day)!
            start = monday; end = cal.date(byAdding: .day, value: 7, to: monday)!
        case .tomorrow:
            start = cal.date(byAdding: .day, value: 1, to: day)!
            end = cal.date(byAdding: .day, value: 2, to: day)!
        case .today, .unsupported:
            start = day; end = cal.date(byAdding: .day, value: 1, to: day)!
        }
    }
}

/// Transient, explicitly requested day query; titles enter local model prompts only for an explicit calendar request, never lifestyle feature records.
public struct CalendarDayResult: Codable, Sendable {
    public enum Status: String, Codable, Sendable { case available, collectionDisabled, notAuthorized, failed, unsupportedRange }
    public let scope: CalendarQueryRange.Scope
    public let queriedAt: Date?
    public let status: Status
    public let dayStart: Date
    public let dayEnd: Date
    public let timeZone: TimeZone
    public let events: [CalendarDayEvent]
    public init(status: Status, dayStart: Date, dayEnd: Date, timeZone: TimeZone, events: [CalendarDayEvent] = [], scope: CalendarQueryRange.Scope = .today, queriedAt: Date? = nil) {
        self.scope = scope; self.queriedAt = queriedAt
        self.status = status; self.dayStart = dayStart; self.dayEnd = dayEnd; self.timeZone = timeZone
        self.events = events.filter { $0.start < dayEnd && $0.end > dayStart }
            .sorted { $0.start == $1.start ? $0.title < $1.title : $0.start < $1.start }
    }
    public func isValid(at now: Date) -> Bool {
        guard let queriedAt else { return dayStart <= now && now < dayEnd }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        return now >= queriedAt && now.timeIntervalSince(queriedAt) <= 900 && cal.isDate(queriedAt, inSameDayAs: now)
    }
    public var rangeHeader: String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = timeZone; f.dateFormat = "yyyy-MM-dd"
        return "Calendar range: \(f.string(from: dayStart)) through \(f.string(from: dayEnd.addingTimeInterval(-1))) (\(timeZone.identifier))"
    }
    public func response(language: ReplyLanguage, at now: Date) -> String {
        let zh = language == .chinese
        switch status {
        case .collectionDisabled: return zh ? "Joe 的日历采集开关已关闭。请在 app 的 Settings 中开启后重试。" : "Calendar collection is off in Joe. Turn it on in the app's Settings and retry."
        case .notAuthorized: return zh ? "iOS 未授予完整日历读取权限。请在系统设置中允许 Joe 访问日历后重试。" : "iOS has not granted full calendar read access. Allow Joe calendar access in iPhone Settings and retry."
        case .unsupportedRange: return zh ? "请明确选择本周、今天或明天；暂不支持其他日期范围，我不会用本周的数据替代。" : "Please choose this week, today or tomorrow. Other or conflicting date ranges are not supported; I will not substitute this week’s events."
        case .failed: return zh ? "这次日历读取失败，请重试。无法判断所选范围内是否有事件。" : "The calendar could not be read. Please retry; this does not mean the requested range has no events."
        case .available: break
        }
        guard isValid(at: now) else { return zh ? "日历查询已过期，请重新查询所需日期范围。" : "This calendar result is from another day or has expired. Ask again to refresh the requested range." }
        guard !events.isEmpty else { return rangeHeader + "\n" + (zh ? "该范围内的可读取日历中没有事件；这不代表账户已经完整同步。" : "No events are visible in this range; this does not prove account sync is complete.") }
        let date = DateFormatter(); date.locale = Locale(identifier: zh ? "zh_CN" : "en_US")
        date.timeZone = timeZone; date.dateStyle = .medium; date.timeStyle = .none
        let time = DateFormatter(); time.locale = date.locale; time.timeZone = timeZone; time.dateFormat = "HH:mm"
        date.dateFormat = "yyyy-MM-dd"
        let header = (zh ? "所选范围的日程：\n" : "Events in the requested range:\n") + rangeHeader
        let rows = events.map { event -> String in
            let when: String
            if event.allDay {
                let endDate = date.string(from: min(event.end, dayEnd).addingTimeInterval(-1))
                let startDate = date.string(from: max(event.start, dayStart))
                when = (zh ? "全天" : "All day") + (startDate == endDate ? "" : " through " + endDate)
            }
            else {
                let start = event.start < dayStart ? "previous day " + date.string(from: event.start) + " " + time.string(from: event.start) : time.string(from: event.start)
                let end = date.string(from: event.end) == date.string(from: event.start) ? time.string(from: event.end) : date.string(from: event.end) + " " + time.string(from: event.end)
                when = "\(start)–\(end)"
            }
            let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return "• \(date.string(from: max(event.start, dayStart))) \(when) — \(title.isEmpty ? (zh ? "无标题事件" : "Untitled event") : title)"
        }
        return ([header] + rows).joined(separator: "\n")
    }
}
