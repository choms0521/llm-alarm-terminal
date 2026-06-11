import Foundation
import GhosttyKit

/// Real `PrintableTextInjecting` backed by a libghostty surface.
///
/// Injects printable UTF-8 through `ghostty_surface_text` — the same C ABI call
/// the IME commit path uses (see `GhosttyTerminalView.insertText`). It lives in
/// the app layer so `Sources/Daemon` and the daemon test target stay free of the
/// GhosttyKit dependency; the daemon reaches it only through the
/// `PrintableTextInjecting` protocol, and `InternalSink` filters out control
/// bytes (C1) before it is ever called.
@MainActor
public final class GhosttySurfaceInjector: PrintableTextInjecting {
    private let surface: ghostty_surface_t

    public init(surface: ghostty_surface_t) {
        self.surface = surface
    }

    public func injectPrintable(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            ghostty_surface_text(
                surface,
                base.assumingMemoryBound(to: CChar.self),
                UInt(bytes.count)
            )
        }
    }
}
