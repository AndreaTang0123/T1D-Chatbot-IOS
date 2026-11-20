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
    struct CalendarOption: Identifiable {
        let id: String
        let title: String
        let account: String
    }
    var availableCalendars: [CalendarOption] {
        guard hasAccess else { return [] }
        return store.calendars(for: .event).map {
            CalendarOption(id: $0.calendarIdentifier, title: $0.title, account: $0.source?.title ?? "Local")
        }.sorted { ($0.account, $0.title, $0.id) < ($1.account, $1.title, $1.id) }
    }
    private var selectedIDs: Set<String>? {
        guard let data = UserDefaults.standard.string(forKey: "selectedCalendarIDs")?.data(using: .utf8) else { return nil }
        return (try? JSONDecoder().decode([String].self, from: data)).map { Set($0) }
    }
    func isSelected(_ id: String) -> Bool { selectedIDs?.contains(id) ?? true }
    func setSelected(_ id: String, enabled: Bool) {
        var ids = selectedIDs ?? Set(availableCalendars.map(\.id))
        if enabled { ids.insert(id) } else { ids.remove(id) }
        if let data = try? JSONEncoder().encode(ids.sorted()), let json = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(json, forKey: "selectedCalendarIDs")
        }
    }
    private var selectedCalendars: [EKCalendar] {
        guard hasAccess else { return [] }
        return store.calendars(for: .event).filter { isSelected($0.calendarIdentifier) }
    }
    var sourceStatus: String {
        guard enabled else { return "Calendar collection is off." }
        guard hasAccess else { return "Full calendar access is required." }
        let calendars = selectedCalendars
        return calendars.isEmpty ? "No calendars selected or available. Select calendars below and check account sync." : "Selected calendars: " + calendars.map { "\($0.title) (\($0.source?.title ?? "Local"))" }.sorted().joined(separator: ", ")
    }
    func authorize() async throws -> Bool {
        let allowed = try await store.requestFullAccessToEvents()
        UserDefaults.standard.set(allowed, forKey: "calendarEnabled")
        return allowed
    }
    func daySchedule(at now: Date, question: String) -> CalendarDayResult {
        let range = CalendarQueryRange(question: question, now: now)
        func result(_ status: CalendarDayResult.Status, _ events: [CalendarDayEvent] = []) -> CalendarDayResult {
            CalendarDayResult(status: status, dayStart: range.start, dayEnd: range.end, timeZone: range.timeZone, events: events, scope: range.scope, queriedAt: now)
        }
        guard range.scope != .unsupported else { return result(.unsupportedRange) }
        guard enabled else { return result(.collectionDisabled) }
        guard hasAccess else { return result(.notAuthorized) }
        // Refresh EventKit’s local cache before each explicit query (accounts may have synced since launch).
        store.reset()
        let calendars = selectedCalendars
        guard !calendars.isEmpty else { return result(availableCalendars.isEmpty ? .noCalendars : .noSelectedCalendars) }
        let predicate = store.predicateForEvents(withStart: range.start, end: range.end, calendars: calendars)
        // EventKit's synchronous query has no error callback. Empty means no visible local events, not proof of server coverage.
        let events = store.events(matching: predicate).filter { $0.status != .canceled }.map {
            CalendarDayEvent(title: $0.title ?? "", start: $0.startDate, end: $0.endDate, allDay: $0.isAllDay)
        }
        guard hasAccess else { return result(.notAuthorized) }
        return result(.available, events)
    }
    func snapshot(at now: Date) -> Snapshot {
        guard enabled, EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return Snapshot() }
        let calendars = selectedCalendars
        guard !calendars.isEmpty else { return Snapshot() }
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-3600), end: now.addingTimeInterval(6*3600), calendars: calendars)
        let events = store.events(matching: predicate).filter { !$0.isAllDay && $0.status != .canceled }.sorted { $0.startDate < $1.startDate }
        let current = events.first { $0.startDate <= now && $0.endDate > now }
        let next = events.first { $0.startDate > now }
        return Snapshot(current: current.map { ContextClassifier.calendarCategory($0.title ?? "") },
                        next: next.map { ContextClassifier.calendarCategory($0.title ?? "") },
                        nextStart: next?.startDate, currentEnd: current?.endDate)
    }
}
