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
    func testWeeklyActivityRoutesAndSuppliesEvidenceWithoutGlucose() throws {
        for question in ["Analyze my exercise over the past week", "分析最近一周运动历史", "My steps for the last 7 days"] {
            XCTAssertTrue(HealthActivityQuery(question).weekly)
            XCTAssertTrue(QuestionIntent(question).tools.contains(.context))
        }
        XCTAssertFalse(HealthActivityQuery("What's on my calendar this week?").requested)
        var health = result()
        health.weeklyHistory = WeeklyActivityResult(startLocal: "2026-11-10", endLocal: "2026-11-16", days: [
            WeeklyActivityDay(date: "2026-11-15", steps: 6543, stepsStatus: .available, workouts: ["Walking"], workoutMinutes: 42, workoutStatus: .available),
            WeeklyActivityDay(date: "2026-11-16", steps: nil, stepsStatus: .readFailed, workouts: [], workoutMinutes: nil, workoutStatus: .noVisibleRecords)])
        let question = "Analyze my exercise over the past week"
        let facts = snapshot(health)
        XCTAssertNil(ExplanationFallback().requiredResponse(decision: .noData, userText: question, snapshot: facts))
        let prompt = try GemmaPromptBuilder.build(request: AssistantModelRequest(question: question, history: [], snapshot: facts, decision: .noData, allowedTools: [.context])).prompt
        for evidence in ["6543", "42", "Walking", "readFailed", "noVisibleRecords"] { XCTAssertTrue(prompt.contains(evidence)) }
        XCTAssertFalse(health.response(question: question, language: .english).contains("4321"))
        let validator = ResponseValidator()
        let valid = validator.validate("2026-11-15: 6543 steps and 42 workout minutes. Missing records do not establish inactivity.", userText: question, decision: .noData, snapshot: facts, evidence: [.context])
        XCTAssertTrue(valid.reasons.isEmpty, "\(valid.reasons)")
        XCTAssertTrue(validator.validate("No tool results were returned.", userText: question, decision: .noData, snapshot: facts, evidence: [.context]).reasons.contains("weekly_activity_evidence_omitted"))
    }
    func testUnqualifiedActivityLogsReadAWeekAndNeverSupplyEmptyEvidence() throws {
        var health = result()
        health.weeklyHistory = WeeklyActivityResult(startLocal: "2026-11-10", endLocal: "2026-11-16", days: [
            WeeklyActivityDay(date: "2026-11-15", steps: 5000, stepsStatus: .available, workouts: ["Running"], workoutMinutes: 30, workoutStatus: .available)])
        for question in ["Can you access my activity logs?", "Analyze my activities", "Show workout history", "查看运动记录", "活动日志"] {
            XCTAssertTrue(HealthActivityQuery(question).weekly, question)
            XCTAssertEqual(QuestionIntent(question).tools, [.context], question)
            XCTAssertFalse(health.response(question: question, language: .english).isEmpty)
            let request = AssistantModelRequest(question: question, history: [], snapshot: snapshot(health), decision: .noData, allowedTools: QuestionIntent(question).tools)
            let prompt = try GemmaPromptBuilder.build(request: request).prompt
            XCTAssertTrue(prompt.contains("Running"), question)
            XCTAssertTrue(prompt.contains("5000"), question)
        }
    }
    func testUnavailableWeeklyLogsGiveExactReadStatusWithoutGeneration() {
        var health = result()
        health.weeklyHistory = WeeklyActivityResult(startLocal: "2026-11-10", endLocal: "2026-11-16", days: [
            WeeklyActivityDay(date: "2026-11-15", steps: nil, stepsStatus: .readFailed, workouts: [], workoutMinutes: nil, workoutStatus: .noVisibleRecords)])
        let reply = ExplanationFallback().requiredResponse(decision: .noData, userText: "Access activity logs", snapshot: snapshot(health))
        XCTAssertTrue(reply?.contains("Read failed") == true)
        XCTAssertTrue(reply?.contains("No visible records") == true)
        XCTAssertFalse(reply?.contains("0 steps") == true)
    }
    func testScreenshotWorkedOutQuestionRoutesToActualWorkoutEvidence() throws {
        let start = now.addingTimeInterval(-7200)
        let workout = RecordedWorkout(category: "Walking", start: start, end: start.addingTimeInterval(2400), durationMinutes: 40, timeZone: zone)
        var health = result()
        health.weeklyHistory = WeeklyActivityResult(startLocal: "2026-11-10", endLocal: "2026-11-16", days: [
            WeeklyActivityDay(date: "2026-11-16", steps: 6559, stepsStatus: .available, workouts: ["Walking"], workoutMinutes: 40, workoutStatus: .available)], latestWorkout: workout)
        for question in ["When did I worked out last time?", "When did I last work out?", "When was my last workout?", "When did I exercise last time?", "我上一次锻炼是什么时候？"] {
            XCTAssertTrue(HealthActivityQuery(question).latestWorkout, question)
            XCTAssertTrue(HealthActivityQuery(question).weekly, question)
            XCTAssertEqual(QuestionIntent(question).tools, [.context], question)
            let response = ExplanationFallback().requiredResponse(decision: .noData, userText: question, snapshot: snapshot(health))
            XCTAssertTrue(response?.contains(workout.startLocal) == true, question)
            XCTAssertTrue(response?.contains(workout.endLocal) == true, question)
            XCTAssertTrue(response?.contains("40") == true, question)
            XCTAssertFalse(response?.contains("no tool results") == true, question)
            let prompt = try GemmaPromptBuilder.build(request: AssistantModelRequest(question: question, history: [], snapshot: snapshot(health), decision: .noData, allowedTools: [.context])).prompt
            XCTAssertTrue(prompt.contains(workout.startLocal), question)
        }
    }
    func testLastWorkoutDoesNotInferTrainingFromStepsOrQueryTime() {
        var health = result()
        health.weeklyHistory = WeeklyActivityResult(startLocal: "2026-11-10", endLocal: "2026-11-16", days: [
            WeeklyActivityDay(date: "2026-11-16", steps: 6559, stepsStatus: .available, workouts: [], workoutMinutes: nil, workoutStatus: .noVisibleRecords)])
        let response = ExplanationFallback().requiredResponse(decision: .noData, userText: "When did I worked out last time?", snapshot: snapshot(health))
        XCTAssertTrue(response?.contains("cannot establish when") == true)
        XCTAssertFalse(response?.contains("latest visible workout within") == true)
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
