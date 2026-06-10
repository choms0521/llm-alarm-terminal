import XCTest
import Foundation

/// Day 1 acceptance: push envelope v0.9 codec + 4KB validator.
/// Covers round-trip of all 6 fields, Korean/emoji preview, and explicit
/// PUSH_PAYLOAD_TOO_LARGE rejection (reject, not drop).
final class PushEnvelopeCodecTests: XCTestCase {

    private func makeEnvelope(
        preview: String = "테스트 메시지",
        timestamp: Date = Date(timeIntervalSince1970: 1_700_000_000),
        fetchHint: String? = nil
    ) -> PushEnvelope {
        let sid = UUID()
        return PushEnvelope(
            sessionId: sid,
            messageId: UUID(),
            preview: preview,
            chatRoomId: sid.uuidString,   // reserved: sessionId placeholder
            timestamp: timestamp,
            fetchHint: fetchHint
        )
    }

    /// Round-trip preserves all 6 fields. The whole-second timestamp fixture
    /// survives epoch-millis encoding exactly, so full-struct == holds.
    func testRoundTripPreservesAllFields() throws {
        let env = makeEnvelope(fetchHint: "hint-123")
        let decoded = try PushEnvelopeCodec.decode(PushEnvelopeCodec.encode(env))
        XCTAssertEqual(decoded, env)
    }

    /// Korean + emoji preview survives round-trip byte-for-byte.
    func testRoundTripKoreanEmojiPreview() throws {
        let env = makeEnvelope(preview: "가나다라 작업 완료 ✅ 다음 단계로")
        let decoded = try PushEnvelopeCodec.decode(PushEnvelopeCodec.encode(env))
        XCTAssertEqual(decoded.preview, env.preview)
        XCTAssertEqual(decoded, env)
    }

    /// nil fetchHint round-trips as nil.
    func testRoundTripNilFetchHint() throws {
        let env = makeEnvelope(fetchHint: nil)
        let decoded = try PushEnvelopeCodec.decode(PushEnvelopeCodec.encode(env))
        XCTAssertNil(decoded.fetchHint)
        XCTAssertEqual(decoded, env)
    }

    /// epoch-millis encoding keeps millisecond precision (sub-ms is lost by
    /// design); compare the timestamp field within ms tolerance.
    func testTimestampMillisecondPrecision() throws {
        let env = makeEnvelope(timestamp: Date(timeIntervalSince1970: 1_700_000_000_123.0 / 1000.0))
        let decoded = try PushEnvelopeCodec.decode(PushEnvelopeCodec.encode(env))
        XCTAssertEqual(
            decoded.timestamp.timeIntervalSince1970,
            env.timestamp.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    /// An oversized payload (built from a large fetchHint that pushes the JSON
    /// past 4096 bytes) is rejected explicitly with PUSH_PAYLOAD_TOO_LARGE.
    func testOversizedPayloadRejected() {
        let env = makeEnvelope(fetchHint: String(repeating: "a", count: 4096))
        XCTAssertThrowsError(try PushEnvelopeCodec.encode(env)) { error in
            guard let pushError = error as? PushError else {
                return XCTFail("expected PushError, got \(error)")
            }
            XCTAssertEqual(pushError, .payloadTooLarge)
            XCTAssertEqual(pushError.code, "PUSH_PAYLOAD_TOO_LARGE")
        }
    }

    /// A payload under the ceiling encodes successfully and stays within 4KB.
    func testUnderLimitPayloadEncodes() throws {
        let env = makeEnvelope(fetchHint: String(repeating: "a", count: 100))
        let data = try PushEnvelopeCodec.encode(env)
        XCTAssertLessThanOrEqual(data.count, PushEnvelopeCodec.maxPayloadBytes)
    }
}
