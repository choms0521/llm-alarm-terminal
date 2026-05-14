import XCTest
import Foundation

final class NeedsInputPolicyV1Tests: XCTestCase {

    private let policy = NeedsInputPolicyV1()

    // MARK: - 1. white-list 패턴 매칭

    func test_detect_doYouWantToApplyThisChange_yn_returnsTrue() {
        XCTAssertTrue(policy.detect(in: "Do you want to apply this change? [y/n]"))
    }

    func test_detect_doYouWantToProceed_returnsTrue() {
        XCTAssertTrue(policy.detect(in: "Do you want to proceed?"))
    }

    func test_detect_pressEnterToContinue_returnsTrue() {
        XCTAssertTrue(policy.detect(in: "Press Enter to continue"))
    }

    func test_detect_ynBracket_returnsTrue() {
        XCTAssertTrue(policy.detect(in: "Choose option [y/n]"))
    }

    // MARK: - 2. 80 bytes window 검사

    func test_detect_patternOutside80ByteWindow_returnsFalse() {
        let prefix = "Do you want to apply this change? [y/n]"
        // utf8 100 bytes 분량의 padding 으로 prefix 패턴을 80-byte tail window 외부로 밀어낸다.
        let padding = String(repeating: "x", count: 200)
        let composed = prefix + padding
        XCTAssertFalse(policy.detect(in: composed))
    }

    // MARK: - 3. FP 차단

    func test_detect_promptArrowWithoutSGRReset_returnsFalse() {
        XCTAssertFalse(policy.detect(in: "cat README.md 결과: ❯ 화살표 기호"))
    }

    func test_detect_bareArrow_returnsFalse() {
        XCTAssertFalse(policy.detect(in: "❯ "))
    }

    // MARK: - 4. claude REPL prompt 매칭

    func test_detect_claudeReplPromptWithSGRReset0m_returnsTrue() {
        XCTAssertTrue(policy.detect(in: "\u{1b}[0m❯ "))
    }

    func test_detect_claudeReplPromptWithSGRReset39m_returnsTrue() {
        XCTAssertTrue(policy.detect(in: "\u{1b}[39m❯ "))
    }

    func test_detect_claudeReplPromptInTail_returnsTrue() {
        let viewport = "some output\n\u{1b}[0m❯ "
        XCTAssertTrue(policy.detect(in: viewport))
    }

    // MARK: - 5. version 식별

    func test_version_equalsV1May2026() {
        XCTAssertEqual(policy.version, "v1-2026-05")
    }

    // MARK: - 6. 부정 케이스

    func test_detect_emptyString_returnsFalse() {
        XCTAssertFalse(policy.detect(in: ""))
    }

    func test_detect_plainKoreanFinishedMessage_returnsFalse() {
        XCTAssertFalse(policy.detect(in: "분석을 마쳤습니다."))
    }

    func test_detect_koreanTextNoPattern_returnsFalse() {
        XCTAssertFalse(policy.detect(in: "안녕하세요 한글만 있는 평범한 출력입니다"))
    }
}
