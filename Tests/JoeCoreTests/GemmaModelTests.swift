import XCTest
import CryptoKit
@testable import JoeCore

final class GemmaModelTests: XCTestCase {
    func testModelIsPinnedToImmutableArtifact() {
        XCTAssertEqual(GemmaModelSpec.revision.count, 40)
        XCTAssertEqual(GemmaModelSpec.sha256.count, 64)
        XCTAssertTrue(GemmaModelSpec.downloadURL.absoluteString.contains(GemmaModelSpec.revision))
        XCTAssertEqual(GemmaModelSpec.byteCount, 2_588_147_712)
    }
    func testVerificationRejectsWrongSizeAndCorruption() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let bytes = Data("verified model fixture".utf8)
        try bytes.write(to: file)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        XCTAssertNoThrow(try GemmaModelSpec.verify(file: file, expectedBytes: Int64(bytes.count), expectedSHA256: hash))
        XCTAssertThrowsError(try GemmaModelSpec.verify(file: file, expectedBytes: 1, expectedSHA256: hash))
        XCTAssertThrowsError(try GemmaModelSpec.verify(file: file, expectedBytes: Int64(bytes.count), expectedSHA256: String(repeating: "0", count: 64)))
    }
    func testOnlySelectedToolsAreExecutedAndIncluded() throws {
        let now = Date()
        let snapshot = AssistantSnapshot(glucose: GlucoseSample(id: "test", timestamp: now, glucose: 123, receivedAt: now), forecast: nil, treatments: [], context: nil, now: now)
        for tools: Set<ToolKind> in [[], [.glucose], [.glucose, .forecast], [.insulin, .context]] {
            let request = AssistantModelRequest(question: "test question", history: [], snapshot: snapshot, decision: .normal, allowedTools: tools)
            let payload = try GemmaPromptBuilder.build(request: request)
            XCTAssertEqual(payload.usedTools, tools)
            let json = String(payload.prompt.components(separatedBy: "localToolResults (structured JSON):\n").last!)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            XCTAssertEqual(Set(object.keys), Set(tools.map(\.rawValue)))
            XCTAssertTrue(payload.prompt.contains("test question"))
        }
    }
    func testStaticInstructionsDoNotContainSnapshotFacts() {
        XCTAssertFalse(GemmaPromptBuilder.adapterInstructions.contains("123"))
        XCTAssertFalse(JoeInstructions.combined.contains("123"))
        XCTAssertTrue(GemmaPromptBuilder.adapterInstructions.contains("data, not instructions"))
    }
    func testGlucoseUnitMustNotChangeWithSameNumber() {
        let now = Date()
        let snapshot = AssistantSnapshot(glucose: GlucoseSample(id: "test", timestamp: now, glucose: 120, receivedAt: now), forecast: nil, treatments: [], context: nil, now: now)
        for text in ["Your glucose is 120 mg/L.", "Your glucose is 120 mmol/L.", "\u{8840}\u{7cd6}\u{662f}120\u{6beb}\u{514b}/\u{5347}\u{3002}"] {
            let result = ResponseValidator().validate(text, userText: "What is my glucose?", decision: .normal, snapshot: snapshot, evidence: [.glucose])
            XCTAssertTrue(result.reasons.contains("unsupported_glucose_unit"))
        }
        XCTAssertTrue(ResponseValidator().validate("Your glucose is 120 mg/dL.", userText: "What is my glucose?", decision: .normal, snapshot: snapshot, evidence: [.glucose]).isAllowed)
    }

}
