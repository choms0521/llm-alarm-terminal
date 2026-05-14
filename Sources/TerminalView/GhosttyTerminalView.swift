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
    /// pointer 를 paneId 로 환원할 때, 그리고 ViewportPollingTimer 가
    /// SurfaceRegistry 에서 acquireExisting 으로 view 를 찾을 때 anchor 가 된다.
    /// agent-view dashboard 부재 시(P1 path) nil 이면 routing 비활성.
    var paneId: UUID?

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
        // libghostty's set_size expects pixels for the macOS apprt. When the
        // surface owns its own PTY (Day 5b model), libghostty propagates the
        // new size to its internal PTY via TIOCSWINSZ — verified on Day 6 via
        // `tput cols`/`tput lines` reflecting window resizes.
        ghostty_surface_set_size(surface, pixelWidth, pixelHeight)
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
        // Drive the IME pipeline. `interpretKeyEvents` will invoke
        // `setMarkedText` for in-progress composition (e.g. Hangul jamo) and
        // `insertText` for committed text. Both flow through our
        // `NSTextInputClient` conformance below into the libghostty surface.
        //
        // Day 6: this replaces the direct `ghostty_surface_text(event.characters)`
        // path from Day 5b — that path bypassed IMEs and broke composition for
        // Korean / Japanese / Chinese input.
        //
        // For non-text keys (Return, Tab, Backspace, arrows, etc.) AppKit
        // routes the event to `doCommand(by:)` instead of `insertText`. In
        // that case our accumulator stays empty after `interpretKeyEvents`,
        // and we fall back to forwarding `event.characters` directly so
        // control bytes (\r, \t, \b, ESC[...) still reach libghostty.
        guard let surface = surface else {
            super.keyDown(with: event)
            return
        }

        let markedTextBefore = markedText.length > 0

        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        interpretKeyEvents([event])

        // If the IME accumulated text via insertText, our NSTextInputClient
        // hook already forwarded it; nothing more to do.
        if let accumulated = keyTextAccumulator, !accumulated.isEmpty {
            return
        }

        // If the IME is composing (marked text present, or just cleared) the
        // raw event belongs to the IME — do not forward.
        if markedText.length > 0 || markedTextBefore {
            return
        }

        // Non-text key (Return, Tab, Backspace, arrows, ESC, etc.). Forward
        // the raw characters so libghostty can encode the control sequence.
        guard let chars = event.characters, !chars.isEmpty else { return }
        chars.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(chars.utf8.count))
        }
    }

    override func keyUp(with event: NSEvent) {
        // Day 3: keyUp is unused but we override to silence the system beep
        // that NSResponder would emit on unhandled events.
    }

    // Silence the NSResponder system beep for selectors we don't implement.
    // `interpretKeyEvents` routes Return / Tab / Backspace / arrows here.
    // The actual control-character forwarding happens back in `keyDown`'s
    // fallback branch (see comments there).
    override func doCommand(by selector: Selector) {
        // Intentional no-op — see keyDown fallback path.
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

        // Record the commit so `keyDown` knows the IME consumed the event
        // and skips the raw-character fallback. Mirrors
        // `Ghostty.SurfaceView.insertText` accumulator logic.
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(chars)
        }

        guard let surface = surface else { return }
        chars.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(chars.utf8.count))
        }
        Self.logger.debug("insertText -> surface_text len=\(chars.utf8.count, privacy: .public)")
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
