import XCTest
import SwiftUI

final class AnsiSGRParserTests: XCTestCase {

    private func plain(_ s: AttributedString) -> String { String(s.characters) }

    // MARK: - 1. fg/bg 기본 8 색

    func test_parse_red_foreground() {
        let r = AnsiSGRParser.parse("\u{1b}[31mhello\u{1b}[0m")
        XCTAssertEqual(plain(r), "hello")
        let runs = Array(r.runs)
        XCTAssertEqual(runs.first?.foregroundColor, Color.red)
    }

    func test_parse_green_foreground() {
        let r = AnsiSGRParser.parse("\u{1b}[32mok\u{1b}[0m")
        XCTAssertEqual(plain(r), "ok")
        let runs = Array(r.runs)
        XCTAssertEqual(runs.first?.foregroundColor, Color.green)
    }

    // MARK: - 2. truecolor 38;2;R;G;B

    func test_parse_truecolor_foreground() {
        let r = AnsiSGRParser.parse("\u{1b}[38;2;128;64;255mtruecolor\u{1b}[0m")
        XCTAssertEqual(plain(r), "truecolor")
        let runs = Array(r.runs)
        // SwiftUI Color 비교는 sRGB 컴포넌트로만 식별 가능. 단지 색이 .primary 가 아님을 검증.
        XCTAssertNotNil(runs.first?.foregroundColor)
        XCTAssertNotEqual(runs.first?.foregroundColor, .primary)
    }

    // MARK: - 3. 256 팔레트 38;5;N

    func test_parse_palette256_196() {
        let r = AnsiSGRParser.parse("\u{1b}[38;5;196m256\u{1b}[0m")
        XCTAssertEqual(plain(r), "256")
        let runs = Array(r.runs)
        XCTAssertNotNil(runs.first?.foregroundColor)
    }

    func test_parse_palette256_0to7_mapsToBasic() {
        let r = AnsiSGRParser.parse("\u{1b}[38;5;1mA\u{1b}[0m")
        XCTAssertEqual(Array(r.runs).first?.foregroundColor, Color.red)
    }

    // MARK: - 4. bold 1/22 on/off

    func test_parse_bold_on() {
        let r = AnsiSGRParser.parse("\u{1b}[1mBOLD\u{1b}[0m")
        XCTAssertEqual(plain(r), "BOLD")
        XCTAssertNotNil(Array(r.runs).first?.font)
    }

    func test_parse_bold_offWithReset() {
        let r = AnsiSGRParser.parse("\u{1b}[1mBOLD\u{1b}[0mplain")
        XCTAssertEqual(plain(r), "BOLDplain")
        let runs = Array(r.runs)
        XCTAssertGreaterThanOrEqual(runs.count, 2)
        XCTAssertNil(runs.last?.font)
    }

    // MARK: - 5. 미지원 코드 silently drop

    func test_parse_blink5_silentlyDropped_plainTextRemains() {
        let r = AnsiSGRParser.parse("\u{1b}[5mblink\u{1b}[0m")
        XCTAssertEqual(plain(r), "blink")
    }

    func test_parse_reverse7_silentlyDropped() {
        let r = AnsiSGRParser.parse("\u{1b}[7mrev\u{1b}[0m")
        XCTAssertEqual(plain(r), "rev")
    }

    // MARK: - 6. CR 처리

    func test_parse_crlf_normalizedToLf() {
        let r = AnsiSGRParser.parse("plain\r\nnext")
        XCTAssertEqual(plain(r), "plain\nnext")
    }

    func test_parse_bareCr_dropsCurrentLinePrefix() {
        let r = AnsiSGRParser.parse("first\rsecond")
        XCTAssertEqual(plain(r), "second")
    }

    // MARK: - 7. ESC byte 결과 미포함

    func test_parse_resultHasNoRawEsc() {
        let r = AnsiSGRParser.parse("\u{1b}[31m한국어\u{1b}[0m")
        XCTAssertFalse(plain(r).contains("\u{1b}"))
    }

    // MARK: - 8. bg basic + 49 default reset

    func test_parse_bg_yellow() {
        let r = AnsiSGRParser.parse("\u{1b}[43mbg\u{1b}[0m")
        XCTAssertEqual(plain(r), "bg")
        XCTAssertEqual(Array(r.runs).first?.backgroundColor, Color.yellow)
    }

    // MARK: - 9. SGR ;; 다중 파라미터

    func test_parse_compoundParams_1Semi31_boldAndRed() {
        let r = AnsiSGRParser.parse("\u{1b}[1;31mboldred\u{1b}[0m")
        XCTAssertEqual(plain(r), "boldred")
        let first = Array(r.runs).first
        XCTAssertNotNil(first?.foregroundColor)
        XCTAssertNotNil(first?.font)
    }
}
