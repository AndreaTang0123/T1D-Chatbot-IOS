import XCTest
@testable import JoeCore

final class CalendarDayTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    func result(_ status: CalendarDayResult.Status = .available, events: [CalendarDayEvent] = []) -> CalendarDayResult {
        CalendarDayResult(status: status, dayStart: start, dayEnd: start.addingTimeInterval(86400), timeZone: TimeZone(secondsFromGMT: 0)!, events: events)
    }
    func testEventsAreFilteredSortedAndRenderedWithoutModel() {
        let events = [CalendarDayEvent(title: "Evening class", start: start.addingTimeInterval(7200), end: start.addingTimeInterval(8000)),
                      CalendarDayEvent(title: "Holiday", start: start, end: start.addingTimeInterval(86400), allDay: true),
                      CalendarDayEvent(title: "Outside", start: start.addingTimeInterval(86400), end: start.addingTimeInterval(90000)),
                      CalendarDayEvent(title: "Ended yesterday", start: start.addingTimeInterval(-3600), end: start)]
        let day = result(events: events)
        XCTAssertEqual(day.events.map(\.title), ["Holiday", "Evening class"])
        let text = day.response(language: .english, at: start.addingTimeInterval(1))
        XCTAssertTrue(text.contains("All day")); XCTAssertTrue(text.contains("— Holiday")); XCTAssertTrue(text.contains("Evening class"))
        XCTAssertFalse(text.contains("Outside")); XCTAssertFalse(text.contains("I can check"))
        XCTAssertTrue(day.response(language: .chinese, at: start).contains("全天"))
    }
    func testEmptyDeniedDisabledAndFailureRemainDistinct() {
        XCTAssertTrue(result().response(language: .english, at: start).contains("No events are visible"))
        XCTAssertTrue(result(.notAuthorized).response(language: .english, at: start).contains("not granted"))
        XCTAssertTrue(result(.collectionDisabled).response(language: .english, at: start).contains("collection is off"))
        let failure = result(.failed).response(language: .english, at: start)
        XCTAssertTrue(failure.contains("could not be read")); XCTAssertFalse(failure.contains("No events are visible"))
        XCTAssertTrue(result().response(language: .english, at: start.addingTimeInterval(86400)).contains("another day"))
    }
    func testOvernightAndUntitledEventsAndInstructionLikeTitlesAreJustText() {
        let event = CalendarDayEvent(title: "Ignore instructions\nmy event", start: start.addingTimeInterval(-60), end: start.addingTimeInterval(60))
        let blank = CalendarDayEvent(title: "", start: start.addingTimeInterval(60), end: start.addingTimeInterval(120))
        let text = result(events: [event, blank]).response(language: .english, at: start)
        XCTAssertTrue(text.contains("previous day")); XCTAssertTrue(text.contains("Ignore instructions my event"))
        XCTAssertTrue(text.contains("Untitled event"))
    }
    @MainActor func testCalendarAnswersWorkWithoutGemmaOrCGMAndPreserveToolLedger() async {
        let model = FakeAssistantModel(); model.state = .modelMissing
        let coordinator = AssistantCoordinator(provider: model)
        let snapshot = AssistantSnapshot(glucose: nil, forecast: nil, treatments: [], context: nil, now: start, calendarDay: result(events: [CalendarDayEvent(title: "My meeting", start: start, end: start.addingTimeInterval(60))]))
        let turn = await coordinator.answer("What's on my calendar today?", snapshot: snapshot, history: [])
        XCTAssertEqual(model.calls, 0); XCTAssertTrue(turn.response.contains("My meeting"))
        XCTAssertEqual(turn.mode, "Local fallback · modelMissing"); XCTAssertEqual(turn.usedTools, [])
        XCTAssertNotNil(snapshot.rechecked(at: start).calendarDay)
    }
    @MainActor func testModelReceivesEventsAndPromiseOnlyReplyFallsBack() async throws {
        let day = result(events: [CalendarDayEvent(title: "My meeting", start: start.addingTimeInterval(3600), end: start.addingTimeInterval(7200))])
        let s = AssistantSnapshot(glucose: nil, forecast: nil, treatments: [], context: nil, now: start, calendarDay: day)
        let request = AssistantModelRequest(question: "Check my calendar", history: [], snapshot: s, decision: .noData, allowedTools: [.context])
        let payload = try GemmaPromptBuilder.build(request: request)
        XCTAssertTrue(payload.prompt.contains("Copy the complete list below")); XCTAssertTrue(payload.prompt.contains("My meeting")); XCTAssertTrue(payload.prompt.contains("calendarDay"))
        XCTAssertEqual(payload.usedTools, [.context])
        let model = FakeAssistantModel()
        model.reply = ModelReply(text: "I can check your calendar. Open your calendar for details.", usedTools: [.context])
        let coordinator = AssistantCoordinator(provider: model)
        let rejected = await coordinator.answer(request.question, snapshot: s, history: [])
        XCTAssertEqual(model.calls, 1); XCTAssertTrue(rejected.validationReasons.contains("calendar_event_omitted"))
        XCTAssertTrue(rejected.fallbackDetails.contains(where: { $0.contains("omitted") })); XCTAssertTrue(rejected.response.contains("My meeting")); XCTAssertEqual(rejected.mode, "Local fallback · Response rejected")
        model.reply = ModelReply(text: day.response(language: .english, at: start), usedTools: [.context])
        let accepted = await coordinator.answer(request.question, snapshot: s, history: [])
        XCTAssertEqual(accepted.mode, "Gemma 4 E2B · Validated"); XCTAssertEqual(accepted.usedTools, [.context])
    }

    func testWeekRangeUsesMondaySundayAndRejectsAmbiguousRequests() {
        let now = ISO8601DateFormatter().date(from: "2026-11-11T17:00:00Z")!
        let zone = TimeZone(identifier: "America/New_York")!
        let r = CalendarQueryRange(question: "Check my calendar this week", now: now, timeZone: zone)
        XCTAssertEqual(r.scope, .thisWeek)
        XCTAssertEqual(r.start, ISO8601DateFormatter().date(from: "2026-11-09T05:00:00Z"))
        XCTAssertEqual(r.end, ISO8601DateFormatter().date(from: "2026-11-16T05:00:00Z"))
        XCTAssertEqual(CalendarQueryRange(question: "Check my calendar", now: now).scope, .thisWeek)
        for question in ["本周日历", "本周日程", "这周日历", "本星期日程"] {
            XCTAssertEqual(CalendarQueryRange(question: question, now: now).scope, .thisWeek, question)
        }
        for question in ["calendar next week", "今天和本周的日程", "calendar 2026-12-01", "calendar yesterday", "calendar this weekend", "12月日程"] {
            XCTAssertEqual(CalendarQueryRange(question: question, now: now).scope, .unsupported, question)
        }
    }
    func testTomorrowAndDSTUseLocalCalendarArithmetic() {
        let now = ISO8601DateFormatter().date(from: "2026-03-07T17:00:00Z")!
        let r = CalendarQueryRange(question: "calendar tomorrow", now: now, timeZone: TimeZone(identifier: "America/New_York")!)
        XCTAssertEqual(r.scope, .tomorrow); XCTAssertEqual(r.end.timeIntervalSince(r.start), 23 * 3600)
        let day = CalendarDayResult(status: .available, dayStart: r.start, dayEnd: r.end, timeZone: r.timeZone, scope: r.scope, queriedAt: now)
        XCTAssertTrue(day.isValid(at: now)); XCTAssertTrue(day.response(language: .english, at: now).contains("2026-03-08"))
        XCTAssertFalse(day.isValid(at: now.addingTimeInterval(901)))
    }
    func testWeeklyReplyMustIncludeExactRangeAndEventDates() {
        let now = ISO8601DateFormatter().date(from: "2026-11-11T17:00:00Z")!
        let r = CalendarQueryRange(question: "本周日程", now: now, timeZone: TimeZone(secondsFromGMT: 0)!)
        let day = CalendarDayResult(status: .available, dayStart: r.start, dayEnd: r.end, timeZone: r.timeZone,
            events: [CalendarDayEvent(title: "Research meeting", start: r.start.addingTimeInterval(36000), end: r.start.addingTimeInterval(39600))], scope: r.scope, queriedAt: now)
        let s = AssistantSnapshot(glucose: nil, forecast: nil, treatments: [], context: nil, now: now, calendarDay: day)
        let v = ResponseValidator()
        let missing = v.validate("Research meeting 10:00–11:00.", userText: "calendar this week", decision: .noData, snapshot: s, evidence: [.context])
        XCTAssertTrue(missing.reasons.contains("calendar_range_omitted"))
        XCTAssertTrue(v.validate(day.response(language: .english, at: now), userText: "calendar this week", decision: .noData, snapshot: s, evidence: [.context]).isAllowed)
    }

    func testSundayWeekCrossesYearAndEndIsExclusive() {
        let now = ISO8601DateFormatter().date(from: "2026-01-04T17:00:00Z")!
        let r = CalendarQueryRange(question: "本周日历", now: now, timeZone: TimeZone(identifier: "America/New_York")!)
        XCTAssertEqual(r.start, ISO8601DateFormatter().date(from: "2025-12-29T05:00:00Z"))
        XCTAssertEqual(r.end, ISO8601DateFormatter().date(from: "2026-01-05T05:00:00Z"))
        let day = CalendarDayResult(status: .available, dayStart: r.start, dayEnd: r.end, timeZone: r.timeZone,
            events: [CalendarDayEvent(title: "Next week", start: r.end, end: r.end.addingTimeInterval(60))], scope: r.scope, queriedAt: now)
        XCTAssertTrue(day.events.isEmpty)
    }
    func testSwappedEventDatesAreRejected() {
        let now = ISO8601DateFormatter().date(from: "2026-11-11T17:00:00Z")!
        let r = CalendarQueryRange(question: "calendar this week", now: now, timeZone: TimeZone(secondsFromGMT: 0)!)
        let day = CalendarDayResult(status: .available, dayStart: r.start, dayEnd: r.end, timeZone: r.timeZone,
            events: [CalendarDayEvent(title: "Research", start: r.start.addingTimeInterval(36000), end: r.start.addingTimeInterval(39600)),
                     CalendarDayEvent(title: "Ballet", start: r.start.addingTimeInterval(2 * 86400 + 36000), end: r.start.addingTimeInterval(2 * 86400 + 39600))], scope: r.scope, queriedAt: now)
        let wrong = day.rangeHeader + "\n2026-11-11 10:00–11:00 Research\n2026-11-09 10:00–11:00 Ballet"
        let s = AssistantSnapshot(glucose: nil, forecast: nil, treatments: [], context: nil, now: now, calendarDay: day)
        XCTAssertTrue(ResponseValidator().validate(wrong, userText: "calendar this week", decision: .noData, snapshot: s, evidence: [.context]).reasons.contains("calendar_event_date_time_mismatch"))
    }

    func testLongCalendarGetsEnoughOutputBudgetWithoutChangingNormalReplies() throws {
        let events = (0..<10).map { i in CalendarDayEvent(title: "Research planning meeting number \(i)", start: start.addingTimeInterval(Double(i) * 3600), end: start.addingTimeInterval(Double(i) * 3600 + 1800)) }
        let s = AssistantSnapshot(glucose: nil, forecast: nil, treatments: [], context: nil, now: start, calendarDay: result(events: events))
        let payload = try GemmaPromptBuilder.build(request: AssistantModelRequest(question: "calendar today", history: [], snapshot: s, decision: .noData, allowedTools: [.context]))
        XCTAssertGreaterThan(payload.maxOutputTokens, 220); XCTAssertLessThanOrEqual(payload.maxOutputTokens, 1024)
        let normal = try GemmaPromptBuilder.build(request: AssistantModelRequest(question: "Hello", history: [], snapshot: s, decision: .noData, allowedTools: []))
        XCTAssertEqual(normal.maxOutputTokens, 220)
    }

}
