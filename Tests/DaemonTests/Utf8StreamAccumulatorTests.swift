import XCTest
import Foundation

/// Day 5 acceptance (A9 + malformed handling): UTF-8 stream reassembly across
/// chunk boundaries.
final class Utf8StreamAccumulatorTests: XCTestCase {

    // A9 discriminating case: "가" (EA B0 80) split 1 byte then 2 bytes ->
    // reassembled as one "가", with no intermediate emission.
    func testSplitMultibyteReassembles() {
        var acc = Utf8StreamAccumulator()
        XCTAssertNil(acc.push(Data([0xEA])))         // incomplete -> carried, nothing emitted
        XCTAssertEqual(acc.emitted, [])
        let emitted = acc.push(Data([0xB0, 0x80]))   // completes "가"
        XCTAssertEqual(emitted, "가")
        XCTAssertEqual(acc.emitted, ["가"])
    }

    // 4-byte emoji split across three chunks reassembles intact.
    func testEmojiSplitReassembles() {
        var acc = Utf8StreamAccumulator()
        XCTAssertNil(acc.push(Data([0xF0])))         // 👍 = F0 9F 91 8D
        XCTAssertNil(acc.push(Data([0x9F, 0x91])))
        let emitted = acc.push(Data([0x8D]))
        XCTAssertEqual(emitted, "👍")
        XCTAssertEqual(acc.emitted, ["👍"])
    }

    // The malformed discriminating case: a single invalid sequence (a lone
    // continuation byte) emits exactly one U+FFFD and is consumed, never carried.
    func testInvalidSequenceEmitsReplacement() {
        var acc = Utf8StreamAccumulator()
        let emitted = acc.push(Data([0x80]))         // lone continuation
        XCTAssertEqual(emitted, "\u{FFFD}")
        XCTAssertEqual(acc.emitted, ["\u{FFFD}"])
    }

    // An invalid lead followed by ASCII: U+FFFD for the bad lead, ASCII preserved.
    func testInvalidLeadDoesNotSwallowFollowingAscii() {
        var acc = Utf8StreamAccumulator()
        let emitted = acc.push(Data([0xFF, 0x41]))   // 0xFF invalid, 'A'
        XCTAssertEqual(emitted, "\u{FFFD}A")
    }

    // A lead followed by a non-continuation is malformed now, not carried.
    func testLeadFollowedByNonContinuationIsMalformed() {
        var acc = Utf8StreamAccumulator()
        let emitted = acc.push(Data([0xE0, 0x41]))   // 3-byte lead then 'A'
        XCTAssertEqual(emitted, "\u{FFFD}A")
        XCTAssertEqual(acc.emitted, ["\u{FFFD}A"])
    }

    // ASCII passes through unchanged.
    func testAsciiPassthrough() {
        var acc = Utf8StreamAccumulator()
        let emitted = acc.push(Data("hello\n".utf8))
        XCTAssertEqual(emitted, "hello\n")
    }

    // Korean text delivered whole stays intact and continuous across chunks.
    func testKoreanContinuousAcrossChunks() {
        var acc = Utf8StreamAccumulator()
        let full = Array("가나다".utf8)               // 9 bytes
        var result = ""
        result += acc.push(Data(full[0..<4])) ?? ""   // 가 + partial 나
        result += acc.push(Data(full[4...])) ?? ""    // rest
        XCTAssertEqual(result, "가나다")
    }

    // flush() emits a single U+FFFD for an unresolved trailing carry.
    func testFlushEmitsReplacementForDanglingCarry() {
        var acc = Utf8StreamAccumulator()
        XCTAssertNil(acc.push(Data([0xEA])))          // dangling incomplete
        XCTAssertEqual(acc.flush(), "\u{FFFD}")
        XCTAssertEqual(acc.emitted, ["\u{FFFD}"])
    }
}
