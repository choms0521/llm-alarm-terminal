import Foundation

/// In-process daemon module marker.
///
/// P4: WebSocket server + SessionManager wiring runs in-process (foreground only).
/// This namespace holds module-wide constants shared by the envelope codec,
/// ring buffer, WS server, and input queue introduced across P4 Day 1~6.
public enum DaemonModule {
    /// WS envelope schema version. v0.9 is a preview; freeze lands in P7.
    public static let envelopeSchemaVersion = "0.9"
}
