import XCTest
import Foundation

/// Day 1 acceptance: ≤200-char message-boundary preview (Korean-safe).
final class PreviewBuilderTests: XCTestCase {

    /// Invariant: preview never exceeds 200 characters for arbitrary input length.
    func testPreviewNeverExceeds200() {
        for n in [0, 1, 199, 200, 201, 500, 1000] {
            let input = String(repeating: "가", count: n)
            XCTAssertLessThanOrEqual(PreviewBuilder.build(from: input).count, 200)
        }
    }

    /// Korean 250-char input cuts to exactly 200 characters on a grapheme
    /// boundary; the last Character stays intact.
    func testKorean250CutsToExactly200() {
        let input = String(repeating: "가", count: 250)
        let preview = PreviewBuilder.build(from: input)
        XCTAssertEqual(preview.count, 200)
        XCTAssertEqual(preview.last, "가")   // last grapheme intact
    }

    /// A multi-scalar grapheme cluster (family emoji) is not split at the
    /// boundary — it is kept whole as the 200th Character.
    func testEmojiGraphemeBoundaryPreserved() {
        let input = String(repeating: "a", count: 199) + "👨‍👩‍👧‍👦" + "tail"
        let preview = PreviewBuilder.build(from: input)
        XCTAssertEqual(preview.count, 200)
        XCTAssertEqual(preview.last, "👨‍👩‍👧‍👦")   // family emoji kept whole
    }

    /// Short input passes through unchanged.
    func testShortInputUnchanged() {
        let input = "가나다 short"
        XCTAssertEqual(PreviewBuilder.build(from: input), input)
    }
}
