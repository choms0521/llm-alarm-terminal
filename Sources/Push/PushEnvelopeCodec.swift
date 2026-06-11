import Foundation

/// Encodes a `PushEnvelope` to the shared wire JSON and enforces the 4KB push
/// limit inside the codec (right after encoding). The enforced guarantee is the
/// byte-length check itself: whichever field grows past the ceiling, encode
/// rejects explicitly rather than dropping silently. In the expected
/// construction path the other fields stay small (UUIDs, an epoch-millis
/// timestamp, a preview built ≤200 characters by `PreviewBuilder`, and a
/// `chatRoomId` that P5 fills with the sessionId placeholder), which leaves an
/// unbounded `fetchHint` as the likeliest trigger — but the codec validates
/// the final byte length, not per-field invariants.
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
