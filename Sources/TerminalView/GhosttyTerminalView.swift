import AppKit
import GhosttyKit
import QuartzCore
import os

/// AppKit view that hosts a single libghostty surface.
///
/// Day 6 scope (mouse, scroll, IME polish):
/// - Day 5b base: backed by a CAMetalLayer; one `ghostty_surface_t` whose
///   userdata points back to this view; libghostty owns the PTY via
///   `ghostty_surface_config_s.command`; `keyDown` forwards typed characters.
/// - Day 6 additions:
///   - Mouse buttons (left, right, middle, other) forwarded to
///     `ghostty_surface_mouse_button`.
///   - Mouse movement / drag forwarded to `ghostty_surface_mouse_pos` via a
///     tracking area sized to the view.
///   - Scroll-wheel events forwarded to `ghostty_surface_mouse_scroll` with
///     precision + momentum bits packed into `ghostty_input_scroll_mods_t`.
///   - `NSTextInputClient` conformance so macOS IMEs (Hangul, etc.) drive
///     composition through `setMarkedText` / `insertText`. `keyDown` now calls
///     `interpretKeyEvents` to enter the IME pipeline; composed text arrives
///     via `insertText` and is forwarded with `ghostty_surface_text`. Preedit
///     state goes through `ghostty_surface_preedit`.
final class GhosttyTerminalView: NSView {
    private static let logger = Logger(subsystem: "com.choms0521.ClaudeAlarmTerminal", category: "GhosttyTerminalView")

    private let ghosttyApp: GhosttyApp
    private var surface: ghostty_surface_t?

    /// 본 view 가 매핑된 Pane.id. P3 Day 4 의 SessionActionRouter 가 surfaceUserdata
    /// pointer 를 tabId 로 환원할 때, 그리고 ViewportPollingTimer 가
    /// SurfaceRegistry 에서 acquireExisting 으로 view 를 찾을 때 anchor 가 된다.
    /// agent-view dashboard 부재 시(P1 path) nil 이면 routing 비활성.
    var tabId: UUID?

    /// libghostty surface 핸들 read-only 접근자. GhosttyViewportProvider 가
    /// `ghostty_surface_read_text` 를 호출한 뒤 반드시
    /// `defer { ghostty_surface_free_text(...) }` 로 1:1 alloc/free 를 강제하면서
    /// viewport 를 폴링한다.
    var surfaceHandle: ghostty_surface_t? { surface }

    /// Tracking area for mouseMoved / mouseEntered / mouseExited. Recreated
    /// on `updateTrackingAreas` so it always matches the current bounds.
    private var trackingArea: NSTrackingArea?

    /// Marked (preedit) text from the active IME composition. Kept as an
    /// `NSMutableAttributedString` so `NSTextInputClient` can mutate in place;
    /// committed text moves out via `insertText` (which calls
    /// `ghostty_surface_text`) and clears this buffer.
    private var markedText = NSMutableAttributedString()

