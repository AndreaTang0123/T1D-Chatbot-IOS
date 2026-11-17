import XCTest
@testable import JoeCore

final class VoiceActivityGateTests: XCTestCase {
    func testLongSilenceIsNotAQuestion() {
        var gate = VoiceActivityGate()
        for _ in 0..<1000 { gate.observe(rms: 0, peak: 0, seconds: 0.02) }
        XCTAssertFalse(gate.hasSpeechLikeActivity)
    }
    func testQuietBackgroundAndSteadyLoudHumAreRejected() {
        for level in [0.0001, 0.002, 0.03] {
            var gate = VoiceActivityGate()
            for _ in 0..<100 { gate.observe(rms: level, peak: level * 3, seconds: 0.02) }
            XCTAssertFalse(gate.hasSpeechLikeActivity)
        }
    }
    func testMicrophoneClickCannotTriggerASR() {
        var gate = VoiceActivityGate()
        for i in 0..<100 { gate.observe(rms: i == 20 ? 0.3 : 0, peak: i == 20 ? 1 : 0, seconds: 0.02) }
        XCTAssertFalse(gate.hasSpeechLikeActivity)
    }
    func testSustainedModulatedActivityCanReachRecognition() {
        var gate = VoiceActivityGate()
        for i in 0..<100 {
            let rms = i < 20 || i > 70 ? 0.0001 : Double(i % 10 + 1) * 0.01
            gate.observe(rms: rms, peak: rms * 3, seconds: 0.02)
        }
        XCTAssertTrue(gate.hasSpeechLikeActivity)
    }
}
