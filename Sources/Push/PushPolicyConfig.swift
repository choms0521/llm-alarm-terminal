import Foundation

/// Push delivery policy, shared between the app-target settings toggle and the
/// Daemon-target `PushSender`. Lives in `Sources/Push` so both targets reference
/// the same type — the seam that keeps the UI toggle and the sender in sync.
public struct PushPolicyConfig: Equatable, Sendable {
    /// When true, push is skipped while a WS client is attached to the session
    /// (the foreground user already reads the live stream); when not attached,
    /// push is sent.
    public var skipWhenAttached: Bool

    public init(skipWhenAttached: Bool = true) {
        self.skipWhenAttached = skipWhenAttached
    }
}
