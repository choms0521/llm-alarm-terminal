import Foundation
import AppKit
import GhosttyKit
import os

/// Owns the single process-wide `ghostty_app_t` instance.
///
/// Day 5b scope: identical to Day 3 construction, but the underlying
/// `ghostty_app_t` handle is now exposed via `unsafeApp` so views can call
/// `ghostty_surface_new(app, &cfg)` directly. This is required for the
/// libghostty-internal PTY pivot where the surface owns its own PTY via the
/// `ghostty_surface_config_s.command` field.
final class GhosttyApp {
    static let logger = Logger(subsystem: "com.choms0521.ClaudeAlarmTerminal", category: "GhosttyApp")

    /// The underlying libghostty app handle.
    /// Force-unwrapped optional so we can construct it after the `super.init`
    /// equivalent point — `init?` returns nil before assigning it on failure.
    private(set) var cValue: ghostty_app_t!

    /// Public accessor for the underlying `ghostty_app_t`. Views use this to
    /// create surfaces via `ghostty_surface_new`. Marked `unsafe` in its name
    /// because callers must respect libghostty's lifecycle rules — they must
    /// not free the handle and must not retain it past this `GhosttyApp`
    /// instance's lifetime.
    var unsafeApp: ghostty_app_t { cValue }

    /// The libghostty config used to create the app. Kept alive until deinit.
    private let config: ghostty_config_t

    /// Holds a `+1` retain on `self` so the userdata pointer passed into
    /// libghostty stays valid for the app's lifetime. Released on deinit.
    private var selfRetain: Unmanaged<GhosttyApp>?

    /// Coalesces wakeup_cb → ghostty_app_tick dispatches. The I/O thread can
    /// fire wakeup_cb hundreds of times per second during heavy PTY output
    /// (claude streaming). Each wakeup means "main thread, please drain the
    /// event queue". Without coalescing we would enqueue N main-queue blocks
    /// per second; with coalescing we enqueue at most one pending tick at any
    /// time. cmux uses the same pattern (GhosttyTerminalView.swift:1680, 3033).
    ///
    /// Guarded by `tickStateLock` because the flag is checked/set on the I/O
    /// thread but cleared on main thread. NSLock keeps the critical section
    /// trivially small.
    private let tickStateLock = NSLock()
    private var tickPending: Bool = false

