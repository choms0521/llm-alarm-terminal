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
            wakeup_cb: { _ in
                // Day 3: render-tick wakeup is no-op. Day 5+ will dispatch
                // a CADisplayLink/CVDisplayLink callback here.
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
            read_clipboard_cb: { _, _, _ in
                // Day 3: clipboard not supported. Return false so libghostty
                // treats reads as failed/empty.
                return false
            },
            confirm_read_clipboard_cb: { _, _, _, _ in
                // Day 3: no confirmation flow.
            },
            write_clipboard_cb: { _, _, _, _, _ in
                // Day 3: writes are dropped.
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
}
