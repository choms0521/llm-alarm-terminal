import Foundation

/// Watches a stream of PTY bytes for the first occurrence of the regex
/// `Session ID: ([0-9a-f-]{36})`, invokes a callback exactly once with the
/// captured UUID, then refuses further work.
///
/// Internal buffering: we accumulate UTF-8 bytes into a `String` and scan the
/// running buffer on every `feed`. Once a match fires we drop the buffer so
/// memory does not grow unbounded.
public final class ClaudeSessionIDExtractor {
    private static let pattern: NSRegularExpression = {
        // Force-try because the regex is a compile-time constant.
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(
            pattern: #"Session ID: ([0-9a-f-]{36})"#,
            options: []
        )
    }()

    /// Hard cap on the rolling buffer so a long stream without a match cannot
    /// retain unbounded memory. 64 KiB is well above any banner length we
    /// expect from `claude` while staying tiny relative to PTY throughput.
    private static let maxBufferBytes = 64 * 1024

    private var buffer = ""
    private var didMatch = false
    private let onMatch: (String) -> Void

    public init(onMatch: @escaping (String) -> Void) {
        self.onMatch = onMatch
    }

    /// Feed a chunk of PTY output. Non-UTF-8 chunks are decoded with a
    /// permissive replacement strategy so partial multi-byte boundaries do not
    /// drop a match.
    public func feed(_ data: Data) {
        guard !didMatch else { return }
        if data.isEmpty { return }

        let chunk = String(decoding: data, as: UTF8.self)
        buffer.append(chunk)

        // Search the new buffer for the regex.
        let nsBuffer = buffer as NSString
        let range = NSRange(location: 0, length: nsBuffer.length)
        if let match = Self.pattern.firstMatch(in: buffer, options: [], range: range),
           match.numberOfRanges >= 2 {
            let captureRange = match.range(at: 1)
            if captureRange.location != NSNotFound {
                let captured = nsBuffer.substring(with: captureRange)
                didMatch = true
                buffer.removeAll(keepingCapacity: false)
                onMatch(captured)
                return
            }
        }

        // No match yet — keep only the trailing window so we do not bloat
        // memory while we wait for the banner line.
        if buffer.utf8.count > Self.maxBufferBytes {
            // Keep the trailing portion that could still contain a partial
            // match (the regex is short, so 1 KiB is plenty).
            let keep = 1024
            if buffer.count > keep {
                let start = buffer.index(buffer.endIndex, offsetBy: -keep)
                buffer = String(buffer[start...])
            }
        }
    }

    /// True once a match has been observed. Useful for tests.
    public var hasMatched: Bool { didMatch }
}
