import Foundation

/// Tracks which WS client is attached to which session, plus each client's last
/// inbound `seq` for monotonic validation (§5.4 of the P4 plan).
///
/// Lifecycle: a client is `register`ed at connection time (its `lastSeq` starts
/// at 0 so the very first inbound envelope is validated against 0), `bind`s to a
/// session on `session.start`, and is `cleanup`ed on disconnect. Cleanup removes
/// only the binding and seq state — it never terminates the session, so the PTY
/// survives a client disconnect (A4).
public actor SessionBindRegistry {
    private var bindings: [UUID: UUID] = [:]   // clientId -> sessionId
    private var lastSeq: [UUID: UInt64] = [:]  // clientId -> last accepted inbound seq

    public init() {}

    /// Called when a connection is accepted. Seeds `lastSeq` at 0 so the first
    /// real message (e.g. session.start) is monotonic-checked against 0.
    /// Non-destructive: never resets an already-tracked client's `lastSeq`.
    public func register(clientId: UUID) {
        if lastSeq[clientId] == nil { lastSeq[clientId] = 0 }
    }

    public func isRegistered(clientId: UUID) -> Bool {
        lastSeq[clientId] != nil
    }

    /// Binds a client to a session (handled on session.start, after the inbound
    /// envelope's seq has already passed `ingestInbound`).
    public func bind(clientId: UUID, sessionId: UUID) {
        bindings[clientId] = sessionId
        if lastSeq[clientId] == nil { lastSeq[clientId] = 0 }
    }

    public func boundSession(clientId: UUID) -> UUID? {
        bindings[clientId]
    }

    /// The client currently bound to a session, if any (test/introspection helper).
    public func boundClient(forSession sessionId: UUID) -> UUID? {
        bindings.first(where: { $0.value == sessionId })?.key
    }

    public var clientCount: Int { lastSeq.count }

    /// Validates an inbound envelope's `seq` monotonicity for this client and,
    /// on success, advances the stored `lastSeq`. Throws `nonMonotonicSeq` on an
    /// out-of-order or duplicate seq so the caller can emit NON_MONOTONIC_SEQ.
    public func ingestInbound(clientId: UUID, env: WSEnvelope) throws {
        var seq = lastSeq[clientId] ?? 0
        try validateMonotonic(env, lastSeq: &seq)
        lastSeq[clientId] = seq
    }

    /// Client disconnect cleanup. Removes binding + seq state only — the session
    /// (and its PTY) is intentionally left alive.
    public func cleanup(clientId: UUID) {
        bindings[clientId] = nil
        lastSeq[clientId] = nil
    }

    /// Sleep / lid-close invalidation: drops every client→session binding so
    /// `boundClient(forSession:)` returns nil and the push fallback path fires.
    /// `lastSeq` (seq tracking) is intentionally preserved — a client that
    /// reconnects after wake must keep monotonic-seq continuity (P6), so
    /// `clientCount` stays unchanged. Distinct from `cleanup`, which drops both.
    public func invalidateAllBindings() {
        bindings.removeAll(keepingCapacity: true)   // lastSeq preserved
    }
}
