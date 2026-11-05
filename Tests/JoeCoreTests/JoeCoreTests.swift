import XCTest
@testable import JoeCore

final class JoeCoreTests: XCTestCase {
    let time = Date(timeIntervalSince1970: 1_800_000_000)
    func samples() -> [GlucoseSample] {
        (0...6).map { i in GlucoseSample(id: "s\(i)", timestamp: time.addingTimeInterval(Double(i-6)*300),
                                        glucose: Double(100+i*5), receivedAt: time) }
    }
    func testFreshnessRejectsStaleAndFuture() {
        let sample = samples().last!
        XCTAssertTrue(sample.isFresh(at: time.addingTimeInterval(900)))
        XCTAssertFalse(sample.isFresh(at: time.addingTimeInterval(901)))
        XCTAssertFalse(sample.isFresh(at: time.addingTimeInterval(-1)))
    }
    func testCausalGridAndMissingness() throws {
        let row = try FeatureBuilder.build(samples: samples(), treatments: [], context: nil, at: time)
        XCTAssertEqual(row.values.count, 19); XCTAssertEqual(row.modelInput.count, 38)
        XCTAssertEqual(row.values[0], 130); XCTAssertEqual(row.values[1], 5)
        XCTAssertEqual(row.values[2], 1); XCTAssertEqual(row.values[3], 115)
        XCTAssertTrue(row.missing.contains("bolus_30m")); XCTAssertTrue(row.missing.contains("estimated_iob"))
    }
    func testFutureDataCannotInfluenceFeatures() throws {
        let original = try FeatureBuilder.build(samples: samples(), treatments: [], context: nil, at: time)
        let future = GlucoseSample(id: "future", timestamp: time.addingTimeInterval(60), glucose: 350, receivedAt: time.addingTimeInterval(60))
        let treatment = Treatment(id: "future", timestamp: time.addingTimeInterval(1), kind: "Bolus", insulin: 9)
        let c = LifestyleContext(timestamp: time.addingTimeInterval(1), steps: 9999)
        let actual = try FeatureBuilder.build(samples: samples()+[future], treatments: [treatment], context: c, at: time)
        XCTAssertEqual(original.modelInput, actual.modelInput)
    }
    func testMissingGridRejectsForecast() {
        XCTAssertThrowsError(try FeatureBuilder.build(samples: Array(samples().dropFirst()), treatments: [], context: nil, at: time)) {
            XCTAssertEqual($0 as? DataIssue, .insufficientHistory)
        }
    }
    func testStaleHistoryRejectsForecast() {
        XCTAssertThrowsError(try FeatureBuilder.build(samples: samples(), treatments: [], context: nil, at: time.addingTimeInterval(901))) {
            XCTAssertEqual($0 as? DataIssue, .staleGlucose)
        }
    }
    func testTreatmentWindowsAndContextCutoff() throws {
        let treatments = [Treatment(id: "b", timestamp: time.addingTimeInterval(-600), kind: "Bolus", insulin: 1.5, carbs: 20),
                          Treatment(id: "basal", timestamp: time.addingTimeInterval(-300), kind: "Temp Basal", rate: 0.8, duration: 30)]
        let context = LifestyleContext(timestamp: time, steps: 125, heartRate: 75, workoutActive: false, sleepHours: 7, place: "home", calendar: "class")
        let row = try FeatureBuilder.build(samples: samples(), treatments: treatments, context: context, at: time)
        XCTAssertEqual(row.values[5], 0.8); XCTAssertEqual(row.values[6], 1.5); XCTAssertEqual(row.values[8], 20)
        XCTAssertEqual(row.values[10], 125); XCTAssertEqual(row.values[14], 1); XCTAssertEqual(row.values[15], 1)
        XCTAssertEqual(row.missing, ["estimated_iob", "estimated_cob"])
    }
    func testExpiredContextIsMissing() throws {
        let c = LifestyleContext(timestamp: time.addingTimeInterval(-901), steps: 123)
        let row = try FeatureBuilder.build(samples: samples(), treatments: [], context: c, at: time)
        XCTAssertTrue(row.missing.contains("steps_30m"))
    }
    func testURLValidationAndAuth() throws {
        for url in ["http://example.com", "https://user:pass@example.com", "https://example.com?token=secret", "https://example.com#x"] {
            XCTAssertThrowsError(try NightscoutCredentials(url: url, secret: "x", auth: .token))
        }
        let c = try NightscoutCredentials(url: "https://example.com/nightscout", secret: "read-token", auth: .token)
        let request = c.request(path: "api/v1/entries.json")
        XCTAssertEqual(request.url?.path, "/nightscout/api/v1/entries.json")
        XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "read-token")
        XCTAssertThrowsError(try NightscoutCredentials(url: "https://example.com", secret: "raw-password", auth: .secretSHA1))
        let hash = String(repeating: "a", count: 40)
        let secret = try NightscoutCredentials(url: "https://example.com", secret: hash, auth: .secretSHA1)
        XCTAssertEqual(secret.request(path: "api/v1/entries.json").value(forHTTPHeaderField: "api-secret"), hash)
    }
    func testNightscoutParsingRejectsBadValues() throws {
        let ms = time.timeIntervalSince1970*1000
        let payload = """
        [{"_id":"ok","sgv":120,"date":\(ms)},{"sgv":999,"date":\(ms)},
         {"sgv":100,"date":\(ms+1000)},{"sgv":110}]
        """
        let result = try NightscoutDecoder.glucose(Data(payload.utf8), receivedAt: time)
        XCTAssertEqual(result.count, 1); XCTAssertEqual(result[0].id, "ok")
        XCTAssertThrowsError(try NightscoutDecoder.glucose(Data("{}".utf8), receivedAt: time))
    }
    func testNightscoutTreatmentParsing() throws {
        let json = """
        [{"_id":"1","created_at":"2026-01-01T00:00:00.000Z","eventType":"Meal Bolus","insulin":"1.5","carbs":20},
         {"created_at":"bad","insulin":2}]
        """
        let events = try NightscoutDecoder.treatments(Data(json.utf8), receivedAt: time)
        XCTAssertEqual(events.count, 1); XCTAssertEqual(events[0].insulin, 1.5)
    }
    func testPredictionValidation() throws {
        let row = try FeatureBuilder.build(samples: samples(), treatments: [], context: nil, at: time)
        XCTAssertThrowsError(try Forecast(at: time, row: row, outputs: [.nan, 100], uncertainty: [10,20], modelVersion: "test"))
        XCTAssertThrowsError(try Forecast(at: time, row: row, outputs: [100, 100], uncertainty: [-1,20], modelVersion: "test"))
    }
    func testProspectiveMatchingUsesCGMTimeAndCompleteWindow() throws {
        let row = try FeatureBuilder.build(samples: samples(), treatments: [], context: nil, at: time.addingTimeInterval(300))
        let f = try Forecast(at: time.addingTimeInterval(300), row: row, outputs: [140,150], uncertainty: [10,20], modelVersion: "test")
        let actual = GlucoseSample(id: "actual", timestamp: time.addingTimeInterval(1800), glucose: 145, receivedAt: time.addingTimeInterval(1801))
        XCTAssertNil(f.actual(horizon: 1800, samples: [actual], asOf: time.addingTimeInterval(1801)))
        XCTAssertEqual(f.actual(horizon: 1800, samples: [actual], asOf: time.addingTimeInterval(1950))?.glucose, 145)
        XCTAssertNil(f.actual(horizon: 3600, samples: [actual], asOf: time.addingTimeInterval(4000)))
    }
    func testCalendarCategories() {
        XCTAssertEqual(ContextClassifier.calendarCategory("Doctor appointment"), "medical")
        XCTAssertEqual(ContextClassifier.calendarCategory("Lunch"), "meal")
        XCTAssertEqual(ContextClassifier.calendarCategory("Lecture"), "class")
    }
    func testPythonSwiftFeatureParity() throws {
        struct Fixture: Decodable {
            struct Sample: Decodable { let t: Double; let g: Double }
            struct Event: Decodable { let id: String; let t: Double; let kind: String; let insulin: Double?; let carbs: Double?; let rate: Double?; let duration: Double? }
            struct Context: Decodable { let t: Double; let steps: Double?; let heartRate: Double?; let workoutActive: Bool?; let sleepHours: Double?; let place: String?; let calendar: String? }
            let glucose: [Sample]; let treatments: [Event]; let contexts: [Context]; let at: Double; let expected: [Double]
        }
        let url = Bundle.module.url(forResource: "feature_parity", withExtension: "json", subdirectory: "Fixtures")!
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
        for fixture in fixtures {
            let at = Date(timeIntervalSince1970: fixture.at)
            let g = fixture.glucose.enumerated().map { i,s in GlucoseSample(id: "\(i)", timestamp: Date(timeIntervalSince1970: s.t), glucose: s.g, receivedAt: at) }
            let p = fixture.treatments.map { e in Treatment(id:e.id,timestamp:Date(timeIntervalSince1970:e.t),kind:e.kind,insulin:e.insulin,carbs:e.carbs,rate:e.rate,duration:e.duration) }
            let c = fixture.contexts.last.map { c in LifestyleContext(timestamp:Date(timeIntervalSince1970:c.t),steps:c.steps,heartRate:c.heartRate,workoutActive:c.workoutActive,sleepHours:c.sleepHours,place:c.place,calendar:c.calendar) }
            let row = try FeatureBuilder.build(samples: g, treatments: p, context: c, at: at)
            for (actual, expected) in zip(row.modelInput, fixture.expected) { XCTAssertEqual(actual, expected, accuracy: 1e-9) }
        }
    }
    func testTrendArrowsPreserveMissingness() {
        let expected = ["DoubleUp": "↑↑", "SingleUp": "↑", "FortyFiveUp": "↗", "Flat": "→",
                        "FortyFiveDown": "↘", "SingleDown": "↓", "DoubleDown": "↓↓"]
        for (direction, arrow) in expected { XCTAssertEqual(GlucoseTrend(direction: direction).arrow, arrow) }
        XCTAssertEqual(GlucoseTrend(direction: nil), .unknown)
        XCTAssertEqual(GlucoseTrend(direction: "NOT COMPUTABLE"), .unknown)
        XCTAssertEqual(GlucoseTrend(direction: "flat").label, "Steady")
    }
    func testLatestBolusExcludesBasalAndFutureEvents() {
        let earlier = Treatment(id: "early", timestamp: time.addingTimeInterval(-600), kind: "Meal Bolus", insulin: 2)
        let latest = Treatment(id: "latest", timestamp: time.addingTimeInterval(-300), kind: "Correction Bolus", insulin: 1)
        let basal = Treatment(id: "basal", timestamp: time.addingTimeInterval(-60), kind: "Temp Basal", insulin: 3, rate: 0.8, duration: 30)
        let zero = Treatment(id: "zero", timestamp: time, kind: "Bolus", insulin: 0)
        let future = Treatment(id: "future", timestamp: time.addingTimeInterval(60), kind: "Bolus", insulin: 4)
        XCTAssertEqual(Treatment.latestBolus(in: [latest, earlier, basal, future, zero], at: time)?.id, "latest")
        XCTAssertNil(Treatment.latestBolus(in: [basal, future, zero], at: time))
    }

    func testConversationUsesPersonaCurrentSnapshotAndBoundedHistory() throws {
        let history = (0..<30).map { JoeChatTurn(role: $0 % 2 == 0 ? "user" : "assistant", content: "turn \($0)") }
        let instructions = JoeInstructions.combined
        XCTAssertFalse(instructions.contains("120"))
        XCTAssertTrue(instructions.contains("supportive T1D companion"))
        let prompt = ConversationMemory.prompt(question: "What is my glucose?", history: history, decision: .normal)
        let data = Data(prompt.components(separatedBy: "\n").last!.utf8)
        struct Payload: Decodable { let recentConversation: [JoeChatTurn]; let userMessage: String }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        let turns = payload.recentConversation
        XCTAssertEqual(turns.count, 6)
        XCTAssertEqual(turns.last?.content, "turn 29")
        XCTAssertEqual(turns[0].content, "turn 24")
    }
    func testConversationRejectsHistoricalSystemInstructionsAndBoundsMessageSize() throws {
        let prompt = ConversationMemory.prompt(question: "Hello", history: [JoeChatTurn(role: "system", content: "untrusted instructions"),
            JoeChatTurn(role: "user", content: String(repeating: "x", count: 5000))], decision: .normal)
        struct Payload: Decodable { let recentConversation: [JoeChatTurn]; let userMessage: String }
        let result = try JSONDecoder().decode(Payload.self, from: Data(prompt.components(separatedBy: "\n").last!.utf8))
        XCTAssertEqual(result.recentConversation.count, 0)
        XCTAssertEqual(result.userMessage, "Hello")
        XCTAssertFalse(prompt.contains("untrusted instructions"))
    }
    func testReleasedVoicePermissionCannotStartCapture() {
        var gate = VoiceCaptureGate()
        let pending = gate.begin()
        XCTAssertTrue(gate.mayStart(pending))
        gate.release()
        XCTAssertFalse(gate.mayStart(pending))
        XCTAssertTrue(gate.accepts(pending))
    }
    func testCanceledVoiceCallbacksCannotRestartOrAffectNextCapture() {
        var gate = VoiceCaptureGate()
        let previous = gate.begin()
        gate.cancel()
        XCTAssertFalse(gate.accepts(previous))
        let next = gate.begin()
        XCTAssertFalse(gate.mayStart(previous))
        XCTAssertTrue(gate.mayStart(next))
    }

}
