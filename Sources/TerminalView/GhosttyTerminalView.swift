import AppKit
import GhosttyKit
import QuartzCore
import os

/// AppKit view that hosts a single libghostty surface.
///
/// Day 5b scope (libghostty-internal PTY pivot):
/// - Backed by a CAMetalLayer so libghostty can render via Metal.
/// - Owns one `ghostty_surface_t` whose userdata points back to this view.
/// - When `command` is non-nil, libghostty spawns the process inside its own
///   PTY using `ghostty_surface_config_s.command` + `working_directory`. The
///   surface then receives PTY bytes natively (ANSI codes interpreted).
/// - When `command` is nil, the view starts in idle-passive mode — a surface
///   exists but no PTY is attached. `replaceCommand(...)` swaps the surface
///   for a new one with a command attached.
/// - Forwards keystrokes via `ghostty_surface_text` (the "typed text" path).
/// - Resizes the surface in pixels on layout.
final class GhosttyTerminalView: NSView {
    private static let logger = Logger(subsystem: "com.choms0521.ClaudeAlarmTerminal", category: "GhosttyTerminalView")

    private let ghosttyApp: GhosttyApp
    private var surface: ghostty_surface_t?

    /// Initialize the view. When `command` is non-nil libghostty spawns the
    /// process internally inside its own PTY. When nil the view starts with a
    /// surface that has no attached process (idle-passive).
    ///
    /// - Parameters:
    ///   - app: the shared `GhosttyApp` providing `ghostty_app_t`.
    ///   - command: optional executable path (e.g. `/bin/zsh -l` or the
    ///     resolved `claude` path). When non-nil the surface owns the PTY.
    ///   - cwd: optional working directory for the spawned command.
    ///   - frame: initial frame for the view.
    init(app: GhosttyApp, command: String?, cwd: String?, frame: NSRect) {
        self.ghosttyApp = app
        super.init(frame: frame)

        self.wantsLayer = true
        self.layerContentsRedrawPolicy = .duringViewResize
        self.translatesAutoresizingMaskIntoConstraints = false

        createSurface(command: command, cwd: cwd)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    deinit {
        if let s = surface {
            ghostty_surface_free(s)
        }
    }

    // MARK: - Layer backing

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        return layer
    }

    override var wantsUpdateLayer: Bool { true }

    // MARK: - Surface lifecycle

    /// Create a fresh libghostty surface. When `command` is non-nil libghostty
    /// spawns the process inside its own PTY and renders the output natively.
    ///
    /// `command` and `cwd` C-string lifetimes: `strdup`-allocated locally and
    /// freed immediately after `ghostty_surface_new` returns. libghostty copies
    /// the strings into its internal config before returning, so they only need
    /// to be valid across the call.
    private func createSurface(command: String?, cwd: String?) {
        guard surface == nil else { return }

        var cfg = ghostty_surface_config_new()
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(
                nsview: Unmanaged.passUnretained(self).toOpaque()
            )
        )
        cfg.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2.0)
        // 0 = inherit configured default (SF Mono 13pt is libghostty's macOS default).
        cfg.font_size = 0
        cfg.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

        // `strdup` returns memory we own; we free it after the call. libghostty
        // copies the strings before returning per the C ABI contract.
        let commandDup: UnsafeMutablePointer<CChar>? = command.flatMap { strdup($0) }
        let cwdDup: UnsafeMutablePointer<CChar>? = cwd.flatMap { strdup($0) }
        cfg.command = UnsafePointer(commandDup)
        cfg.working_directory = UnsafePointer(cwdDup)

        defer {
            if let p = commandDup { free(p) }
            if let p = cwdDup { free(p) }
        }

        guard let s = ghostty_surface_new(ghosttyApp.cValue, &cfg) else {
            Self.logger.error("ghostty_surface_new returned NULL")
            return
        }
        self.surface = s
        Self.logger.debug("ghostty_surface_new succeeded command=\(command ?? "<nil>", privacy: .public)")
    }

    /// Replace the active surface with one running the new command. Used by
    /// Cmd+T / Cmd+Shift+T to swap libghostty's owned PTY to the new process.
    ///
    /// Implementation: free the current surface then create a new one. The
    /// view's `nsview` userdata pointer stays the same so AppKit hosting is
    /// uninterrupted.
    func replaceCommand(_ command: String?, cwd: String?) {
        if let s = surface {
            ghostty_surface_free(s)
            surface = nil
        }
        createSurface(command: command, cwd: cwd)
        // Re-apply the current bounds so the new surface receives a correct
        // initial size (libghostty surfaces default to 80x24 cells otherwise).
        applySurfaceSize()
    }

    // MARK: - Resize

    override func layout() {
        super.layout()
        applySurfaceSize()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        applySurfaceSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let metalLayer = self.layer as? CAMetalLayer {
            metalLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        }
        applySurfaceSize()
    }

    private func applySurfaceSize() {
        guard let surface = surface else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let pixelWidth = UInt32(max(1, bounds.width * scale))
        let pixelHeight = UInt32(max(1, bounds.height * scale))
        // libghostty's set_size expects pixels for the macOS apprt.
        ghostty_surface_set_size(surface, pixelWidth, pixelHeight)
    }

    // MARK: - Key passthrough

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        Self.logger.debug("becomeFirstResponder -> \(ok, privacy: .public)")
        return ok
    }

    override func keyDown(with event: NSEvent) {
        // Forward typed characters to the libghostty surface. When the surface
        // owns its own PTY (Day 5b model) libghostty routes these keystrokes
        // into the child process automatically; this is the correct usage of
        // `ghostty_surface_text` — the "typed text" semantic.
        guard let chars = event.characters, !chars.isEmpty else {
            super.keyDown(with: event)
            return
        }
        if let surface = surface {
            chars.withCString { ptr in
                ghostty_surface_text(surface, ptr, UInt(chars.utf8.count))
            }
            Self.logger.debug("keyDown -> surface_text len=\(chars.utf8.count, privacy: .public)")
        }
    }

    override func keyUp(with event: NSEvent) {
        // Day 3: keyUp is unused but we override to silence the system beep
        // that NSResponder would emit on unhandled events.
    }
}
