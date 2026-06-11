import Foundation

/// Errors raised while encoding/decoding or validating an envelope.
public enum EnvelopeCodecError: Error, Equatable {
    /// A wire `seq`/`ackSeq` string did not parse as a UInt64.
    case malformedSeq(String)
    /// An inbound `seq` was not strictly greater than the previous one.
    case nonMonotonicSeq(prev: UInt64, got: UInt64)
    /// A payload held bytes that are not valid UTF-8 (encode refuses to split it).
    case nonUtf8Payload
}

extension WSEnvelope: Codable {
    enum CodingKeys: String, CodingKey {
        case seq, ackSeq, actor, kind, code, payload
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        let seqStr = try c.decode(String.self, forKey: .seq)
        guard let seqValue = UInt64(seqStr) else {
            throw EnvelopeCodecError.malformedSeq(seqStr)
        }
        self.seq = seqValue

        if let ackStr = try c.decodeIfPresent(String.self, forKey: .ackSeq) {
            guard let ackValue = UInt64(ackStr) else {
                throw EnvelopeCodecError.malformedSeq(ackStr)
            }
            self.ackSeq = ackValue
        } else {
            self.ackSeq = nil
        }

        self.actor = try c.decode(EnvelopeActor.self, forKey: .actor)
        self.kind = try c.decode(EnvelopeKind.self, forKey: .kind)
        self.code = try c.decodeIfPresent(String.self, forKey: .code)

        let payloadStr = try c.decode(String.self, forKey: .payload)
        self.payload = Data(payloadStr.utf8)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(String(seq), forKey: .seq)
        try c.encodeIfPresent(ackSeq.map(String.init), forKey: .ackSeq)
        try c.encode(actor, forKey: .actor)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(code, forKey: .code)

        guard let payloadStr = String(data: payload, encoding: .utf8) else {
            throw EnvelopeCodecError.nonUtf8Payload
        }
        try c.encode(payloadStr, forKey: .payload)
    }
}

/// JSON codec for WS envelopes. Thin wrapper that keeps the encoder/decoder
/// configuration in one place so wire behavior is identical everywhere.
public enum EnvelopeCodec {
    public static func encode(_ envelope: WSEnvelope) throws -> Data {
        try JSONEncoder().encode(envelope)
    }

    public static func decode(_ data: Data) throws -> WSEnvelope {
        try JSONDecoder().decode(WSEnvelope.self, from: data)
    }
}

/// Per-client monotonic `seq` validation (wire level).
///
/// Called by `SessionBindRegistry` (Day 3) which owns each client's `lastSeq`.
/// Throws `nonMonotonicSeq` on an out-of-order or duplicate `seq`; on success
/// advances `lastSeq` to the accepted value.
public func validateMonotonic(_ envelope: WSEnvelope, lastSeq: inout UInt64) throws {
    guard envelope.seq > lastSeq else {
        throw EnvelopeCodecError.nonMonotonicSeq(prev: lastSeq, got: envelope.seq)
    }
    lastSeq = envelope.seq
}
