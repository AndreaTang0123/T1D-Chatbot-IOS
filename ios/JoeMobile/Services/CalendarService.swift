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
