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
    func testThreeDaysAreRolling72HoursWithCoverageAndNoInventedDays() throws {
        let zone = TimeZone(identifier: "America/New_York")!
        let start = now.addingTimeInterval(-72 * 3600)
        let data = [sample("before", -72 * 3600 - 1, 300), sample("first", -72 * 3600, 100), sample("last", -300, 140), sample("future", 1, 240)]
        let h = try XCTUnwrap(GlucoseHistorySummary(samples: data, days: 3, now: now, timeZone: zone))
        XCTAssertEqual(h.start, start); XCTAssertEqual(h.end, now); XCTAssertEqual(h.observedBins, 2)
        XCTAssertEqual(h.meanMgDl, 120); XCTAssertEqual(h.latestGlucoseMgDl, 140)
        XCTAssertLessThan(h.coveragePercent, 1); XCTAssertEqual(h.daily.count, 2)
        XCTAssertTrue(h.windowStartLocal.contains("America/New_York")); XCTAssertTrue(h.description(language: .english).contains("Historical"))
        XCTAssertTrue(h.supportedNumbers.contains(72)); XCTAssertNil(GlucoseHistorySummary(samples: [], days: 3, now: now))
        XCTAssertEqual(GlucoseHistorySummary.requestedDays("最近三天血糖", defaultDays: 14), 3)
        XCTAssertEqual(GlucoseHistorySummary.requestedDays("past 3 days of glucose", defaultDays: 14), 3)
        XCTAssertEqual(GlucoseHistorySummary.requestedDays("last 72 hours glucose", defaultDays: 14), 3)
        XCTAssertEqual(QuestionIntent("最近三天血糖").tools, [.history])
        let s = AssistantSnapshot(glucose: nil, forecast: nil, treatments: [], context: nil, now: now, glucoseHistory: h, timeZone: zone)
        let validation = ResponseValidator().validate(h.description(language: .english), userText: "glucose history last 3 days", decision: .noData, snapshot: s, evidence: [.history])
        XCTAssertTrue(validation.isAllowed, String(describing: validation.reasons))
    }
    func testNightscoutAndHealthDuplicatesDoNotInflateThreeDayCoverage() throws {
        let direct = GlucoseSample(id: "n", timestamp: now.addingTimeInterval(-60), glucose: 120, receivedAt: now, sourceName: "Nightscout")
        let health = GlucoseSample(id: "healthkit:h", timestamp: now.addingTimeInterval(-59), glucose: 200, receivedAt: now, sourceName: "Dexcom")
        let h = try XCTUnwrap(GlucoseHistorySummary(samples: [health, direct], days: 3, now: now))
        XCTAssertEqual(h.observedBins, 1); XCTAssertEqual(h.meanMgDl, 120); XCTAssertEqual(h.sources, ["Nightscout"])
        XCTAssertEqual(h.latest, direct.timestamp)
    }

    func testRolling72HoursAcrossDSTDoesNotBecomeThreeCalendarDays() throws {
        let end = ISO8601DateFormatter().date(from: "2026-11-02T17:00:00Z")!
        let start = end.addingTimeInterval(-72 * 3600)
        let samples = [GlucoseSample(id: "start", timestamp: start, glucose: 100, receivedAt: end, sourceName: "Nightscout"),
                       GlucoseSample(id: "end", timestamp: end, glucose: 140, receivedAt: end, sourceName: "Nightscout")]
        let h = try XCTUnwrap(GlucoseHistorySummary(samples: samples, days: 3, now: end, timeZone: TimeZone(identifier: "America/New_York")!))
        XCTAssertEqual(h.end.timeIntervalSince(h.start), 72 * 3600)
        XCTAssertEqual(h.windowStartLocal, "2026-10-30 13:00 (America/New_York, UTC-04:00)")
        XCTAssertEqual(h.windowEndLocal, "2026-11-02 12:00 (America/New_York, UTC-05:00)")
        XCTAssertEqual(h.daily.map(\.localDate), ["2026-10-30", "2026-11-02"])
        XCTAssertEqual(h.minimumLocalTime, h.windowStartLocal); XCTAssertEqual(h.maximumLocalTime, h.windowEndLocal)
    }

    func testHistoryPresentationReplacesOnlyLabelsNotNumbersOrDates() {
        let raw = "Historical glucose 2026-11-12: meanMgDl 115, minimumMgDl 100, maximumMgDl 130, observedBins 24."
        let rendered = AssistantReplyPresentation.format(raw, language: .english, evidence: [.history])
        XCTAssertFalse(rendered.contains("meanMgDl")); XCTAssertTrue(rendered.contains("mean glucose (mg/dL) 115"))
        XCTAssertEqual(ResponseValidator.numbers(raw), ResponseValidator.numbers(rendered))
        XCTAssertEqual(AssistantReplyPresentation.format(raw, language: .english, evidence: [.context]), raw)
    }

}