    init?() {
        // Step 1: ghostty_init must be called once per process before any other
        // API. Day 2's GhostBridgeVerifier already proved this works.
        var argv: UnsafeMutablePointer<CChar>? = nil
        let initRc = ghostty_init(0, &argv)
        guard initRc == GHOSTTY_SUCCESS else {
            Self.logger.error("ghostty_init failed rc=\(initRc, privacy: .public)")
            return nil
        }

        // Step 2: build a default config. Day 3 does not load files; we use
        // the built-in defaults so SF Mono 13pt and the default color scheme
        // apply automatically.
        guard let cfg = ghostty_config_new() else {
            Self.logger.error("ghostty_config_new returned NULL")
            return nil
        }
        ghostty_config_finalize(cfg)
        self.config = cfg
        self.cValue = nil

        // Step 3: build the runtime config. The userdata is an opaque pointer
        // back to `self` so the callbacks can find us. All stored properties
        // are now initialized so it is safe to take a retain on `self`.
        let retained = Unmanaged.passRetained(self as GhosttyApp)
        self.selfRetain = retained

        var runtime_cfg = ghostty_runtime_config_s(
            userdata: retained.toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: { userdata in
                // R2 fix: libghostty's I/O thread fires wakeup_cb whenever
                // the embedded event queue has pending work (PTY output,
                // size updates, actions, render dispatches). Skipping it
                // (the prior no-op) caused events to accumulate, leading
                // to delayed/duplicated frames and the "TUI rendered twice"
                // corruption visible after a few minutes of streaming.
                // We hop to main and call ghostty_app_tick, coalescing
                // multiple wakeups into one pending tick.
                guard let userdata = userdata else { return }
                let app = Unmanaged<GhosttyApp>.fromOpaque(userdata).takeUnretainedValue()
                app.requestTick()
            },
            action_cb: { _, target, action in
                // P3 Day 4: action_cb 는 libghostty 의 read/write/render thread 중
                // 어디에서든 동기 invoke 된다(vendor/ghostty/src/apprt/embedded.zig:267-287).
                // callback 진입 즉시 payload 만 추출하고 dispatch 는 main thread hop.
                // 포인터는 hop 후 invalid 일 수 있으므로 sendable struct 로 copy.
                let actionTag: ActionTag
                switch action.tag {
                case GHOSTTY_ACTION_RING_BELL: actionTag = .ringBell
                case GHOSTTY_ACTION_COMMAND_FINISHED: actionTag = .commandFinished
                case GHOSTTY_ACTION_PROMPT_TITLE: actionTag = .promptTitle
                case GHOSTTY_ACTION_PROGRESS_REPORT: actionTag = .progressReport
                default: actionTag = .unknown(rawValue: action.tag.rawValue)
                }
                let surfaceUserdata: UnsafeMutableRawPointer? = {
                    if target.tag == GHOSTTY_TARGET_SURFACE,
                       let surface = target.target.surface {
                        return ghostty_surface_userdata(surface)
                    }
                    return nil
                }()
                let payload = ActionPayload()
                DispatchQueue.main.async {
                    SessionActionRouter.shared?.dispatch(
                        tag: actionTag,
                        surfaceUserdata: surfaceUserdata,
                        payload: payload
                    )
                }
                return true
            },
            read_clipboard_cb: { userdata, _, state in
                // P3.5 R-1: libghostty passes the surface userdata (not the app
                // userdata) to clipboard callbacks — same convention as vendor
                // Ghostty.App.surfaceUserdata. We extract the GhosttyTerminalView,
                // pull the current string from NSPasteboard, then deliver it
                // back via ghostty_surface_complete_clipboard_request.
                guard let userdata = userdata else { return false }
                let view = Unmanaged<GhosttyTerminalView>.fromOpaque(userdata).takeUnretainedValue()
                guard let surface = view.surfaceHandle else { return false }
                guard let str = NSPasteboard.general.string(forType: .string),
                      !str.isEmpty else { return false }
                str.withCString { ptr in
                    ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
                }
                return true
            },
            confirm_read_clipboard_cb: { _, _, _, _ in
                // Read confirmation flow (OSC52 read-from-app) not surfaced in
                // P3.5 — silently no-op. libghostty falls back to the unconfirmed
                // path. Add a confirmation dialog in P4+ if OSC52 read support
                // becomes a security requirement.
            },
            write_clipboard_cb: { _, _, content, len, _ in
                // P3.5 R-1: forward libghostty's clipboard writes (Copy / OSC52
                // write / selection copy) into NSPasteboard.general with proper
                // MIME → NSPasteboardType mapping. Pattern mirrors vendor
                // Ghostty.App.writeClipboard. libghostty emits both text/plain
                // and text/html for the same selection so rich-text destinations
                // get formatting while terminals get raw text. Without the
                // mapping, all entries collapse to .string and the last one
                // (HTML markup) overwrites the plain text — surfaced 2026-05-15
                // as `<div style=...>` pasted into TextEdit.
                guard let content = content, len > 0 else { return }
                var collected: [(NSPasteboard.PasteboardType, String)] = []
                for i in 0..<len {
                    let entry = content[i]
                    guard let dataPtr = entry.data, let mimePtr = entry.mime else { continue }
                    let mime = String(cString: mimePtr)
                    let data = String(cString: dataPtr)
                    let pbType: NSPasteboard.PasteboardType?
                    switch mime {
                    case "text/plain": pbType = .string
                    case "text/html": pbType = .html
                    case "text/rtf": pbType = .rtf
                    default: pbType = nil
                    }
                    if let pbType = pbType {
                        collected.append((pbType, data))
                    }
                }
                guard !collected.isEmpty else { return }
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.declareTypes(collected.map { $0.0 }, owner: nil)
                for (type, data) in collected {
                    pb.setString(data, forType: type)
                }
            },
            close_surface_cb: { _, processAlive in
                GhosttyApp.logger.debug("close_surface_cb processAlive=\(processAlive, privacy: .public)")
            }
        )

        // Step 4: create the libghostty app. Ownership of `config` transfers
        // to libghostty per the C ABI contract.
        guard let app = ghostty_app_new(&runtime_cfg, cfg) else {
            Self.logger.error("ghostty_app_new returned NULL")
            retained.release()
            ghostty_config_free(cfg)
            return nil
        }
        self.cValue = app

        Self.logger.debug("GhosttyApp initialized")
    }

    deinit {
        ghostty_app_free(cValue)
        selfRetain?.release()
    }

    /// Pump libghostty's internal event loop. Should be called on main thread
    /// after surface input is delivered.
    func tick() {
        ghostty_app_tick(cValue)
    }

    /// Schedule a coalesced `ghostty_app_tick` on the main queue. Safe to call
    /// from any thread (typically libghostty's I/O thread via wakeup_cb).
    /// While a tick is pending, additional requests are dropped — the pending
    /// tick will drain all queued events.
    func requestTick() {
        tickStateLock.lock()
        if tickPending {
            tickStateLock.unlock()
            return
        }
        tickPending = true
        tickStateLock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.tickStateLock.lock()
            self.tickPending = false
            self.tickStateLock.unlock()
            ghostty_app_tick(self.cValue)
        }
    }
}
