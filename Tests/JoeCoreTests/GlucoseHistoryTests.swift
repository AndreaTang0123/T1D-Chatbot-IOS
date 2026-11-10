import XCTest
@testable import JoeCore

final class GlucoseHistoryTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func sample(_ id: String, _ seconds: Double, _ value: Double) -> GlucoseSample {
        GlucoseSample(id: id, timestamp: now.addingTimeInterval(seconds), glucose: value, receivedAt: now, sourceName: "Dexcom")
    }
    func testHistoryBinsExcludeInvalidAndFutureAndDeduplicateSources() {
        let data = [sample("a", -600, 60), sample("b", -300, 120), sample("c", 0, 240),
                    sample("duplicate", -300, 120), sample("future", 300, 100), sample("invalid", -900, .nan),
                    sample("old", -31*86400, 100)]
        let h = GlucoseHistorySummary(samples: data, days: 7, now: now)!
        XCTAssertEqual(h.observedBins, 3)
        XCTAssertEqual(h.meanMgDl, 140)
        XCTAssertEqual(h.below70Percent, 33.3)
        XCTAssertEqual(h.within70To180Percent, 33.3)
        XCTAssertEqual(h.above180Percent, 33.3)
        XCTAssertEqual(h.coveragePercent, 0.1)
        XCTAssertEqual(h.sources, ["Dexcom"])
        XCTAssertEqual(h.latest, now)
        XCTAssertNil(GlucoseHistorySummary(samples: [], days: 14, now: now))
    }
    func testHistoryRoutesWithoutCurrentCGMAndKeepsDoseGuard() throws {
        let h = GlucoseHistorySummary(samples: [sample("a", -10800, 120)], days: 14, now: now)!
        let snapshot = AssistantSnapshot(glucose: nil, forecast: nil, treatments: [], context: nil, now: now, glucoseHistory: h)
        let question = "总结最近两周血糖表现"
        XCTAssertEqual(QuestionIntent(question).tools, [.history])
        XCTAssertNil(ExplanationFallback().requiredResponse(decision: .noData, userText: question, snapshot: snapshot))
        XCTAssertTrue(ExplanationFallback().generalResponse(userText: question, snapshot: snapshot).contains("120.0 mg/dL"))
        XCTAssertTrue(ExplanationFallback().requiredResponse(decision: .noData, userText: "最近两周血糖表现，应该打多少胰岛素？", snapshot: snapshot) != nil)
        let payload = try GemmaPromptBuilder.build(request: AssistantModelRequest(question: question, history: [], snapshot: snapshot, decision: .noData, allowedTools: [.history]))
        XCTAssertEqual(payload.usedTools, [.history])
        XCTAssertTrue(payload.prompt.contains("meanMgDl"))
        let valid = ResponseValidator().validate("历史血糖平均120 mg/dL，数据可能延迟，不能代表当前读数。", userText: question, decision: .noData, snapshot: snapshot, evidence: [.history])
        XCTAssertTrue(valid.isAllowed)
        let bad = ResponseValidator().validate("当前血糖为999 mg/dL。", userText: question, decision: .noData, snapshot: snapshot, evidence: [.history])
        XCTAssertTrue(bad.reasons.contains("unsupported_number"))
        XCTAssertTrue(bad.reasons.contains("history_as_current_or_time_weighted"))
        XCTAssertEqual(snapshot.rechecked(at: now).glucoseHistory?.observedBins, 1)
        XCTAssertNil(snapshot.currentGlucose.glucoseMgDl)
        XCTAssertFalse(snapshot.forecastResult.available)
    }
    func testRequestedWindows() {
        XCTAssertEqual(GlucoseHistorySummary.requestedDays("last week glucose history", defaultDays: 14), 7)
        XCTAssertEqual(GlucoseHistorySummary.requestedDays("最近两周血糖表现", defaultDays: 7), 14)
        XCTAssertEqual(GlucoseHistorySummary.requestedDays("近一个月历史血糖", defaultDays: 14), 30)
    }
}
