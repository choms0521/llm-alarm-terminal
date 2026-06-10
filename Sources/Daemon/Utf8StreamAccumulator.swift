import Foundation

/// Reassembles a byte stream into complete UTF-8 strings across chunk
/// boundaries. `PTYReader` delivers chunks with lowWater 1, so a multi-byte
/// character can be split mid-sequence; this accumulator emits only complete
/// UTF-8 and carries a trailing incomplete sequence to the next chunk.
///
/// `Utf8BoundaryTruncator` is a grapheme-truncate utility and cannot be reused
/// here (it has no streaming byte-level carry).
///
/// Distinctions (the load-bearing logic):
/// - A valid lead byte at the end whose full sequence has not arrived yet is
///   *incomplete* -> carried.
/// - A lone continuation, an invalid lead, or a lead followed by a
///   non-continuation is *malformed now* -> emit U+FFFD and consume, never carry
///   (otherwise the stream would wedge forever).
/// - A carry that somehow exceeds the 4-byte max UTF-8 length is malformed ->
///   U+FFFD and clear.
public struct Utf8StreamAccumulator {
    private var carry: [UInt8] = []

    /// Every non-empty string emitted so far (tests assert against this).
    public private(set) var emitted: [String] = []

    public init() {}

    /// Feeds one chunk and returns the string emitted for it (nil if the chunk
    /// only extended an incomplete carry). Also appended to `emitted`.
    @discardableResult
    public mutating func push(_ chunk: Data) -> String? {
        var buf = carry
        buf.append(contentsOf: chunk)
        carry = []

        var output = ""
        var i = 0
        let n = buf.count

        while i < n {
            let lead = buf[i]
            let length = Self.sequenceLength(lead)

            if length == 0 {
                // Invalid lead or lone continuation: malformed now.
                output.unicodeScalars.append("\u{FFFD}")
                i += 1
                continue
            }

            if i + length > n {
                // Not all bytes arrived. Carry only if the bytes present so far
                // are valid continuations; a non-continuation means malformed.
                if Self.continuationsValid(buf, from: i + 1, to: n) {
                    carry = Array(buf[i..<n])
                    break
                }
                output.unicodeScalars.append("\u{FFFD}")
                i += 1
                continue
            }

            if Self.continuationsValid(buf, from: i + 1, to: i + length),
               let scalar = String(bytes: buf[i..<(i + length)], encoding: .utf8) {
                output += scalar
                i += length
            } else {
                // Bad continuation / overlong / surrogate / out-of-range.
                output.unicodeScalars.append("\u{FFFD}")
                i += 1
            }
        }

        // Defensive cap: a carry longer than the max UTF-8 sequence is malformed.
        if carry.count > 4 {
            output.unicodeScalars.append("\u{FFFD}")
            carry = []
        }

        guard !output.isEmpty else { return nil }
        emitted.append(output)
        return output
    }

    /// Flushes any unresolved carry at end-of-stream as a single U+FFFD.
    @discardableResult
    public mutating func flush() -> String? {
        guard !carry.isEmpty else { return nil }
        carry = []
        let replacement = "\u{FFFD}"
        emitted.append(replacement)
        return replacement
    }

    private static func sequenceLength(_ b: UInt8) -> Int {
        switch b {
        case 0x00...0x7F: return 1
        case 0xC2...0xDF: return 2
        case 0xE0...0xEF: return 3
        case 0xF0...0xF4: return 4
        default: return 0 // continuation byte, 0xC0/0xC1, or 0xF5...0xFF
        }
    }

    private static func isContinuation(_ b: UInt8) -> Bool {
        (0x80...0xBF).contains(b)
    }

    private static func continuationsValid(_ buf: [UInt8], from start: Int, to end: Int) -> Bool {
        var j = start
        while j < end {
            if !isContinuation(buf[j]) { return false }
            j += 1
        }
        return true
    }
}
