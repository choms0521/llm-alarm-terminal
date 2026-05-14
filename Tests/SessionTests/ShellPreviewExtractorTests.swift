import XCTest
import Foundation

final class ShellPreviewExtractorTests: XCTestCase {

    // MARK: - 3-조건 conjunction prompt 검출

    func test_extract_promptOnly_returnsNil() {
        XCTAssertNil(ShellPreviewExtractor.extract("user@host % "))
    }

    func test_extract_outputThenPrompt_returnsOutput() {
        let r = ShellPreviewExtractor.extract("output line\nuser@host % ")
        XCTAssertEqual(r, "output line")
    }

    func test_extract_commandThenKoreanOutputThenClaudePrompt_returnsKorean() {
        let r = ShellPreviewExtractor.extract("user@host % command\n결과: 한국어 출력\n❯ ")
        XCTAssertEqual(r, "결과: 한국어 출력")
    }

    func test_extract_dollarPrompt_dropped() {
        let r = ShellPreviewExtractor.extract("npm test\nall tests passed\n$ ")
        XCTAssertEqual(r, "all tests passed")
    }

    func test_extract_hashPrompt_dropped() {
        let r = ShellPreviewExtractor.extract("root output\n# ")
        XCTAssertEqual(r, "root output")
    }

    // MARK: - OSC 133 우선 영역

    func test_extract_osc133_commandOutputRegion_returnsLastLine() {
        let input = "\u{1b}]133;A\u{1b}\\user@host % \u{1b}]133;B\u{1b}\\ls\n결과"
        XCTAssertEqual(ShellPreviewExtractor.extract(input), "결과")
    }

    func test_extract_osc133_withDMarker_endsAtD() {
        let input = "\u{1b}]133;A\u{1b}\\prompt\u{1b}]133;B\u{1b}\\cmd\nresult\u{1b}]133;D;0\u{1b}\\"
        XCTAssertEqual(ShellPreviewExtractor.extract(input), "result")
    }

    func test_extract_osc133_external_fallbackHandles() {
        let input = "prefix raw text\n\u{1b}]133;A\u{1b}\\cmd\nresult"
        XCTAssertEqual(ShellPreviewExtractor.extract(input), "result")
    }

    // MARK: - RPROMPT 처리

    func test_extract_rprompt_dropsRightSide() {
        let r = ShellPreviewExtractor.extract("left prompt\u{1b}[100Cright prompt")
        XCTAssertEqual(r, "left prompt")
    }

    // MARK: - CR 처리

    func test_extract_crlfNormalized() {
        let r = ShellPreviewExtractor.extract("first\r\nsecond")
        XCTAssertEqual(r, "second")
    }

    func test_extract_bareCr_dropsCurrentLinePrefix() {
        let r = ShellPreviewExtractor.extract("aaaa\rfinal")
        XCTAssertEqual(r, "final")
    }

    // MARK: - ANSI strip 결과 ESC 미포함

    func test_extract_resultHasNoRawEsc() {
        let r = ShellPreviewExtractor.extract("\u{1b}[31m한국어 출력\u{1b}[0m\nuser@host % ")
        XCTAssertEqual(r, "한국어 출력")
        XCTAssertFalse(r!.contains("\u{1b}"))
    }

    // MARK: - 빈 / 공백 케이스

    func test_extract_empty_returnsNil() {
        XCTAssertNil(ShellPreviewExtractor.extract(""))
    }

    func test_extract_onlyNewlines_returnsNil() {
        XCTAssertNil(ShellPreviewExtractor.extract("\n\n\n"))
    }
}
