import XCTest
@testable import JoeCore

@MainActor final class PersonaRegressionTests: XCTestCase {
    func testVersionedBilingualFixturesFallbackAndSafety() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let model = FakeAssistantModel(); model.state = .modelNotReady
        let coordinator = AssistantCoordinator(provider: model)
        var reports: [AssistantTurnRecord] = []
        for item in PersonaRegressionCase.all {
            let snapshot = AssistantSnapshot(glucose: GlucoseSample(id: "synthetic", timestamp: now, glucose: 120, receivedAt: now),
                forecast: nil, treatments: [], context: nil, now: now)
            let turn = await coordinator.answer(item.text, snapshot: snapshot, history: [], regressionCaseID: item.id)
            XCTAssertEqual(ReplyLanguage(text: turn.response), item.language)
            XCTAssertEqual(turn.prompts, JoeInstructions.versions)
            XCTAssertEqual(turn.regressionCaseID, item.id)
            if !QuestionIntent(item.text).asksForData { XCTAssertFalse(turn.response.contains("120")) }
            XCTAssertFalse(turn.response.isEmpty)
            reports.append(turn)
        }
        XCTAssertEqual(model.calls, 0)
        if let output = ProcessInfo.processInfo.environment["JOE_REGRESSION_REPORT"] {
            struct Report: Encodable {
                let suite: String
                let execution: String
                let liveFoundationModelExecuted: Bool
                let manualToneReview: String
                let results: [AssistantTurnRecord]
            }
            let report = Report(suite: PersonaRegressionCase.version, execution: "deterministic-fallback-tests",
                liveFoundationModelExecuted: false, manualToneReview: "not evaluated", results: reports)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(report).write(to: URL(fileURLWithPath: output))
        }
    }
    func testDoseQuestionsBypassModelInBothLanguages() async {
        let model = FakeAssistantModel(); let coordinator = AssistantCoordinator(provider: model)
        for text in ["How much insulin should I take?", "\u{5e94}\u{8be5}\u{6253}\u{591a}\u{5c11}\u{5355}\u{4f4d}？"] {
            let now = Date()
            let s = AssistantSnapshot(glucose: GlucoseSample(id: "g", timestamp: now, glucose: 120, receivedAt: now), forecast: nil, treatments: [], context: nil, now: now)
            let reply = await coordinator.answer(text, snapshot: s, history: [])
            XCTAssertEqual(ReplyLanguage(text: reply.response), ReplyLanguage(text: text))
            XCTAssertTrue(reply.mode.contains("Swift safety"))
        }
        XCTAssertEqual(model.calls, 0)
    }
}
