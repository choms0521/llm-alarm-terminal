import Foundation

/// Per-session in-memory ring buffer of outbound envelopes (~500).
///
/// Elements are whole envelopes, never byte chunks, so an overflow drop always
/// lands on a message boundary and can never split a multi-byte UTF-8 character
/// (§5.2 of the P4 plan). On the first drop of an overflow episode a single
/// `BUFFER_OVERFLOW_DROPPED` mark is produced (latched). The latch resets once
/// the consumer drains the buffer back below capacity, so a later overflow
/// emits a fresh mark.
public final class SessionRingBuffer {
    private let sessionId: UUID
    private let capacity: Int
    private var items: [WSEnvelope] = []
    private var dropEventEmitted = false
    private var droppedSinceReset = 0

    /// Number of `BUFFER_OVERFLOW_DROPPED` marks emitted so far (one per episode).
    public private(set) var dropEventCount = 0

    public init(sessionId: UUID, capacity: Int = 500) {
        self.sessionId = sessionId
        self.capacity = capacity
    }

    /// Current number of buffered envelopes.
    public var count: Int { items.count }

    /// Appends one envelope. On overflow the oldest envelope is dropped whole
    /// (message-boundary drop). Returns a drop mark to emit on the first drop of
    /// an episode, otherwise nil.
    @discardableResult
    public func enqueue(_ envelope: WSEnvelope) -> WSEnvelope? {
        items.append(envelope)
        guard items.count > capacity else { return nil }

        items.removeFirst()
        droppedSinceReset += 1
        guard !dropEventEmitted else { return nil }

        dropEventEmitted = true
        dropEventCount += 1
        return makeDropMark()
    }

    /// Removes and returns up to `n` envelopes from the front (oldest first).
    /// If this brings the buffer below capacity, the drop latch resets.
    public func drain(upTo n: Int) -> [WSEnvelope] {
        let taken = Array(items.prefix(n))
        items.removeFirst(min(n, items.count))
        if items.count < capacity {
            dropEventEmitted = false
            droppedSinceReset = 0
        }
        return taken
    }

    /// Builds the BUFFER_OVERFLOW_DROPPED mark (§7 schema). `seq` is a placeholder;
    /// the sender stamps the real outbound seq when it writes to the wire.
    private func makeDropMark() -> WSEnvelope {
        let payload = #"{"sessionId":"\#(sessionId.uuidString)","droppedCount":\#(droppedSinceReset)}"#
        return WSEnvelope(
            seq: 0,
            actor: EnvelopeActor(deviceId: "daemon-local"),
            kind: .error,
            code: "BUFFER_OVERFLOW_DROPPED",
            text: payload
        )
    }
}