    /// While non-nil, we are inside a `keyDown -> interpretKeyEvents` call.
    /// `insertText` appends committed text here so `keyDown` can decide
    /// whether the IME consumed the event or whether we still need to send
    /// the raw characters (Return, Tab, Backspace, arrow keys, etc) ourselves.
    /// Pattern lifted from `Ghostty.SurfaceView.keyTextAccumulator`.
    private var keyTextAccumulator: [String]?

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
    init(app: GhosttyApp, tabId: UUID? = nil, command: String?, cwd: String?, frame: NSRect) {
        self.ghosttyApp = app
        self.tabId = tabId
        super.init(frame: frame)

        self.wantsLayer = true
        self.layerContentsRedrawPolicy = .duringViewResize
        self.translatesAutoresizingMaskIntoConstraints = false

        let viewPtr = Unmanaged.passUnretained(self).toOpaque()
        Self.logger.info("[R2-DIAG] init tabId=\(tabId?.uuidString.prefix(8) ?? "nil", privacy: .public) viewPtr=\(String(describing: viewPtr), privacy: .public) command=\(command ?? "<nil>", privacy: .public)")

        createSurface(command: command, cwd: cwd)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    deinit {
        let viewPtr = Unmanaged.passUnretained(self).toOpaque()
        Self.logger.info("[R2-DIAG] deinit tabId=\(self.tabId?.uuidString.prefix(8) ?? "nil", privacy: .public) viewPtr=\(String(describing: viewPtr), privacy: .public) surface=\(String(describing: self.surface), privacy: .public)")
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
        let viewPtr = Unmanaged.passUnretained(self).toOpaque()
        Self.logger.info("[R2-DIAG] surface_new tabId=\(self.tabId?.uuidString.prefix(8) ?? "nil", privacy: .public) viewPtr=\(String(describing: viewPtr), privacy: .public) surface=\(String(describing: s), privacy: .public)")
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
        applySurfaceSize(for: bounds.size)
    }

    // MARK: - Resize
    //
    // R2 fix (cmux 정도): SwiftUI NSViewRepresentable routes size changes via
    // `layout()` (not `setFrameSize`). cmux's `GhosttyTerminalView.swift`
    // hooks both `layout()` and `viewDidChangeBackingProperties` and applies
    // FOUR things in one atomic pass:
    //   ① layer.contentsScale            — AppKit pixel scale
    //   ② metalLayer.drawableSize        — Metal framebuffer pixel size
    //   ③ ghostty_surface_set_content_scale — libghostty cell-pixel calibration
    //   ④ ghostty_surface_set_size       — libghostty grid + PTY winsize
    //
    // Missing ② caused the Metal drawable to lag bounds → visible corruption.
    // Missing ③ caused libghostty's cell measurement to drift from layer
    // pixels → cursor escapes (ESC[r;cH) landed at wrong cells → claude TUI
    // box drawing fragmented + stale cells retained.
    //
    // Dedup gates (`lastAppliedSize`, `lastContentScale`, `lastDrawableSize`)
    // prevent SIGWINCH storms during `layout()` invalidation churn.

    private var lastAppliedSize: CGSize?
    private var lastContentScale: CGFloat?
    private var lastDrawableSize: CGSize?

    /// Pixel dimensions whose `ghostty_surface_set_size` was deferred because
    /// AppKit was in live resize. Flushed by `viewDidEndLiveResize`. Storing
    /// only the final pending size (overwritten on each layout pass) means
    /// claude receives at most one SIGWINCH per resize gesture instead of
    /// hundreds — preventing duplicated alt-screen redraws that previously
    /// littered the primary screen scrollback as W₁-wrap + W₂-wrap artifacts.
    private var pendingPixelSize: (UInt32, UInt32)?

    override func layout() {
        super.layout()
        applySurfaceSize(for: bounds.size)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applySurfaceSize(for: newSize)
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        flushPendingResizeIfAny()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // Backing scale change invalidates pixel mapping; force a re-apply.
        lastAppliedSize = nil
        lastContentScale = nil
        lastDrawableSize = nil
        applySurfaceSize(for: bounds.size)
    }

    /// Apply the final size saved during live resize. Called when AppKit
    /// finishes its live-resize gesture so claude only sees one SIGWINCH.
    private func flushPendingResizeIfAny() {
        guard let surface = surface else { return }
        guard let pending = pendingPixelSize else { return }
        pendingPixelSize = nil
        Self.logger.info("[R2-DIAG] set_size FLUSH (post-live) tabId=\(self.tabId?.uuidString.prefix(8) ?? "nil", privacy: .public) px=\(pending.0, privacy: .public)x\(pending.1, privacy: .public)")
        ghostty_surface_set_size(surface, pending.0, pending.1)
    }

    private func applySurfaceSize(for size: CGSize) {
        guard let surface = surface else {
            Self.logger.info("[R2-DIAG] applySurfaceSize SKIP (no surface) tabId=\(self.tabId?.uuidString.prefix(8) ?? "nil", privacy: .public)")
            return
        }
        // Dedup gate: skip when size has not actually changed.
        if let last = lastAppliedSize, last == size {
            return
        }
        guard size.width > 0, size.height > 0 else { return }
        lastAppliedSize = size

        // Pixel conversion — vendor cmux pattern (GhosttyTerminalView.swift:6653).
        let layerScale = max(1.0, window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0)
        let backing: CGSize
        if window != nil {
            backing = convertToBacking(NSRect(origin: .zero, size: size)).size
        } else {
            backing = CGSize(width: size.width * layerScale, height: size.height * layerScale)
        }
        guard backing.width > 0, backing.height > 0 else { return }

        let xScale = backing.width / max(1, size.width)
        let yScale = backing.height / max(1, size.height)
        let drawable = CGSize(width: floor(backing.width), height: floor(backing.height))

        // ① + ② Layer/drawable pixel sync — atomic, no implicit animation.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.layer?.contentsScale = layerScale
        if let metal = self.layer as? CAMetalLayer {
            if lastDrawableSize != drawable || metal.drawableSize != drawable {
                metal.drawableSize = drawable
                lastDrawableSize = drawable
            }
        }
        CATransaction.commit()

        // ③ libghostty cell-pixel calibration — only on scale change.
        if lastContentScale != layerScale {
            ghostty_surface_set_content_scale(surface, xScale, yScale)
            lastContentScale = layerScale
        }

        // ④ libghostty grid + PTY winsize.
        let wpx = UInt32(max(1, drawable.width))
        let hpx = UInt32(max(1, drawable.height))
        let live = self.inLiveResize || (self.window?.inLiveResize == true)
        if live {
            // Defer to viewDidEndLiveResize. Layer + drawableSize already
            // updated above so the visible rendering remains smooth during
            // drag; only the PTY-bound size is held back.
            pendingPixelSize = (wpx, hpx)
            Self.logger.info("[R2-DIAG] set_size DEFER (live) tabId=\(self.tabId?.uuidString.prefix(8) ?? "nil", privacy: .public) px=\(wpx, privacy: .public)x\(hpx, privacy: .public)")
            return
        }
        pendingPixelSize = nil
        Self.logger.info("[R2-DIAG] set_size tabId=\(self.tabId?.uuidString.prefix(8) ?? "nil", privacy: .public) size=\(size.width, privacy: .public)x\(size.height, privacy: .public) px=\(wpx, privacy: .public)x\(hpx, privacy: .public) scale=\(layerScale, privacy: .public)")
        ghostty_surface_set_size(surface, wpx, hpx)
    }

    // MARK: - Tracking area (mouse moved/entered/exited)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let existing = trackingArea {
            removeTrackingArea(existing)
            trackingArea = nil
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [
                .mouseEnteredAndExited,
                .mouseMoved,
                .inVisibleRect,
                .activeAlways,
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - Key passthrough

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        Self.logger.debug("becomeFirstResponder -> \(ok, privacy: .public)")
        return ok
    }

    override func keyDown(with event: NSEvent) {
        // Drive the IME pipeline first. `interpretKeyEvents` calls
        // `setMarkedText` while composing (e.g. Hangul jamo) and `insertText`
        // when committing. For non-text keys (Return, Tab, Backspace, arrows,
        // ESC etc.) AppKit routes to `doCommand(by:)` and the accumulator
        // stays empty.
        //
        // P3 Recovery: All forwarding now goes through `ghostty_surface_key`
        // (not `ghostty_surface_text`). That API is the only one that
        // properly encodes control bytes — DEL/BS/Enter/Tab/arrows etc. —
        // into the PTY input stream. The previous direct
        // `ghostty_surface_text(event.characters)` fallback caused Backspace
        // to advance the cursor instead of deleting and broke arrow keys.
        guard surface != nil else {
            super.keyDown(with: event)
            return
        }

        let markedTextBefore = markedText.length > 0

        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        interpretKeyEvents([event])

        let action: ghostty_input_action_e = event.isARepeat
            ? GHOSTTY_ACTION_REPEAT
            : GHOSTTY_ACTION_PRESS
        let composing = markedText.length > 0 || markedTextBefore

        // IME committed text → forward each commit as a key event with `text`.
        if let accumulated = keyTextAccumulator, !accumulated.isEmpty {
            for text in accumulated {
                _ = keyAction(action, event: event, text: text)
            }
            return
        }

        // Still composing (marked text present) or just cleared marked text:
        // the raw event belongs to the IME, not the terminal.
        if composing {
            return
        }

        // Non-text key (Return, Tab, Backspace, arrows, ESC, etc.).
        _ = keyAction(action, event: event, text: Self.ghosttyCharacters(event))
    }

    override func keyUp(with event: NSEvent) {
        _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    /// Build a `ghostty_input_key_s` from an `NSEvent` and hand it to
    /// `ghostty_surface_key`. This is the single API that knows how to encode
    /// control bytes (BS/DEL/Tab/Enter/arrows/ESC sequences) into PTY input.
    ///
    /// Pattern lifted from `vendor/ghostty/macos/Sources/Ghostty/Surface
    /// View/SurfaceView_AppKit.swift::keyAction` (line 1416).
    @discardableResult
    private func keyAction(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        text: String? = nil
    ) -> Bool {
        guard let surface = surface else { return false }

        var key_ev = ghostty_input_key_s()
        key_ev.action = action
        key_ev.keycode = UInt32(event.keyCode)
        key_ev.text = nil
        key_ev.composing = false
        key_ev.mods = Self.ghosttyMods(event.modifierFlags)
        key_ev.consumed_mods = Self.ghosttyMods(
            event.modifierFlags.subtracting([.control, .command])
        )
        key_ev.unshifted_codepoint = 0
        if event.type == .keyDown || event.type == .keyUp {
            if let chars = event.characters(byApplyingModifiers: []),
               let codepoint = chars.unicodeScalars.first {
                key_ev.unshifted_codepoint = codepoint.value
            }
        }

        // Only attach `text` when it is a real printable string; control
        // characters (< 0x20) are encoded by libghostty itself based on
        // `keycode` + `mods` so attaching them would double-encode.
        if let text, !text.isEmpty,
           let codepoint = text.utf8.first, codepoint >= 0x20 {
            return text.withCString { ptr in
                key_ev.text = ptr
                return ghostty_surface_key(surface, key_ev)
            }
        } else {
            return ghostty_surface_key(surface, key_ev)
        }
    }

    /// Extract the text portion of a key event, dropping control bytes and
    /// macOS private-use area (function key) values. Mirrors
    /// `NSEvent.ghosttyCharacters` in the upstream extension.
    private static func ghosttyCharacters(_ event: NSEvent) -> String? {
        guard let characters = event.characters else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return event.characters(
                    byApplyingModifiers: event.modifierFlags.subtracting(.control)
                )
            }
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }
        return characters
    }

