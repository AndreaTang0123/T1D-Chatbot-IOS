import XCTest
@testable import JoeCore

final class CalendarNarrativeTests: XCTestCase {
    let now = ISO8601DateFormatter().date(from: "2026-11-16T12:00:00Z")!
    func day() -> CalendarDayResult {
        let r = CalendarQueryRange(question: "calendar today", now: now, timeZone: TimeZone(secondsFromGMT: 0)!)
        return CalendarDayResult(status: .available, dayStart: r.start, dayEnd: r.end, timeZone: r.timeZone, events: [
            CalendarDayEvent(title: "Morning meeting", start: r.start.addingTimeInterval(9*3600), end: r.start.addingTimeInterval(10*3600)),
            CalendarDayEvent(title: "Afternoon class", start: r.start.addingTimeInterval(15*3600), end: r.start.addingTimeInterval(16*3600)),
            CalendarDayEvent(title: "Dinner", start: r.start.addingTimeInterval(18*3600), end: r.start.addingTimeInterval(19*3600))], queriedAt: now)
    }
    func validation(_ text: String, question: String = "What's on my calendar today?") -> ResponseValidation {
        let s = AssistantSnapshot(glucose: nil, forecast: nil, treatments: [], context: nil, now: now, calendarDay: day())
        return ResponseValidator().validate(text, userText: question, decision: .noData, snapshot: s, evidence: [.context])
    }
    func testConversationalHighlightsMayOmitOtherEventsAndAddTentativeInterpretation() {
        let text = "You have Morning meeting at 09:00. Afternoon class starts at 15:00. From the recorded events, it looks fairly light. What's on your mind?"
        XCTAssertTrue(validation(text).isAllowed, validation(text).reasons.description)
        XCTAssertTrue(validation(text, question: "List all calendar events today").reasons.contains("calendar_event_omitted"))
    }
    func testChineseTimeAdjacentToTextIsNotMistakenForMissingTime() {
        let text = "今天，Morning meeting 在09:00到10:00，Afternoon class 在15:00到16:00。看起来日程比较分散，你现在有什么想聊的吗？"
        XCTAssertTrue(validation(text, question: "今天我的日程怎么样？").isAllowed)
    }
    func testSwappedTimesOrUnsupportedFreeTimeClaimAreRejected() {
        XCTAssertTrue(validation("Morning meeting at 15:00. Afternoon class at 09:00.").reasons.contains("calendar_event_date_time_mismatch"))
        XCTAssertTrue(validation("Morning meeting at 09:00 and Afternoon class at 15:00. No other commitments.").reasons.contains("calendar_unverified_free_time"))
        XCTAssertTrue(validation("I can check your calendar.").reasons.contains("calendar_event_omitted"))
    }
    func testFullListPreservesAllFactsAndInterpretationCanFollow() {
        let text = day().response(language: .english, at: now) + "\nFrom the recorded events, you have several commitments. What's on your mind?"
        XCTAssertTrue(validation(text, question: "List all calendar events today").isAllowed)
    }
    func testWeeklyOverviewKeepsBoundsAndDatesWithoutTechnicalHeader() {
        let range = CalendarQueryRange(question: "calendar this week", now: now, timeZone: TimeZone(secondsFromGMT: 0)!)
        let d = CalendarDayResult(status: .available, dayStart: range.start, dayEnd: range.end, timeZone: range.timeZone,
            events: day().events, scope: .thisWeek, queriedAt: now)
        let s = AssistantSnapshot(glucose: nil, forecast: nil, treatments: [], context: nil, now: now, calendarDay: d)
        let valid = "This week (2026-11-16 through 2026-11-22), highlights include 2026-11-16 Morning meeting at 09:00. From the recorded events, it looks fairly spaced out. What's on your mind?"
        let v = ResponseValidator()
        XCTAssertTrue(v.validate(valid, userText: "calendar this week", decision: .noData, snapshot: s, evidence: [.context]).isAllowed)
        XCTAssertTrue(v.validate(valid.replacingOccurrences(of: "2026-11-16 Morning", with: "2026-11-17 Morning"), userText: "calendar this week", decision: .noData, snapshot: s, evidence: [.context]).reasons.contains("calendar_event_date_time_mismatch"))
    }
    func testInterpretationCannotTurnMondayIntoWeekend() {
        let text = "Morning meeting at 09:00. It looks like a fairly light weekend."
        XCTAssertTrue(validation(text).reasons.contains("calendar_unsupported_weekday"))
        XCTAssertFalse(validation("Morning meeting at 09:00. From the recorded events, Monday looks structured.").reasons.contains("calendar_unsupported_weekday"))
    }
    func testICloudScopeRejectsOtherAccountsAndUnknownCalDAVSources() {
        XCTAssertTrue(ICloudCalendarScope.includes(sourceType: "calDAV", title: "iCloud"))
        XCTAssertTrue(ICloudCalendarScope.includes(sourceType: "mobileMe", title: "Legacy Apple"))
        for type in ["local", "exchange", "subscribed", "birthdays", "other"] {
            XCTAssertFalse(ICloudCalendarScope.includes(sourceType: type, title: "iCloud"))
        }
        for title in ["Google", "Work", "My iCloud backup", "", "Andrea@example.com"] {
            XCTAssertFalse(ICloudCalendarScope.includes(sourceType: "calDAV", title: title))
        }
    }
    func testNoICloudSourceIsDifferentFromAnEmptySchedule() {
        let d = day()
        let unavailable = CalendarDayResult(status: .noICloudCalendars, dayStart: d.dayStart, dayEnd: d.dayEnd, timeZone: d.timeZone)
        let text = unavailable.response(language: .english, at: now)
        XCTAssertTrue(text.contains("No identifiable iCloud")); XCTAssertFalse(text.contains("No events"))
    }
}
