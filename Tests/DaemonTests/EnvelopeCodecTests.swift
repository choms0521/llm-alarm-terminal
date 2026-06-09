import XCTest
import Foundation

/// Day 1 acceptance: envelope codec v0.9.
/// Covers A3 (2^53+1 seq string round-trip), A5 (Korean/emoji + partial UTF-8
/// rejection), A6 (all 9 kinds round-trip), and monotonic seq validation.
final class EnvelopeCodecTests: XCTestCase {
    private let deviceActor = EnvelopeActor(deviceId: "daemon-local")

    private func makeEnvelope(
        seq: UInt64,
        kind: EnvelopeKind = .input,
        text: String = "hello"
    ) -> WSEnvelope {
        WSEnvelope(seq: seq, actor: deviceActor, kind: kind, text: text)
    }

    // A3: seq above 2^53 survives a string round-trip without precision loss.
    func testSeqU64StringRoundTrip() throws {
        let big: UInt64 = 9007199254740993 // 2^53 + 1
        let env = makeEnvelope(seq: big)
        let decoded = try EnvelopeCodec.decode(EnvelopeCodec.encode(env))
        XCTAssertEqual(decoded.seq, 9007199254740993)
    }

    // seq is serialized as a JSON string, not a number.
    func testSeqIsStringInJson() throws {
        let env = makeEnvelope(seq: 42, kind: .ack)
        let json = try XCTUnwrap(String(data: EnvelopeCodec.encode(env), encoding: .utf8))
        XCTAssertTrue(json.contains("\"seq\":\""))
    }

    // ackSeq is also serialized as a string when present.
    func testAckSeqIsStringInJson() throws {
        let env = WSEnvelope(seq: 5, ackSeq: 4, actor: deviceActor, kind: .ack, text: "{}")
        let json = try XCTUnwrap(String(data: EnvelopeCodec.encode(env), encoding: .utf8))
        XCTAssertTrue(json.contains("\"ackSeq\":\"4\""))
    }

    // A non-numeric wire seq throws malformedSeq on decode.
    func testMalformedSeqThrows() {
        let badJson = Data(#"{"seq":"not-a-number","actor":{"deviceId":"d"},"kind":"input","payload":"x"}"#.utf8)
        XCTAssertThrowsError(try EnvelopeCodec.decode(badJson)) { error in
            XCTAssertEqual(error as? EnvelopeCodecError, .malformedSeq("not-a-number"))
        }
    }

    // A monotonic violation (non-increasing seq) throws nonMonotonicSeq.
    func testNonMonotonicSeqThrows() {
        var lastSeq: UInt64 = 10
        let env = makeEnvelope(seq: 10) // equal => not strictly greater
        XCTAssertThrowsError(try validateMonotonic(env, lastSeq: &lastSeq)) { error in
            XCTAssertEqual(error as? EnvelopeCodecError, .nonMonotonicSeq(prev: 10, got: 10))
        }
        // lastSeq unchanged on rejection
        XCTAssertEqual(lastSeq, 10)
    }

    func testMonotonicSeqAdvancesOnAccept() throws {
        var lastSeq: UInt64 = 10
        try validateMonotonic(makeEnvelope(seq: 11), lastSeq: &lastSeq)
        XCTAssertEqual(lastSeq, 11)
    }

    // A5: partial/invalid UTF-8 payload is refused at encode time.
    func testNonUtf8PayloadEncodeThrows() {
        let loneContinuation = Data([0xED, 0xA0, 0x80]) // surrogate range, invalid UTF-8
        let env = WSEnvelope(seq: 1, actor: deviceActor, kind: .output, payload: loneContinuation)
        XCTAssertThrowsError(try EnvelopeCodec.encode(env)) { error in
            XCTAssertEqual(error as? EnvelopeCodecError, .nonUtf8Payload)
        }
    }

    // A5: Korean and emoji payloads survive the round-trip intact.
    func testKoreanAndEmojiPayloadRoundTrip() throws {
        for text in ["가나다", "👍🇰🇷", "mixed 한글 and emoji 😀"] {
            let env = makeEnvelope(seq: 7, kind: .output, text: text)
            let decoded = try EnvelopeCodec.decode(EnvelopeCodec.encode(env))
            XCTAssertEqual(decoded.payloadText, text)
        }
    }

    // A6: all 9 kinds (including reserved pause/resume) round-trip equal.
    func testAllKinds() throws {
        XCTAssertEqual(EnvelopeKind.allCases.count, 9)
        for kind in EnvelopeKind.allCases {
            let env = WSEnvelope(
                seq: 100,
                ackSeq: 99,
                actor: EnvelopeActor(deviceId: "d", userId: "u"),
                kind: kind,
                code: kind == .error ? "BUFFER_OVERFLOW_DROPPED" : nil,
                text: "payload-\(kind.rawValue)"
            )
            let decoded = try EnvelopeCodec.decode(EnvelopeCodec.encode(env))
            XCTAssertEqual(decoded, env, "round-trip mismatch for kind \(kind.rawValue)")
        }
    }
}
