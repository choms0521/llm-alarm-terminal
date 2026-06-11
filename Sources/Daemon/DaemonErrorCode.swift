import Foundation

/// Machine codes carried on `kind=error` envelopes (§7 schema). The raw value is
/// the on-the-wire `code` string, so a single enum keeps producers and the
/// test assertions in sync.
public enum DaemonErrorCode: String, Sendable, Equatable {
    case bufferOverflowDropped = "BUFFER_OVERFLOW_DROPPED"
    case internalOutputUnsupported = "INTERNAL_OUTPUT_UNSUPPORTED"
    case internalControlInputUnsupported = "INTERNAL_CONTROL_INPUT_UNSUPPORTED"
    case ptyWriteFailed = "PTY_WRITE_FAILED"
    case malformedSeq = "MALFORMED_SEQ"
    case malformedPayload = "MALFORMED_PAYLOAD"
    case nonMonotonicSeq = "NON_MONOTONIC_SEQ"
    /// 미인증 연결의 첫 envelope이 인증 게이트 ②를 통과하지 못했다(P6a). nonce 미echo/
    /// 미등록/만료, secret 불일치, revoked/expired 디바이스 모두 이 코드로 close된다.
    case unauthorized = "UNAUTHORIZED"
    /// pairing.claim 코드가 활성 코드와 불일치하거나(또는 활성 코드 부재), 1회 소비된 코드를
    /// 재claim(replay)했다(P6a §5.5). PairingSession.RejectCode.invalid와 정합.
    case pairingCodeInvalid = "PAIRING_CODE_INVALID"
    /// pairing.claim 코드가 만료됐다(기본 5분, §5.5). PairingSession.RejectCode.expired와 정합.
    case pairingCodeExpired = "PAIRING_CODE_EXPIRED"
    /// 동일 코드 오claim이 한도(기본 5회)에 도달해 코드가 폐기됐다(brute-force 방어, §5.5).
    /// PairingSession.RejectCode.rateLimited와 정합.
    case pairingRateLimited = "PAIRING_RATE_LIMITED"
}
