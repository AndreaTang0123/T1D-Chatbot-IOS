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
/// Transient, explicitly requested day query; titles enter local model prompts only for an explicit calendar request, never lifestyle feature records.
public struct CalendarDayResult: Codable, Sendable {
    public enum Status: String, Codable, Sendable { case available, collectionDisabled, notAuthorized, failed }
    public let status: Status
    public let dayStart: Date
    public let dayEnd: Date
    public let timeZone: TimeZone
    public let events: [CalendarDayEvent]
    public init(status: Status, dayStart: Date, dayEnd: Date, timeZone: TimeZone, events: [CalendarDayEvent] = []) {
        self.status = status; self.dayStart = dayStart; self.dayEnd = dayEnd; self.timeZone = timeZone
        self.events = events.filter { $0.start < dayEnd && $0.end > dayStart }
            .sorted { $0.start == $1.start ? $0.title < $1.title : $0.start < $1.start }
    }
    public func response(language: ReplyLanguage, at now: Date) -> String {
        let zh = language == .chinese
        switch status {
        case .collectionDisabled: return zh ? "Joe 的日历采集开关已关闭。请在 app 的 Settings 中开启后重试。" : "Calendar collection is off in Joe. Turn it on in the app's Settings and retry."
        case .notAuthorized: return zh ? "iOS 未授予完整日历读取权限。请在系统设置中允许 Joe 访问日历后重试。" : "iOS has not granted full calendar read access. Allow Joe calendar access in iPhone Settings and retry."
        case .failed: return zh ? "这次日历读取失败，请重试。无法判断今天是否有事件。" : "The calendar could not be read. Please retry; this does not mean today has no events."
        case .available: break
        }
        guard dayStart <= now, now < dayEnd else { return zh ? "日历查询已跨日，请重新查询今天的日程。" : "This calendar result is from another day. Ask again to refresh today's events." }
        guard !events.isEmpty else { return zh ? "今天的可读取日历中没有事件。若系统日历有事件，请检查日历账户是否已同步到这台 iPhone。" : "No events are visible in today's calendars. If you expect events, check that the calendar account has synced to this iPhone." }
        let date = DateFormatter(); date.locale = Locale(identifier: zh ? "zh_CN" : "en_US")
        date.timeZone = timeZone; date.dateStyle = .medium; date.timeStyle = .none
        let time = DateFormatter(); time.locale = date.locale; time.timeZone = timeZone; time.dateFormat = "HH:mm"
        let header = zh ? "今天的日程（\(date.string(from: dayStart))，\(timeZone.identifier)）：" : "Today's events (\(date.string(from: dayStart)), \(timeZone.identifier)):"
        let rows = events.map { event -> String in
            let when: String
            if event.allDay { when = zh ? "全天" : "All day" }
            else {
                let start = event.start < dayStart ? (zh ? "前一天" : "previous day") : time.string(from: event.start)
                let end = event.end >= dayEnd ? (zh ? "次日" : "next day") : time.string(from: event.end)
                when = "\(start)–\(end)"
            }
            let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return "• \(when) — \(title.isEmpty ? (zh ? "无标题事件" : "Untitled event") : title)"
        }
        return ([header] + rows).joined(separator: "\n")
    }
}
