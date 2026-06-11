import Foundation

/// WS envelope kind set (v0.9 preview; freeze in P7, see §7 of the P4 plan).
///
/// `pause`/`resume` are reserved: P4 guarantees only their encode/decode
/// round-trip, not their runtime behavior (deferred to a later phase).
public enum EnvelopeKind: String, Codable, Sendable, CaseIterable {
    case input
    case output
    case sessionStart = "session.start"
    case sessionExit = "session.exit"
    case sessionTerminated = "session.terminated"
    case ack
    case error
    case pause
    case resume
    /// 6자리 코드 제출(pre-auth). 토큰 없는 디바이스가 secret 교환을 위해 보낸다.
    /// 인증 게이트 ② 이전에 분기 처리되며 연결을 승격하지 않는다(§5.5).
    case pairingClaim = "pairing.claim"
    /// claim 응답(PairingPayload, secret 포함). loopback 한정·일회성 예외(Principle 3).
    case pairingResponse = "pairing.response"
}

/// Sender identity carried on every envelope.
public struct EnvelopeActor: Codable, Sendable, Equatable {
    public let deviceId: String
    public let userId: String?

    public init(deviceId: String, userId: String? = nil) {
        self.deviceId = deviceId
        self.userId = userId
    }
}

/// WS envelope v0.9.
///
/// `seq`/`ackSeq` are held as `UInt64` in memory but serialized as strings on
/// the wire (ADR-P4-2) so values above 2^53 survive a JSON round-trip through
/// a JS runtime. `payload` is always complete UTF-8 — encoding rejects any
/// partial/invalid byte sequence so a multi-byte character is never split at
/// the envelope boundary (the `Codable` conformance lives in EnvelopeCodec.swift).
public struct WSEnvelope: Sendable, Equatable {
    public let seq: UInt64
    public let ackSeq: UInt64?
    public let actor: EnvelopeActor
    public let kind: EnvelopeKind
    public let code: String?
    public let payload: Data

    public init(
        seq: UInt64,
        ackSeq: UInt64? = nil,
        actor: EnvelopeActor,
        kind: EnvelopeKind,
        code: String? = nil,
        payload: Data
    ) {
        self.seq = seq
        self.ackSeq = ackSeq
        self.actor = actor
        self.kind = kind
        self.code = code
        self.payload = payload
    }

    /// Convenience initializer for a UTF-8 text payload.
    public init(
        seq: UInt64,
        ackSeq: UInt64? = nil,
        actor: EnvelopeActor,
        kind: EnvelopeKind,
        code: String? = nil,
        text: String
    ) {
        self.init(
            seq: seq,
            ackSeq: ackSeq,
            actor: actor,
            kind: kind,
            code: code,
            payload: Data(text.utf8)
        )
    }

    /// The payload decoded as a UTF-8 string, or nil if the bytes are not valid UTF-8.
    public var payloadText: String? {
        String(data: payload, encoding: .utf8)
    }
}
