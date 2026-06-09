import Foundation

/// Serializes all PTY writes for a session so they reach the sink in strict FIFO
/// order, with at most one writer per session (R8, Option A).
///
/// Each session has a single `AsyncStream` drained by a single consumer task.
/// The consumer awaits each `sink.write` to completion before pulling the next
/// item, so origin hops (actor / MainActor) never reorder. Spawning a fresh
/// `Task` per item would break FIFO, so it is deliberately avoided.
public actor SerialInputQueue {
    private var continuations: [UUID: AsyncStream<InputItem>.Continuation] = [:]
    private var consumers: [UUID: Task<Void, Never>] = [:]
    private var pending: [UUID: Int] = [:]

    public init() {}

    /// Attaches a single-consumer drain for a session. A second attach for the
    /// same session is a no-op, guaranteeing exactly one consumer.
    public func attach(sessionId: UUID, sink: InputSink) {
        guard consumers[sessionId] == nil else { return }
        let stream = AsyncStream<InputItem> { continuation in
            continuations[sessionId] = continuation
        }
        consumers[sessionId] = Task { [weak self] in
            for await item in stream {
                await sink.write(item)
                await self?.itemDrained(sessionId)
            }
        }
    }

    /// Enqueues one item for a session. No-op if the session is not attached.
    public func enqueue(_ item: InputItem, for sessionId: UUID) {
        guard let continuation = continuations[sessionId] else { return }
        pending[sessionId, default: 0] += 1
        continuation.yield(item)
    }

    /// Detaches a session: finishes the stream, cancels the consumer, drops state.
    public func detach(sessionId: UUID) {
        continuations[sessionId]?.finish()
        continuations[sessionId] = nil
        consumers[sessionId]?.cancel()
        consumers[sessionId] = nil
        pending[sessionId] = nil
    }

    /// 1 if a session has an active consumer, else 0 (single-consumer invariant).
    public func consumerCount(for sessionId: UUID) -> Int {
        consumers[sessionId] == nil ? 0 : 1
    }

    /// Items enqueued but not yet written.
    public func pendingCount(for sessionId: UUID) -> Int {
        pending[sessionId] ?? 0
    }

    private func itemDrained(_ sessionId: UUID) {
        if let count = pending[sessionId], count > 0 {
            pending[sessionId] = count - 1
        }
    }
}
