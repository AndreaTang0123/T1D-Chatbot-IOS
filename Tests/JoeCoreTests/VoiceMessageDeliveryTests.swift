import XCTest
@testable import JoeCore

final class VoiceMessageDeliveryTests: XCTestCase {
    func testOneSubmittedBubbleBecomesOneRecognizedQuestion() {
        let id = UUID(); var delivery = VoiceMessageDelivery(id: id)
        XCTAssertTrue(delivery.isPending); XCTAssertNil(delivery.recognizedText)
        XCTAssertTrue(delivery.recognize("  How many steps today? \n"))
        XCTAssertEqual(delivery.id, id)
        XCTAssertEqual(delivery.recognizedText, "How many steps today?")
        XCTAssertFalse(delivery.isPending)
        XCTAssertFalse(delivery.recognize("A duplicate callback"))
        XCTAssertFalse(delivery.cancel())
    }
    func testCancelIgnoresLateRecognitionAndFailure() {
        var delivery = VoiceMessageDelivery(id: UUID())
        XCTAssertTrue(delivery.cancel())
        XCTAssertFalse(delivery.recognize("Old result"))
        XCTAssertFalse(delivery.fail("Old failure"))
        XCTAssertEqual(delivery.state, .cancelled)
        XCTAssertNil(delivery.recognizedText)
    }
    func testFailureStopsSpinnerAndNeverCreatesAQuestion() {
        var delivery = VoiceMessageDelivery(id: UUID())
        XCTAssertTrue(delivery.fail("No speech detected"))
        XCTAssertFalse(delivery.isPending)
        XCTAssertNil(delivery.recognizedText)
        XCTAssertFalse(delivery.recognize("A late result"))
    }
    func testEmptyResultCannotTriggerAnEmptyAutomaticTurn() {
        var delivery = VoiceMessageDelivery(id: UUID())
        XCTAssertFalse(delivery.recognize(" \n"))
        XCTAssertTrue(delivery.isPending)
        XCTAssertNil(delivery.recognizedText)
        XCTAssertTrue(delivery.fail("No usable speech"))
    }
    func testRepeatedSpokenWordsInDifferentRecordingsAreIndependentTurns() {
        var first = VoiceMessageDelivery(id: UUID())
        var second = VoiceMessageDelivery(id: UUID())
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertTrue(first.recognize("My glucose?")); XCTAssertTrue(second.recognize("My glucose?"))
    }
}