    // Silence the NSResponder system beep for selectors we don't implement.
    // `interpretKeyEvents` routes Return / Tab / Backspace / arrows here.
    // The actual control-character forwarding happens back in `keyDown`'s
    // fallback branch (see comments there).
    override func doCommand(by selector: Selector) {
        // Intentional no-op — see keyDown fallback path.
    }

    // MARK: - Edit actions (Cmd+C / Cmd+V / Cmd+A) + right-click context menu
    //
    // Routed through the standard responder chain by the Edit menu and the
    // overridden `menu(for:)` below. Each action delegates to libghostty's
    // binding system via `ghostty_surface_binding_action` so clipboard handling
    // matches Ghostty proper (terminal mode awareness, bracketed paste, OSC52,
    // selection tracking from mouseDragged). Mirrors vendor
    // SurfaceView_AppKit.swift:1589.

    @IBAction func paste(_ sender: Any?) {
        invokeBindingAction("paste_from_clipboard")
    }

    @IBAction func copy(_ sender: Any?) {
        invokeBindingAction("copy_to_clipboard")
    }

    @IBAction override func selectAll(_ sender: Any?) {
        invokeBindingAction("select_all")
    }

    @IBAction func resetTerminal(_ sender: Any?) {
        invokeBindingAction("reset")
    }

