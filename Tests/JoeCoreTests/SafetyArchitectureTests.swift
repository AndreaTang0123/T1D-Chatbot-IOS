import XCTest
@testable import JoeCore

@MainActor final class FakeAssistantModel: AssistantModelProvider {
    var runtimeVersion = "fake-model.v1"
    var state: ModelAvailability = .available
    var calls = 0
    var reply = ModelReply(text: "I'm here with you.", usedTools: [])
    var failure: AssistantFailure?
    func availability(language: ReplyLanguage) -> ModelAvailability { state }
    func prewarm() {}
    func respond(to request: AssistantModelRequest) async throws -> ModelReply {
        calls += 1
        if let failure { throw failure }
        return reply
    }
}
@MainActor final class SafetyArchitectureTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func snapshot(value: Double? = 120, age: TimeInterval = 0, context: LifestyleContext? = nil,
                  treatments: [Treatment] = [], forecast: Forecast? = nil, riskThreshold: Double? = nil) -> AssistantSnapshot {
        AssistantSnapshot(glucose: value.map { GlucoseSample(id: "test", timestamp: now.addingTimeInterval(-age), glucose: $0, direction: "Flat", receivedAt: now) },
            forecast: forecast, treatments: treatments, context: context, now: now,
            policy: SafetyPolicy(hypoRiskThreshold: riskThreshold))
    }
    func forecast(risk: Double? = nil) throws -> Forecast {
        let g = (0...6).map { GlucoseSample(id: "g\($0)", timestamp: now.addingTimeInterval(Double($0-6)*300), glucose: 120, receivedAt: now) }
        let row = try FeatureBuilder.build(samples: g, treatments: [], context: nil, at: now)
        let f = try Forecast(at: now, row: row, outputs: [140, 150], uncertainty: [10, 20], modelVersion: "fixture.v1")
        guard let risk else { return f }
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(f)) as! [String: Any]
        object["lowRisk"] = risk
        return try JSONDecoder().decode(Forecast.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func testSafetyPriorityRejectsMissingAndInvalidBeforeRisk() throws {
        let engine = SafetyDecisionEngine()
        for value in [nil, Double.nan, -1, 401] {
            let s = snapshot(value: value, forecast: try forecast(risk: 0.9), riskThreshold: 0.5)
            XCTAssertEqual(engine.evaluate(cgm: s.currentGlucose, forecast: s.forecastResult), .noData)
        }
    }
    func testStaleLowIsHistoricalNotUrgentCurrent() {
        let s = snapshot(value: 55, age: 901)
        XCTAssertEqual(SafetyDecisionEngine().evaluate(cgm: s.currentGlucose, forecast: s.forecastResult), .staleData(ageMinutes: 15))
    }
    func testLowHighAndBoundaryPriority() {
        for (value, expected) in [(55.0, SafetyDecision.urgentLow(glucose: 55)), (260, .urgentHigh(glucose: 260)), (70, .normal), (250, .normal)] {
            let s = snapshot(value: value)
            XCTAssertEqual(SafetyDecisionEngine().evaluate(cgm: s.currentGlucose, forecast: s.forecastResult), expected)
        }
    }
    func testRiskRequiresCalibratedScoreAndConfiguredThreshold() throws {
        let f = try forecast(risk: 0.8)
        let disabled = snapshot(forecast: f)
        XCTAssertNil(disabled.forecastResult.hypoRisk60m)
        let enabled = snapshot(forecast: f, riskThreshold: 0.5)
        XCTAssertEqual(SafetyDecisionEngine(policy: enabled.policy).evaluate(cgm: enabled.currentGlucose, forecast: enabled.forecastResult), .forecastRisk)
        let low = snapshot(value: 55, forecast: f, riskThreshold: 0.5)
        XCTAssertEqual(SafetyDecisionEngine(policy: low.policy).evaluate(cgm: low.currentGlucose, forecast: low.forecastResult), .urgentLow(glucose: 55))
    }
    func testFutureCGMIsUnavailableAndForecastMismatchRejected() throws {
        XCTAssertEqual(snapshot(age: -1).currentGlucose.status, .unavailable)
        XCTAssertFalse(snapshot(value: 120, age: 300, forecast: try forecast()).forecastResult.available)
    }
    func testStructuredInsulinNeverGuessesIOBOrZeroDelivery() {
        let missing = snapshot().recentInsulin
        XCTAssertNil(missing.latestBolusUnits); XCTAssertNil(missing.estimatedIOB)
        let event = Treatment(id: "b", timestamp: now.addingTimeInterval(-7*3600), kind: "Bolus", insulin: 1.5)
        let s = snapshot(treatments: [event]).recentInsulin
        XCTAssertEqual(s.status, .stale); XCTAssertEqual(s.dataAgeMinutes, 420)
    }
    func testContextUsesSemanticCategoriesAndNextEventTime() throws {
        let context = LifestyleContext(timestamp: now, steps: 300, place: "school", calendar: "class")
        let s = AssistantSnapshot(glucose: nil, forecast: nil, treatments: [], context: context, now: now,
            nextEventCategory: "meeting", nextEventStart: now.addingTimeInterval(1800), currentEventEnd: now.addingTimeInterval(-1))
        let c = s.currentContext
        XCTAssertNil(c.currentEventCategory); XCTAssertEqual(c.minutesUntilNextEvent, 30)
        let json = try ToolJSON.encode(c)
        XCTAssertFalse(json.contains("latitude")); XCTAssertFalse(json.contains("title"))
    }
    func testQuestionRoutingDoesNotDefaultToAllTools() {
        XCTAssertEqual(QuestionIntent("I feel exhausted").tools, [])
        XCTAssertEqual(QuestionIntent("What is my glucose?").tools, [.glucose])
        XCTAssertEqual(QuestionIntent("Explain my forecast").tools, [.glucose, .forecast])
        XCTAssertEqual(QuestionIntent("Why high after a meal?").tools, [.glucose, .forecast, .insulin])
        XCTAssertEqual(QuestionIntent("\u{6211}\u{4e00}\u{5c0f}\u{65f6}\u{540e}\u{8981}\u{4e0a}\u{8bfe}").tools, [])
        XCTAssertEqual(QuestionIntent("What is my next class?").tools, [.context])
    }
    func testNoDataAndStaleQuestionsBypassModel() async {
        let model = FakeAssistantModel(); let coordinator = AssistantCoordinator(provider: model)
        let noData = await coordinator.answer("What is my glucose?", snapshot: snapshot(value: nil), history: [])
        XCTAssertEqual(noData.decision, .noData); XCTAssertEqual(model.calls, 0)
        let stale = await coordinator.answer("\u{8840}\u{7cd6}\u{591a}\u{5c11}？", snapshot: snapshot(age: 901), history: [])
        XCTAssertTrue(stale.response.contains("\u{8fc7}\u{671f}")); XCTAssertEqual(model.calls, 0)
    }
    func testImmediateLowHighBypassModelEvenForSmallTalk() async {
        let model = FakeAssistantModel(); let coordinator = AssistantCoordinator(provider: model)
        for value in [55.0, 260.0] {
            let result = await coordinator.answer("Hello", snapshot: snapshot(value: value), history: [])
            XCTAssertTrue(result.mode.contains("Swift safety"))
        }
        XCTAssertEqual(model.calls, 0)
    }
    func testMissingModelAndLanguageFailuresRemainSeparate() async {
        let model = FakeAssistantModel(); let coordinator = AssistantCoordinator(provider: model)
        for state in [ModelAvailability.intelligenceDisabled, .unsupportedDevice, .modelNotReady, .unsupportedLanguage] {
            model.state = state
            let result = await coordinator.answer("Hello", snapshot: snapshot(), history: [])
            XCTAssertEqual(result.availability, state); XCTAssertTrue(result.mode.contains(state.rawValue))
        }
        XCTAssertEqual(model.calls, 0)
    }
    func testGenerationAndToolFailuresFallbackWithoutRetry() async {
        let model = FakeAssistantModel(); let coordinator = AssistantCoordinator(provider: model)
        for failure in [AssistantFailure.contextSizeExceeded, .toolFailure, .unsupportedLanguage, .generationError] {
            model.failure = failure
            let result = await coordinator.answer("What is my glucose?", snapshot: snapshot(), history: [])
            XCTAssertEqual(result.failure, failure); XCTAssertTrue(result.response.contains("120"))
        }
        XCTAssertEqual(model.calls, 4)
    }
    func testUnsupportedValueRejectedWithoutSelfRepair() async {
        let model = FakeAssistantModel()
        model.reply = ModelReply(text: "Your glucose is 222 mg/dL.", usedTools: [.glucose])
        let result = await AssistantCoordinator(provider: model).answer("What is my glucose?", snapshot: snapshot(), history: [])
        XCTAssertTrue(result.validationReasons.contains("unsupported_number")); XCTAssertTrue(result.response.contains("120"))
        XCTAssertFalse(result.response.contains("222")); XCTAssertEqual(model.calls, 1)
    }
    func testKnownValuesStillRequireActualToolUse() async {
        let model = FakeAssistantModel(); model.reply = ModelReply(text: "Your glucose is 120 mg/dL.", usedTools: [])
        let result = await AssistantCoordinator(provider: model).answer("What is my glucose?", snapshot: snapshot(), history: [])
        XCTAssertTrue(result.validationReasons.contains("glucose_without_tool"))
    }
    func testValidGroundedResponseAcceptedAndVersioned() async throws {
        let model = FakeAssistantModel(); model.reply = ModelReply(text: "Your latest measurement is 120 mg/dL from 0 minutes ago.", usedTools: [.glucose])
        let result = await AssistantCoordinator(provider: model).answer("What is my glucose?", snapshot: snapshot(), history: [])
        XCTAssertEqual(result.mode, "Apple on-device · Validated"); XCTAssertEqual(result.validationReasons, [])
        XCTAssertEqual(result.prompts, JoeInstructions.versions); XCTAssertEqual(result.foundationModelVersion, "fake-model.v1")
        let decoded = try JSONDecoder().decode(AssistantTurnRecord.self, from: JSONEncoder().encode(result))
        XCTAssertEqual(decoded.prompts, result.prompts)
        let historical = PromptVersions(persona: "old.v0", safety: "old.safety", explanation: "old.explanation")
        XCTAssertEqual(try JSONDecoder().decode(PromptVersions.self, from: JSONEncoder().encode(historical)), historical)
    }
    func testValidatorRejectsDosingLanguageCausalityAndUnsupportedContext() {
        let validator = ResponseValidator(); let s = snapshot()
        for response in ["Take two units of insulin.", "Increase your basal rate.", "Your glucose is high because you slept badly.", "Your sleep was 8 hours."] {
            XCTAssertFalse(validator.validate(response, userText: "How am I doing?", decision: .normal, snapshot: s, evidence: []).isAllowed)
        }
    }
    func testValidatorRejectsLanguageMismatchAndUnsolicitedNormalGlucose() {
        let validator = ResponseValidator(); let s = snapshot()
        XCTAssertTrue(validator.validate("Your glucose is 120 mg/dL.", userText: "\u{8840}\u{7cd6}\u{591a}\u{5c11}？", decision: .normal, snapshot: s, evidence: [.glucose]).reasons.contains("language_mismatch"))
        XCTAssertTrue(validator.validate("Your glucose is 120 mg/dL.", userText: "I'm tired", decision: .normal, snapshot: s, evidence: [.glucose]).reasons.contains("unsolicited_normal_glucose"))
    }
    func testForecastRequiresUncertaintyAndCannotBeCurrent() throws {
        let s = snapshot(forecast: try forecast()); let validator = ResponseValidator()
        let missing = validator.validate("The prediction is 140 mg/dL in 30 minutes.", userText: "My forecast?", decision: .normal, snapshot: s, evidence: [.forecast])
        XCTAssertTrue(missing.reasons.contains("forecast_without_uncertainty"))
        let wrong = validator.validate("Your current glucose is the predicted 140 mg/dL with error 10.", userText: "My forecast?", decision: .normal, snapshot: s, evidence: [.forecast, .glucose])
        XCTAssertTrue(wrong.reasons.contains("prediction_as_current"))
    }
    func testLateDataExpiryIsRecheckable() {
        let s = snapshot(age: 899)
        XCTAssertEqual(s.currentGlucose.status, .fresh)
        XCTAssertEqual(s.rechecked(at: now.addingTimeInterval(2)).currentGlucose.status, .stale)
    }
    func testInstructionsContainNoSnapshotOrThresholdsAndMemoryExcludesOldClinicalSummary() {
        XCTAssertFalse(JoeInstructions.combined.contains("120")); XCTAssertFalse(JoeInstructions.persona.contains("70"))
        let history = [JoeChatTurn(role: "user", content: "My glucose was 222")] + (0..<6).map { JoeChatTurn(role: "assistant", content: "Okay \($0)") }
        let prompt = ConversationMemory.prompt(question: "Hi", history: history, decision: .normal)
        XCTAssertFalse(prompt.contains("222"))
    }
    func testDoseIntentDistinguishesRecommendationsFromRecordQueries() {
        XCTAssertTrue(QuestionIntent("Should I bolus?").dose)
        XCTAssertTrue(QuestionIntent("Do I need a bolus?").dose)
        XCTAssertFalse(QuestionIntent("Can I see my last bolus?").dose)
    }

}
