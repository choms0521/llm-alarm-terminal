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
}
