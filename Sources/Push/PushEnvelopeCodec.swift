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

    /// Frozen at P5 so the P6 mobile parser reads the same shape without a
    /// swap-in: epoch-millis timestamps and a stable key order.
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }()

    /// Encodes and validates the 4KB ceiling on the final byte length. Throws
    /// `PushError.payloadTooLarge` (explicit reject) when over the limit.
    public static func encode(_ env: PushEnvelope) throws -> Data {
        let data = try encoder.encode(env)
        guard data.count <= maxPayloadBytes else {
            throw PushError.payloadTooLarge
        }
        return data
    }

    public static func decode(_ data: Data) throws -> PushEnvelope {
        try decoder.decode(PushEnvelope.self, from: data)
    }
}
