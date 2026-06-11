import Foundation

/// Encodes a `PushEnvelope` to the shared wire JSON and enforces the 4KB push
/// limit inside the codec (right after encoding). Every field except `fetchHint`
/// is bounded (UUIDs, an epoch-millis timestamp, `chatRoomId == sessionId`, a
/// ≤200-character preview), so an unbounded `fetchHint` is the only field that
/// can push the payload over the ceiling — and the validator rejects it
/// explicitly rather than dropping it silently.
public enum PushEnvelopeCodec {
    /// 4KB push payload ceiling (FCM/APNs hard limit).
    public static let maxPayloadBytes = 4096

    /// v0.9 shape stabilized at P5 so the P6 mobile parser reads the same shape
    /// without a swap-in (the formal v1.0 freeze is the P7 gate): epoch-millis
    /// timestamps and a stable key order. Fresh instances
    /// per call (matching `EnvelopeCodec`) because `JSONEncoder`/`JSONDecoder`
    /// are not documented as thread-safe and this codec is called from
    /// multiple actors.
    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }

    /// Encodes and validates the 4KB ceiling on the final byte length. Throws
    /// `PushError.payloadTooLarge` (explicit reject) when over the limit.
    public static func encode(_ env: PushEnvelope) throws -> Data {
        let data = try makeEncoder().encode(env)
        guard data.count <= maxPayloadBytes else {
            throw PushError.payloadTooLarge
        }
        return data
    }

    public static func decode(_ data: Data) throws -> PushEnvelope {
        try makeDecoder().decode(PushEnvelope.self, from: data)
    }
}
