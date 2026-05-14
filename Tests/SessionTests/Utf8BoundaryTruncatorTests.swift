import XCTest
import Foundation

final class Utf8BoundaryTruncatorTests: XCTestCase {

    // MARK: - 한국어 grapheme cluster 보존

    func test_truncate_hangul_3graphemes() {
        let r = Utf8BoundaryTruncator.truncate("가나다라마바사", maxGraphemes: 3)
        XCTAssertEqual(r, "가나다")
    }

    func test_truncate_hangul_lessThanMax_returnsSame() {
        let r = Utf8BoundaryTruncator.truncate("가나다", maxGraphemes: 10)
        XCTAssertEqual(r, "가나다")
    }

    // MARK: - ZWJ emoji 1 grapheme cluster 보존

    func test_truncate_zwjFamilyEmoji_count2() {
        let s = "a👨‍👩‍👧‍👦b"
        let r = Utf8BoundaryTruncator.truncate(s, maxGraphemes: 2)
        XCTAssertEqual(r, "a👨‍👩‍👧‍👦")
        XCTAssertEqual(r.count, 2)
    }

    func test_truncate_zwjFamilyEmoji_unicodeScalarsCount() {
        let s = "a👨‍👩‍👧‍👦b"
        let r = Utf8BoundaryTruncator.truncate(s, maxGraphemes: 2)
        XCTAssertGreaterThanOrEqual(r.unicodeScalars.count, 8, "ZWJ family should keep all scalars")
    }

    // MARK: - ASCII

    func test_truncate_ascii_5char() {
        let r = Utf8BoundaryTruncator.truncate("abcdefgh", maxGraphemes: 5)
        XCTAssertEqual(r, "abcde")
    }

    // MARK: - 엣지 케이스

    func test_truncate_empty_returnsEmpty() {
        XCTAssertEqual(Utf8BoundaryTruncator.truncate("", maxGraphemes: 5), "")
    }

    func test_truncate_zeroMax_returnsEmpty() {
        XCTAssertEqual(Utf8BoundaryTruncator.truncate("abc", maxGraphemes: 0), "")
    }

    func test_truncate_mixedKoreanEmojiAscii_5() {
        let s = "안녕😀하세요world"
        let r = Utf8BoundaryTruncator.truncate(s, maxGraphemes: 5)
        XCTAssertEqual(r.count, 5)
        XCTAssertEqual(r, "안녕😀하세")
    }

    // MARK: - count 단위가 grapheme 임을 명시적으로 검증

    func test_truncate_zwjMan_count1() {
        let s = "👨🏽‍💻이후"
        let r = Utf8BoundaryTruncator.truncate(s, maxGraphemes: 1)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r, "👨🏽‍💻")
    }
}
