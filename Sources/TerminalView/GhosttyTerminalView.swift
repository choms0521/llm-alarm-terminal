import AppKit
import GhosttyKit
import QuartzCore
import os

/// AppKit view that hosts a single libghostty surface.
///
/// Day 3 scope:
/// - Backed by a CAMetalLayer so libghostty can render via Metal.
/// - Owns one `ghostty_surface_t` whose userdata points back to this view.
/// - Forwards keystrokes to `ghostty_surface_text` (and surface keys for
///   special keys). Full keyboard translation + IME comes Day 4+.
/// - Resizes the surface in pixels on layout.
/// - Injects "hello\r\n" and "한" 1 second after creation so Day 3 exit
///   criteria can be verified visually.
final class GhosttyTerminalView: NSView {
    private static let logger = Logger(subsystem: "com.choms0521.ClaudeAlarmTerminal", category: "GhosttyTerminalView")

    private let ghosttyApp: GhosttyApp
    private var surface: ghostty_surface_t?

    init(app: GhosttyApp, frame: NSRect) {
        self.ghosttyApp = app
        super.init(frame: frame)

        // Configure layer backing: libghostty draws via Metal so we need a
        // CAMetalLayer. AppKit will create the layer when we set wantsLayer +
        // a custom makeBackingLayer implementation.
        self.wantsLayer = true
        self.layerContentsRedrawPolicy = .duringViewResize
        self.translatesAutoresizingMaskIntoConstraints = false

        createSurface()
        scheduleDay3SmokeText()
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

    private func createSurface() {
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

        guard let s = ghostty_surface_new(ghosttyApp.cValue, &cfg) else {
            Self.logger.error("ghostty_surface_new returned NULL")
            return
        }
        self.surface = s
        Self.logger.debug("ghostty_surface_new succeeded")
    }

    /// Day 3 smoke: 1s after surface creation, inject "hello\r\n" and the
    /// Hangul character '한' so the renderer (1) draws ASCII glyphs and
    /// (2) records a 2-cell wide CJK glyph per the wcwidth check deferred
    /// from Day 2.
    private func scheduleDay3SmokeText() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self, let surface = self.surface else { return }
            let hello = "hello\r\n"
            hello.withCString { ptr in
                ghostty_surface_text(surface, ptr, UInt(hello.utf8.count))
            }
            let han = "한"
            han.withCString { ptr in
                ghostty_surface_text(surface, ptr, UInt(han.utf8.count))
            }
            Self.logger.debug("Day 3 smoke text injected: hello + 한")
        }
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
        guard let surface = surface else {
            super.keyDown(with: event)
            return
        }

        // Forward typed text via ghostty_surface_text. This is the minimum
        // viable wiring for Day 3; full ghostty_surface_key translation with
        // physical keycode + modifiers will come with the NSTextInputClient
        // adoption in Day 6.
        if let chars = event.characters, !chars.isEmpty {
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
