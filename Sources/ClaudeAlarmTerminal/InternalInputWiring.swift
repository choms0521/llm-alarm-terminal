import Foundation
import GhosttyKit

/// (h) internal input wiring — app glue (layer b).
///
/// App-target-only: it casts to `GhosttyTerminalView` (internal) and constructs
/// `GhosttySurfaceInjector` (GhosttyKit), neither of which `DaemonTests` can
/// compile. The daemon seam (`attachInternalSession` / `SurfaceHandleProviding`)
/// is gated separately with a mock provider; this layer's live firing is verified
/// by manual C2 sign-off, not an automated test.
@MainActor
struct RegistrySurfaceProvider: SurfaceHandleProviding {
    let registry: SurfaceRegistry

    func surface(forTab tabId: UUID) -> UnsafeMutableRawPointer? {
        // `ghostty_surface_t` is `UnsafeMutableRawPointer` (imported from
        // `typedef void*`), matching the seam's requirement exactly.
        (registry.acquireExisting(id: tabId) as? GhosttyTerminalView)?.surfaceHandle
    }
}

/// Attaches an internal session's printable-input sink once its surface exists.
///
/// The surface is created lazily at draw time, so `surface(forTab:)` is nil right
/// after `acquire`. Instead of silently returning, the caller logs and is told
/// (via the `false` return) to retry on the next poll; it returns true once the
/// attach has fired so the caller can stop retrying (idempotency).
@MainActor
@discardableResult
func wireInternalInput(
    tabId: UUID,
    sessionId: UUID,
    provider: any SurfaceHandleProviding,
    daemon: SessionDaemon
) async -> Bool {
    guard let surface = provider.surface(forTab: tabId) else {
        PushLog.debug("wireInternalInput: surface not ready tab=\(tabId) — retry next poll")
        return false
    }
    let injector = GhosttySurfaceInjector(surface: surface)
    let sink = InternalSink(injector: injector)   // C1: control byte rejection kept
    await daemon.attachInternalSession(sessionId: sessionId, sink: sink)
    return true
}

/// Drives `wireInternalInput` for live Claude (internal) sessions until each is
/// attached, on its own light poll — deliberately separate from
/// `ViewportPollingTimer` so that critical read_text/free_text loop stays
/// untouched. Idempotent: each tab is attached at most once.
@MainActor
final class InternalInputCoordinator {
    private let provider: any SurfaceHandleProviding
    private let daemon: SessionDaemon
    private let internalSessions: @MainActor () -> [(tabId: UUID, sessionId: UUID)]
    private var attached: Set<UUID> = []
    private var timer: Timer?

    init(
        provider: any SurfaceHandleProviding,
        daemon: SessionDaemon,
        internalSessions: @escaping @MainActor () -> [(tabId: UUID, sessionId: UUID)]
    ) {
        self.provider = provider
        self.daemon = daemon
        self.internalSessions = internalSessions
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() async {
        for session in internalSessions() where !attached.contains(session.tabId) {
            let fired = await wireInternalInput(
                tabId: session.tabId,
                sessionId: session.sessionId,
                provider: provider,
                daemon: daemon
            )
            if fired { attached.insert(session.tabId) }
        }
    }
}
