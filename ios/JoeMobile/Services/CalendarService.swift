import Foundation
import EventKit
import JoeCore

@MainActor final class CalendarService {
    private let store = EKEventStore()
    var hasAccess: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    var enabled: Bool { UserDefaults.standard.bool(forKey: "calendarEnabled") }
    struct Snapshot {
        var current: String?
        var next: String?
        var nextStart: Date?
        var currentEnd: Date?
    }
    func authorize() async throws -> Bool {
        let allowed = try await store.requestFullAccessToEvents()
        UserDefaults.standard.set(allowed, forKey: "calendarEnabled")
        return allowed
    }
    func daySchedule(at now: Date) -> CalendarDayResult {
        let calendar = Calendar.current
        guard let day = calendar.dateInterval(of: .day, for: now) else {
            return CalendarDayResult(status: .failed, dayStart: now, dayEnd: now, timeZone: calendar.timeZone)
        }
        func result(_ status: CalendarDayResult.Status, _ events: [CalendarDayEvent] = []) -> CalendarDayResult {
            CalendarDayResult(status: status, dayStart: day.start, dayEnd: day.end, timeZone: calendar.timeZone, events: events)
        }
        guard enabled else { return result(.collectionDisabled) }
        guard hasAccess else { return result(.notAuthorized) }
        let predicate = store.predicateForEvents(withStart: day.start, end: day.end, calendars: nil)
        // EventKit's synchronous query has no error callback. Empty means no visible local events, not proof of server coverage.
        let events = store.events(matching: predicate).filter { $0.status != .canceled }.map {
            CalendarDayEvent(title: $0.title ?? "", start: $0.startDate, end: $0.endDate, allDay: $0.isAllDay)
        }
        guard hasAccess else { return result(.notAuthorized) }
        return result(.available, events)
    }
    func snapshot(at now: Date) -> Snapshot {
        guard enabled, EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return Snapshot() }
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-3600), end: now.addingTimeInterval(6*3600), calendars: nil)
        let events = store.events(matching: predicate).filter { !$0.isAllDay }.sorted { $0.startDate < $1.startDate }
        let current = events.first { $0.startDate <= now && $0.endDate > now }
        let next = events.first { $0.startDate > now }
        return Snapshot(current: current.map { ContextClassifier.calendarCategory($0.title ?? "") },
                        next: next.map { ContextClassifier.calendarCategory($0.title ?? "") },
                        nextStart: next?.startDate, currentEnd: current?.endDate)
    }
}
