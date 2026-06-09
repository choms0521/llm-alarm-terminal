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
    case nonMonotonicSeq = "NON_MONOTONIC_SEQ"
}
