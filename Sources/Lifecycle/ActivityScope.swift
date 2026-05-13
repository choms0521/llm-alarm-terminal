import Foundation

/// RAII wrapper around `ProcessInfo.beginActivity(options:reason:)`.
///
/// Day 7 scope (P1 §5.2): a single instance is held by `SessionManager` while
/// at least one session is alive. Its `deinit` calls `endActivity` so the
/// system can resume App Nap. In P1 the option set is fixed at `.userInitiated`
/// — that single flag is enough to keep the PTY reader from being throttled
/// while the GUI is foregrounded. P4 (WS server) will expand the option set
/// (idleSystemSleepDisabled, suddenTerminationDisabled, ...) by changing the
/// call site without modifying this class.
public final class ActivityScope {
    private let token: NSObjectProtocol

    public init(reason: String, options: ProcessInfo.ActivityOptions = .userInitiated) {
        self.token = ProcessInfo.processInfo.beginActivity(options: options, reason: reason)
    }

    deinit {
        ProcessInfo.processInfo.endActivity(token)
    }
}