    private func invokeBindingAction(_ action: String) {
        guard let surface = surface else { return }
        let ok = action.withCString { ptr in
            ghostty_surface_binding_action(surface, ptr, UInt(action.lengthOfBytes(using: .utf8)))
        }
        if !ok {
            Self.logger.warning("ghostty_surface_binding_action failed action=\(action, privacy: .public)")
        }
    }

    // Right-click context menu. AppKit calls `menu(for:)` for any right mouse
    // event. We provide Copy / Paste / Select All / Reset Terminal — selection
    // is already tracked by libghostty via the mouseDragged forwarding.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard event.type == .rightMouseDown else { return nil }
        let menu = NSMenu(title: "Terminal")
        menu.addItem(withTitle: "복사", action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "붙여넣기", action: #selector(paste(_:)), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "모두 선택", action: #selector(selectAll(_:)), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "터미널 리셋", action: #selector(resetTerminal(_:)), keyEquivalent: "")
        return menu
    }

    // MARK: - Mouse buttons

    override func mouseDown(with event: NSEvent) {
        guard let surface = surface else { return super.mouseDown(with: event) }
        let mods = Self.ghosttyMods(event.modifierFlags)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface = surface else { return super.mouseUp(with: event) }
        let mods = Self.ghosttyMods(event.modifierFlags)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface = surface else { return super.rightMouseDown(with: event) }
        let mods = Self.ghosttyMods(event.modifierFlags)
        let consumed = ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, mods
        )
        if !consumed { super.rightMouseDown(with: event) }
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface = surface else { return super.rightMouseUp(with: event) }
        let mods = Self.ghosttyMods(event.modifierFlags)
        let consumed = ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, mods
        )
        if !consumed { super.rightMouseUp(with: event) }
    }

    override func otherMouseDown(with event: NSEvent) {
        guard let surface = surface else { return super.otherMouseDown(with: event) }
        let mods = Self.ghosttyMods(event.modifierFlags)
        let button = Self.mouseButton(fromNSEventButtonNumber: event.buttonNumber)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, button, mods)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard let surface = surface else { return super.otherMouseUp(with: event) }
        let mods = Self.ghosttyMods(event.modifierFlags)
        let button = Self.mouseButton(fromNSEventButtonNumber: event.buttonNumber)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, button, mods)
    }

    // MARK: - Mouse movement

    override func mouseMoved(with event: NSEvent) {
        forwardMousePos(event)
    }

    override func mouseDragged(with event: NSEvent) {
        forwardMousePos(event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        forwardMousePos(event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        forwardMousePos(event)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        forwardMousePos(event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard let surface = surface else { return }
        // Negative values indicate the cursor has left the viewport — matches
        // Ghostty's reference implementation, which uses (-1, -1) to mean
        // "outside" so libghostty can suppress mouse reports.
        let mods = Self.ghosttyMods(event.modifierFlags)
        ghostty_surface_mouse_pos(surface, -1, -1, mods)
    }

    private func forwardMousePos(_ event: NSEvent) {
        guard let surface = surface else { return }
        // Convert window-coord -> view-coord. AppKit's origin is bottom-left;
        // libghostty wants top-left, so we flip Y against the view height.
        let pos = convert(event.locationInWindow, from: nil)
        let x = pos.x
        let y = bounds.height - pos.y
        let mods = Self.ghosttyMods(event.modifierFlags)
        ghostty_surface_mouse_pos(surface, x, y, mods)
    }

    // MARK: - Scroll

    override func scrollWheel(with event: NSEvent) {
        guard let surface = surface else { return super.scrollWheel(with: event) }

        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precision = event.hasPreciseScrollingDeltas
        if precision {
            // Ghostty's reference applies a 2x speed multiplier on
            // high-precision deltas to compensate for trackpad scroll units
            // being smaller than wheel ticks. Day 6 follow-up may re-tune.
            x *= 2
            y *= 2
        }

        let mods = Self.scrollMods(precision: precision, momentum: event.momentumPhase)
        ghostty_surface_mouse_scroll(surface, x, y, mods)
    }

    // MARK: - Helpers

    /// Pack `NSEvent.ModifierFlags` into a `ghostty_input_mods_e` bitmask. The
    /// shape mirrors `Ghostty.ghosttyMods` from the upstream macOS app — we
    /// keep the function local so we don't reach across into the vendor
    /// Swift sources (only the C ABI is consumed).
    private static func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(mods)
    }

    /// Map `NSEvent.buttonNumber` to `ghostty_input_mouse_button_e`. Day 6
    /// covers the common buttons; extras (back/forward) fall through to
    /// the corresponding higher Ghostty buttons.
    private static func mouseButton(fromNSEventButtonNumber n: Int) -> ghostty_input_mouse_button_e {
        switch n {
        case 0: return GHOSTTY_MOUSE_LEFT
        case 1: return GHOSTTY_MOUSE_RIGHT
        case 2: return GHOSTTY_MOUSE_MIDDLE
        case 3: return GHOSTTY_MOUSE_EIGHT   // Back button
        case 4: return GHOSTTY_MOUSE_NINE    // Forward button
        default: return GHOSTTY_MOUSE_UNKNOWN
        }
    }

    /// Pack precision + momentum into `ghostty_input_scroll_mods_t`. The
    /// bit layout matches `src/input/mouse.zig::ScrollMods` and mirrors
    /// Ghostty's Swift `ScrollMods.init(precision:momentum:)`:
    ///   bit 0    -> precision flag
    ///   bits 1-3 -> momentum phase (0=none, 1=began, 2=stationary, 3=changed,
    ///               4=ended, 5=cancelled, 6=mayBegin)
    private static func scrollMods(
        precision: Bool,
        momentum: NSEvent.Phase
    ) -> ghostty_input_scroll_mods_t {
        var value: Int32 = 0
        if precision { value |= 0b0000_0001 }
        let momentumBits: Int32
        switch momentum {
        case .began: momentumBits = 1
        case .stationary: momentumBits = 2
        case .changed: momentumBits = 3
        case .ended: momentumBits = 4
        case .cancelled: momentumBits = 5
        case .mayBegin: momentumBits = 6
        default: momentumBits = 0
        }
        value |= momentumBits << 1
        return ghostty_input_scroll_mods_t(value)
    }
}

// MARK: - NSTextInputClient (IME / preedit)

extension GhosttyTerminalView: NSTextInputClient {
    // Implementation note: the bodies here are deliberately minimal-but-correct
    // following the template in
    // `vendor/ghostty/macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift:1843`.
    // We do NOT consult libghostty for selection / IME-point queries because
    // we have not yet wired the corresponding C ABI calls (`ghostty_surface_read_selection`,
    // `ghostty_surface_ime_point`). Day 7+ can add them when QuickLook / IME
    // rect-positioning becomes a priority. For Korean composition the path
    // through `setMarkedText` + `unmarkText` + `insertText` is sufficient.

    func hasMarkedText() -> Bool {
        return markedText.length > 0
    }

    func markedRange() -> NSRange {
        guard markedText.length > 0 else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: 0, length: markedText.length)
    }

    func selectedRange() -> NSRange {
        // Day 6 follow-up -> Day 7+: query libghostty selection via
        // `ghostty_surface_read_selection` when needed. Returning empty is
        // safe for IME composition.
        return NSRange(location: NSNotFound, length: 0)
    }

    func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        switch string {
        case let v as NSAttributedString:
            markedText = NSMutableAttributedString(attributedString: v)
        case let v as String:
            markedText = NSMutableAttributedString(string: v)
        default:
            Self.logger.debug("setMarkedText: unknown type \(String(describing: type(of: string)), privacy: .public)")
            return
        }
        syncPreedit()
    }

    func unmarkText() {
        if markedText.length > 0 {
            markedText.mutableString.setString("")
            syncPreedit()
        }
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        return []
    }

    func attributedSubstring(
        forProposedRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSAttributedString? {
        // Day 6 follow-up -> Day 7+: implement via `ghostty_surface_read_selection`
        // for QuickLook / dictionary lookup. nil is the safe default.
        return nil
    }

    func characterIndex(for point: NSPoint) -> Int {
        return NSNotFound
    }

    func firstRect(
        forCharacterRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSRect {
        // Day 6 follow-up -> Day 7+: query `ghostty_surface_ime_point` for
        // a precise IME caret rect. Falling back to the view's window rect
        // means the IME candidate window appears near the top-left of the
        // terminal; functional but not pixel-perfect.
        guard let window = window else {
            return NSRect(x: 0, y: 0, width: 0, height: 0)
        }
        let viewRect = NSRect(x: 0, y: bounds.height, width: 0, height: 0)
        let winRect = convert(viewRect, to: nil)
        return window.convertToScreen(winRect)
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        // Resolve to a Swift String regardless of whether AppKit sent us
        // NSAttributedString or String.
        let chars: String
        switch string {
        case let v as NSAttributedString:
            chars = v.string
        case let v as String:
            chars = v
        default:
            return
        }

        // Composition committed -> drop any preedit state before forwarding.
        unmarkText()

        guard !chars.isEmpty else { return }

        // Inside `keyDown -> interpretKeyEvents`: just record the commit; the
        // outer `keyDown` runs `keyAction` with this text so it flows through
        // `ghostty_surface_key`. Mirrors upstream `SurfaceView.insertText`.
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(chars)
            return
        }

        // Outside a keyDown (e.g. menu-driven character palette / dictation):
        // there is no NSEvent to build a key event from, so push the text
        // directly via the IME commit API.
        guard let surface = surface else { return }
        chars.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(chars.utf8.count))
        }
        Self.logger.debug("insertText (no event) -> surface_text len=\(chars.utf8.count, privacy: .public)")
    }

    // MARK: Preedit helpers

    /// Push the current marked text to libghostty as preedit. Mirrors
    /// `Ghostty.SurfaceView.syncPreedit` — when empty we send a NULL pointer
    /// so libghostty clears the preedit overlay.
    private func syncPreedit() {
        guard let surface = surface else { return }
        if markedText.length > 0 {
            let str = markedText.string
            str.withCString { ptr in
                ghostty_surface_preedit(surface, ptr, UInt(str.utf8.count))
            }
        } else {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }
}
