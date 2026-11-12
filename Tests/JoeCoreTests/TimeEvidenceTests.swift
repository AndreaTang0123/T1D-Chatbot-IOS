import XCTest
@testable import JoeCore

@MainActor private final class TimeEvidenceProvider: AssistantModelProvider {
    var runtimeVersion = "synthetic-time-evidence.v1"
    let reply: ModelReply
    init(_ reply: ModelReply) { self.reply = reply }
    func availability(language: ReplyLanguage) -> ModelAvailability { .available }
    func prewarm() {}
    func respond(to request: AssistantModelRequest) async throws -> ModelReply { reply }
}
@MainActor final class TimeEvidenceTests: XCTestCase {
    func testFriendlyLocalDatesUseCalendarDaysAndKeepOlderDates() {
        let zone = TimeZone(identifier: "America/New_York")!
        let now = ISO8601DateFormatter().date(from: "2026-11-13T02:00:00Z")! // Still November 12 locally.
        let text = "2026-11-12 21:21 (America/New_York, UTC-05:00); 2026-11-11 08:05 (America/New_York, UTC-05:00); 2026-11-10 09:00 (America/New_York, UTC-05:00). Meeting (Research)."
        XCTAssertEqual(AssistantReplyPresentation.localTimes(text, relativeTo: now, in: zone, language: .chinese), "今天 21:21; 昨天 08:05; 2026-11-10 09:00. Meeting (Research).")
        XCTAssertTrue(AssistantReplyPresentation.localTimes(text, relativeTo: now, in: zone, language: .english).contains("yesterday 08:05"))
        let nextDay = now.addingTimeInterval(3 * 3600)
        XCTAssertEqual(AssistantReplyPresentation.localTimes("2026-11-12 21:21", relativeTo: nextDay, in: zone, language: .chinese), "昨天 21:21")
        let newYear = ISO8601DateFormatter().date(from: "2027-01-01T06:00:00Z")!
        XCTAssertEqual(AssistantReplyPresentation.localTimes("2026-12-31 23:59", relativeTo: newYear, in: zone, language: .chinese), "昨天 23:59")
    }

