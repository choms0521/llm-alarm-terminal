import Foundation

/// (h) internal input wiring — daemon seam (layer a).
///
/// Lives in the Daemon target with no GhosttyKit dependency, so `DaemonTests` can
/// gate it with a mock provider + spy injector. The app-target adapter
/// (`RegistrySurfaceProvider`) and the real surface hook are layer (b), verified
/// by manual C2 sign-off.
extension SessionDaemon {
    /// Attaches an internal (Claude) session's input sink. Input flows through the
    /// same `SerialInputQueue` the external path uses (R8 serialization), so a
    /// sink never sees concurrent writes for one session.
    public func attachInternalSession(sessionId: UUID, sink: any InputSink) async {
        await attachInput(sessionId: sessionId, sink: sink)
    }
}

/// Surface-handle lookup seam.
///
/// Returns an `UnsafeMutableRawPointer?` rather than `ghostty_surface_t?` so the
/// Daemon target stays GhosttyKit-free: `ghostty_surface_t` is `typedef void*`,
/// which Clang imports as the stdlib type `UnsafeMutableRawPointer` — naming it
/// here needs no GhosttyKit import. The app-target conformer returning
/// `ghostty_surface_t?` therefore satisfies this requirement (identical type),
/// and `DaemonTests` can gate the seam with a mock provider.
public protocol SurfaceHandleProviding: Sendable {
    @MainActor func surface(forTab tabId: UUID) -> UnsafeMutableRawPointer?
}
