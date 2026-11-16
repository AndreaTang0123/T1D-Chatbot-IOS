import XCTest
@testable import JoeCore

final class GemmaAudioQuestionTests: XCTestCase {
    func testUnderstoodQuestionPreservesNumbersDatesAndLanguageForUserReview() throws {
        XCTAssertEqual(try GemmaAudioQuestion.checkedText("  Was my bolus 0.3 units at 11:59 yesterday?\n"), "Was my bolus 0.3 units at 11:59 yesterday?")
        XCTAssertEqual(try GemmaAudioQuestion.checkedText("昨天11:59的记录是多少单位？"), "昨天11:59的记录是多少单位？")
    }
    func testUnusableAudioResultDoesNotBecomeAChatQuestion() {
        for output in ["", " \n", "[NO_SPEECH]", "<|channel>analysis", "<tool_call>insulin", String(repeating: "a", count: 2001)] {
            XCTAssertThrowsError(try GemmaAudioQuestion.checkedText(output))
        }
    }
    func testAudioTaskRemainsSeparateFromJoeAnsweringInstructions() {
        XCTAssertTrue(GemmaAudioQuestion.instructions.contains("Do not answer"))
        XCTAssertTrue(GemmaAudioQuestion.prompt(locale: "zh-CN").contains("Mandarin Chinese"))
        XCTAssertTrue(GemmaAudioQuestion.prompt(locale: "en-US").contains("English"))
    }
}