    let now = ISO8601DateFormatter().date(from: "2026-11-12T15:51:59Z")!
    let zone = TimeZone(identifier: "America/New_York")!
    func snapshot(age: TimeInterval = 0) -> AssistantSnapshot {
        let bolus = Treatment(id: "synthetic", timestamp: now.addingTimeInterval(-(864 * 60 + 59)), kind: "Bolus", insulin: 0.3)
        return AssistantSnapshot(glucose: GlucoseSample(id: "synthetic", timestamp: now.addingTimeInterval(-age), glucose: 120, receivedAt: now), forecast: nil, treatments: [bolus], context: nil, now: now, timeZone: zone)
    }
    func testFullLocalTimestampAndDSTOffsetAreUnambiguous() {
        XCTAssertEqual(snapshot().recentInsulin.latestBolusLocalTime, "2026-11-11 20:27 (America/New_York, UTC-05:00)")
        let first = ISO8601DateFormatter().date(from: "2026-11-01T05:30:00Z")!
        let second = first.addingTimeInterval(3600)
        XCTAssertTrue(LocalEventTime.string(first, in: zone).contains("01:30 (America/New_York, UTC-04:00)"))
        XCTAssertTrue(LocalEventTime.string(second, in: zone).contains("01:30 (America/New_York, UTC-05:00)"))
    }
    func testPromptDoesNotExposeChangingAgeOrUTCForBolusAndCGM() throws {
        let s = snapshot()
        let payload = try GemmaPromptBuilder.build(request: AssistantModelRequest(question: "When did I last bolus?", history: [], snapshot: s, decision: .normal, allowedTools: [.insulin, .glucose]))
        XCTAssertFalse(payload.prompt.contains("\"latestBolusTime\"")); XCTAssertFalse(payload.prompt.contains("\"sourceTimestamp\""));
        XCTAssertFalse(payload.prompt.contains("dataAgeMinutes")); XCTAssertFalse(payload.prompt.contains("ageMinutes"))
        XCTAssertTrue(payload.prompt.contains("2026-11-11 20:27")); XCTAssertTrue(payload.prompt.contains("UTC-05:00"))
    }
    func testCorrectBolusLocalTimeSurvivesMinuteBoundary() async {
        let s = snapshot()
        XCTAssertEqual(s.recentInsulin.dataAgeMinutes, 864)
        XCTAssertEqual(s.rechecked(at: now.addingTimeInterval(2)).recentInsulin.dataAgeMinutes, 865)
        let provider = TimeEvidenceProvider(ModelReply(text: "The latest visible bolus was 0.3 U at \(s.recentInsulin.latestBolusLocalTime!); IOB is unavailable.", usedTools: [.insulin], factSnapshot: s))
        let turn = await AssistantCoordinator(provider: provider, replyTime: { self.now.addingTimeInterval(2) }).answer("When did I last bolus?", snapshot: s, history: [])
        XCTAssertEqual(turn.mode, "Gemma 4 E2B · Validated"); XCTAssertTrue(turn.validationReasons.isEmpty)
        XCTAssertEqual(turn.factSnapshotTime, now); XCTAssertEqual(turn.freshnessCheckTime, now.addingTimeInterval(2))
        XCTAssertFalse(turn.response.contains("minutes ago"))
    }
    func testFactsComeFromExecutedToolSnapshotNotOriginalRequest() async {
        let original = snapshot()
        let facts = AssistantSnapshot(glucose: GlucoseSample(id: "new", timestamp: now, glucose: 140, receivedAt: now), forecast: nil, treatments: [], context: nil, now: now, timeZone: zone)
        let provider = TimeEvidenceProvider(ModelReply(text: "Your latest measurement is 140 mg/dL.", usedTools: [.glucose], factSnapshot: facts))
        let turn = await AssistantCoordinator(provider: provider).answer("What is my glucose?", snapshot: original, history: [])
        XCTAssertEqual(turn.mode, "Gemma 4 E2B · Validated")
    }
    func testSafetyFreshnessStillOverridesFactuallyCorrectReply() async {
        let s = snapshot(age: 899)
        let provider = TimeEvidenceProvider(ModelReply(text: "Your latest measurement is 120 mg/dL at \(s.currentGlucose.sourceLocalTime!).", usedTools: [.glucose], factSnapshot: s))
        let turn = await AssistantCoordinator(provider: provider, replyTime: { self.now.addingTimeInterval(2) }).answer("What is my glucose?", snapshot: s, history: [])
        XCTAssertEqual(turn.mode, "Swift safety · staleData"); XCTAssertTrue(turn.validationReasons.isEmpty)
        XCTAssertTrue(turn.freshnessReasons?.contains("freshness_or_safety_staleData") == true)
        XCTAssertTrue(turn.response.contains("stale")); XCTAssertFalse(turn.response.contains("minutes ago"))
    }
    func testTimestampDigitsDoNotAuthorizeWrongDoseAndWrongTimesAreRejected() {
        let s = snapshot(); let v = ResponseValidator()
        let time = s.recentInsulin.latestBolusLocalTime!
        for amount in ["0.4", "5", "27"] {
            let text = "Your last visible bolus was \(amount) U at \(time); IOB is unavailable."
            XCTAssertTrue(v.validate(text, userText: "When did I last bolus?", decision: .normal, snapshot: s, evidence: [.insulin]).reasons.contains("unsupported_insulin_amount"))
        }
        let wrong = "Your last bolus was 0.3 U at \(time.replacingOccurrences(of: "20:27", with: "20:28")); IOB is unavailable."
        XCTAssertTrue(v.validate(wrong, userText: "When did I last bolus?", decision: .normal, snapshot: s, evidence: [.insulin]).reasons.contains("unsupported_event_time"))
        XCTAssertTrue(v.validate("Your glucose was 120 mg/dL.", userText: "When was my last glucose measurement?", decision: .normal, snapshot: s, evidence: [.glucose]).reasons.contains("event_time_omitted"))
        let relative = v.validate("The last bolus was 0.3 U, 864 minutes ago; IOB is unavailable.", userText: "When did I last bolus?", decision: .normal, snapshot: s, evidence: [.insulin])
        XCTAssertTrue(relative.reasons.contains("relative_event_time")); XCTAssertFalse(relative.reasons.contains("unsupported_number"))
    }
    func testNewLogFieldsAreOptionalForOldStoredRecords() async throws {
        let s = snapshot()
        let provider = TimeEvidenceProvider(ModelReply(text: "Hello.", usedTools: []))
        let turn = await AssistantCoordinator(provider: provider).answer("Hello", snapshot: s, history: [])
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(turn)) as! [String: Any]
        for key in ["factSnapshotTime", "freshnessCheckTime", "freshnessReasons"] { object.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(AssistantTurnRecord.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.factSnapshotTime); XCTAssertNil(decoded.freshnessCheckTime)
    }
    func testContextAndCalendarExpiryAreIndependentOfFactualValidation() {
        let context = LifestyleContext(timestamp: now.addingTimeInterval(-899), place: "home")
        let s = AssistantSnapshot(glucose: snapshot().glucose, forecast: nil, treatments: [], context: context, now: now, timeZone: zone)
        let review = ReplyFreshnessReview.evaluate(question: "Where am I?", facts: s, at: now.addingTimeInterval(2), evidence: [.context])
        XCTAssertNotNil(review.requiredResponse); XCTAssertEqual(review.reasons, ["context_expired_during_generation"])
        let range = CalendarQueryRange(question: "calendar today", now: now, timeZone: zone)
        let day = CalendarDayResult(status: .available, dayStart: range.start, dayEnd: range.end, timeZone: zone,
            events: [CalendarDayEvent(title: "Meeting", start: now, end: now.addingTimeInterval(60))], scope: .today, queriedAt: now)
        let calendar = AssistantSnapshot(glucose: nil, forecast: nil, treatments: [], context: nil, now: now, calendarDay: day)
        let expired = ReplyFreshnessReview.evaluate(question: "calendar today", facts: calendar, at: now.addingTimeInterval(901), evidence: [.context])
        XCTAssertNotNil(expired.requiredResponse); XCTAssertEqual(expired.reasons, ["calendar_expired_during_generation"])
    }

}
