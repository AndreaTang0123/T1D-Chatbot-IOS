import XCTest
@testable import JoeCore

final class HealthActivityTests: XCTestCase {
    let now = ISO8601DateFormatter().date(from: "2026-11-16T18:00:00Z")!
    let zone = TimeZone(identifier: "America/New_York")!
    func result(_ steps: HealthReadStatus = .available, _ hr: HealthReadStatus = .available) -> HealthActivityResult {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        return HealthActivityResult(queriedAt: now, dayStart: calendar.startOfDay(for: now), timeZone: zone, stepsStatus: steps, stepsToday: 4321,
            heartRateStatus: hr, heartRateBpm: 72, heartRateMeasuredAt: now.addingTimeInterval(-7200))
    }
    func snapshot(_ health: HealthActivityResult) -> AssistantSnapshot {
        AssistantSnapshot(glucose: nil, forecast: nil, treatments: [], context: nil, now: now, timeZone: zone, healthActivity: health)
    }
    func testAbbreviatedEnglishAndChineseQueriesSelectContext() {
        for text in ["My hr?", "Latest BPM", "What's my pulse?", "我的心率", "今天走了多少步", "my step count", "Apple Health data"] {
            XCTAssertTrue(QuestionIntent(text).tools.contains(.context), text)
        }
        XCTAssertFalse(HealthActivityQuery("Christmas lunch").heartRate)
    }
    func testQueriesWorkWithoutCGMAndIncludeDatedMeasurementEvidence() throws {
        let s = snapshot(result())
        XCTAssertNil(ExplanationFallback().requiredResponse(decision: .noData, userText: "What's my hr?", snapshot: s))
        let request = AssistantModelRequest(question: "My steps and hr?", history: [], snapshot: s, decision: .noData, allowedTools: [.context])
        let prompt = try GemmaPromptBuilder.build(request: request).prompt
        XCTAssertTrue(prompt.contains("4321")); XCTAssertTrue(prompt.contains("72")); XCTAssertTrue(prompt.contains("2026-11-16 11:00"))
        XCTAssertFalse(prompt.contains("\"heartRateMeasuredAt\""))
        XCTAssertTrue(ExplanationFallback().generalResponse(userText: "My hr?", snapshot: s).contains("72 bpm"))
    }
    func testQueryStatusesDoNotBecomeZeroOrDeniedPermission() {
        for status in [HealthReadStatus.noVisibleRecords, .readFailed, .collectionDisabled, .deviceUnavailable] {
            let h = result(status, status)
            XCTAssertNil(h.stepsToday); XCTAssertNil(h.heartRateBpm)
            let text = h.response(question: "steps and hr", language: .english)
            XCTAssertFalse(text.contains("0 steps")); XCTAssertFalse(text.contains("permission denied"))
        }
        XCTAssertTrue(result(.readFailed).response(question: "steps", language: .english).contains("failed"))
        XCTAssertTrue(result(.noVisibleRecords).response(question: "steps", language: .english).contains("No visible"))
    }
    func testHeartRateRequiresMeasurementTimeAndIsNotLive() {
        let s = snapshot(result()); let text = result().response(question: "My hr?", language: .english)
        let validator = ResponseValidator()
        let shown = AssistantReplyPresentation.localTimes(result().response(question: "我的心率", language: .chinese), relativeTo: now, in: zone, language: .chinese)
        XCTAssertTrue(shown.contains("今天 11:00")); XCTAssertFalse(shown.contains("UTC-"))
        XCTAssertTrue(validator.validate(text, userText: "My hr?", decision: .noData, snapshot: s, evidence: [.context]).isAllowed)
        XCTAssertTrue(validator.validate("Your heart rate is 72 bpm.", userText: "My hr?", decision: .noData, snapshot: s, evidence: [.context]).reasons.contains("health_measurement_time_omitted"))
        XCTAssertTrue(validator.validate("Your live heart rate is 72 bpm at " + result().heartRateMeasuredLocal!, userText: "My hr?", decision: .noData, snapshot: s, evidence: [.context]).reasons.contains("health_record_as_live"))
        XCTAssertTrue(validator.validate("You recorded 120 steps today.", userText: "My steps?", decision: .noData, snapshot: s, evidence: [.context]).reasons.contains("health_steps_omitted"))
    }
    func testHealthQueryNeverSuppressesUrgentCGMSafety() {
        let glucose = GlucoseSample(id: "synthetic-low", timestamp: now, glucose: 60, receivedAt: now)
        let s = AssistantSnapshot(glucose: glucose, forecast: nil, treatments: [], context: nil, now: now, timeZone: zone, healthActivity: result())
        let response = ExplanationFallback().requiredResponse(decision: .urgentLow(glucose: 60), userText: "My steps?", snapshot: s)
        XCTAssertTrue(response?.contains("60") == true)
        let midnight = ISO8601DateFormatter().date(from: "2026-11-17T04:59:00Z")!
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let h = HealthActivityResult(queriedAt: midnight, dayStart: calendar.startOfDay(for: midnight), timeZone: zone,
            stepsStatus: .available, stepsToday: 4321, heartRateStatus: .noVisibleRecords)
        XCTAssertFalse(h.isValid(at: midnight.addingTimeInterval(120)))
    }
    func testDayBoundaryExpiryAndUnsupportedWindowsAreExplicit() {
        let h = result(); XCTAssertTrue(h.isValid(at: now.addingTimeInterval(60)))
        XCTAssertFalse(h.isValid(at: now.addingTimeInterval(901)))
        XCTAssertFalse(h.isValid(at: now.addingTimeInterval(-1)))
        let text = ExplanationFallback().requiredResponse(decision: .noData, userText: "My steps yesterday?", snapshot: snapshot(h))
        XCTAssertTrue(text?.contains("not supported") == true); XCTAssertFalse(text?.contains("4321") == true)
        let stale = snapshot(h).rechecked(at: now.addingTimeInterval(901))
        XCTAssertNil(stale.currentContext.healthActivity)
        let review = ReplyFreshnessReview.evaluate(question: "My hr?", facts: snapshot(h), at: now.addingTimeInterval(901), evidence: [.context])
        XCTAssertNotNil(review.requiredResponse)
    }
}
