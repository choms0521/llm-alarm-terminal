import Darwin
import Foundation

/// Errors thrown by `SessionManager`. The thrown messages are intentionally
/// Korean per P1 plan §5.3 — they are user-facing copy in dialogs.
public enum ManagerError: Error, CustomStringConvertible, Equatable {
    case maxSessionsReached(currentMax: Int)
    case notFound(id: UUID)
    case spawnFailed(underlying: String)

    public var description: String {
        switch self {
        case .maxSessionsReached:
            return "이번 단계에서는 세션 1개만 허용됩니다."
        case .notFound(let id):
            return "세션을 찾을 수 없습니다 (id=\(id.uuidString))."
        case .spawnFailed(let underlying):
            return "세션을 시작하지 못했습니다: \(underlying)"
        }
    }
}

/// Process-wide session registry. Single-actor by design so all mutations
/// serialize behind the actor's executor.
///
/// P1 invariant: `maxSessions` is clamped to 1. Any attempt to set it higher
/// via `CHAT_TERMINAL_MAX_SESSIONS` is silently clamped; values <= 0 fall back
/// to 1. The Korean error in `ManagerError.maxSessionsReached` describes the
/// behavior to the user.
public actor SessionManager {
    public private(set) var sessions: [UUID: Session] = [:]
    public private(set) var lastClaudeSessionId: String?
    private let maxSessions: Int

    /// Held while at least one session exists. Released once every session
    /// reaches `.exited`. Day 7 wiring: keeps the PTY reader resilient to
    /// App Nap throttling. See `Sources/Lifecycle/ActivityScope.swift`.
    private var activityScope: ActivityScope?

    /// Override knob for tests. Pass `nil` to read `CHAT_TERMINAL_MAX_SESSIONS`
    /// from the process environment (default behavior in production).
    public init(maxSessionsOverride: Int? = nil) {
        let raw: Int
        if let override = maxSessionsOverride {
            raw = override
        } else if let envStr = ProcessInfo.processInfo.environment["CHAT_TERMINAL_MAX_SESSIONS"],
                  let envInt = Int(envStr) {
            raw = envInt
        } else {
            raw = 1
        }
        // P1 clamp: max is 1. A request for "0 or negative" also clamps to 1
        // so the app can always create at least one session.
        self.maxSessions = max(1, min(1, raw))
    }

    /// Spawns a new PTY via `PTYSpawner` (external path) and tracks it. Used
    /// by headless verifiers (`SessionVerifier`) and future Day 4-style tests
    /// where the caller owns the PTY master fd directly.
    ///
    /// Concurrency note: `create` is one of two mutation entries that allocate
    /// new sessions (the other is `createInternal`), so the actor's serialized
    /// executor guarantees the "exactly one session" invariant under concurrent
    /// callers across both creates.
    public func create(
        kind: SessionKind,
        cwd: String,
        rows: UInt16,
        cols: UInt16
    ) async throws -> Session {
        if sessions.count >= maxSessions {
            throw ManagerError.maxSessionsReached(currentMax: maxSessions)
        }

        let command: String
        let args: [String]
        switch kind {
        case .claude:
            command = try resolveClaudeBinary()
            args = []
        case .shell:
            let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            command = shellPath
            // Login mode so the shell sources its profile and the prompt looks
            // like a normal interactive Terminal.
            args = ["-l"]
        }

        let handle: PTYHandle
        do {
            handle = try PTYSpawner.spawn(
                command: command,
                args: args,
                cwd: cwd,
                env: nil,
                rows: rows,
                cols: cols
            )
        } catch {
            throw ManagerError.spawnFailed(underlying: String(describing: error))
        }

        let session = Session(
            kind: kind,
            origin: .external,
            ptyHandle: handle,
            cwd: cwd
        )
        sessions[session.id] = session
        ensureActivityScope()
        return session
    }

    /// Records a session whose PTY is owned internally by libghostty (Day 5b
    /// GUI path). The caller (`AppDelegate`) is responsible for swapping the
    /// surface to the new command before this is called; this method only
    /// updates the registry so the max=1 invariant + Claude session ID tracking
    /// continue to work.
    ///
    /// Difference from `create(kind:cwd:rows:cols:)`:
    /// - `create`: external = our `PTYSpawner` owns the PTY, `ptyHandle` is set.
    /// - `createInternal`: internal = libghostty owns the PTY, `ptyHandle` is nil.
    public func createInternal(
        kind: SessionKind,
        cwd: String
    ) async throws -> Session {
        if sessions.count >= maxSessions {
            throw ManagerError.maxSessionsReached(currentMax: maxSessions)
        }
        let session = Session(
            kind: kind,
            origin: .internal,
            ptyHandle: nil,
            cwd: cwd
        )
        sessions[session.id] = session
        ensureActivityScope()
        return session
    }

    /// Acquire an `ActivityScope` if none is currently held. Called from both
    /// `create` paths so the App Nap protection wakes up alongside the first
    /// session and releases when `terminate` drops the last running session.
    private func ensureActivityScope() {
        if activityScope == nil {
            activityScope = ActivityScope(reason: "PTY session active")
        }
    }

    /// Drop the scope once every tracked session has exited.
    private func releaseActivityScopeIfIdle() {
        if sessions.values.allSatisfy({ $0.status == .exited }) {
            activityScope = nil
        }
    }

    /// Tears down a session: SIGTERM, 1-second grace, SIGKILL, then close the
    /// master fd and mark `status = .exited`. The session record stays in
    /// `sessions` so callers can inspect post-mortem state — they can drop it
    /// by calling `remove(id:)` if they want.
    ///
    /// For `origin == .internal` sessions there is no externally-owned PTY to
    /// kill; libghostty manages the child process via `ghostty_surface_free`
    /// invoked by the GUI layer. We only flip the status here.
    public func terminate(id: UUID) async throws {
        guard let existing = sessions[id] else {
            throw ManagerError.notFound(id: id)
        }

        if let handle = existing.ptyHandle {
            let pid = handle.childPID
            // Best-effort SIGTERM then SIGKILL after a 1s grace.
            if existing.status == .running {
                _ = kill(pid, SIGTERM)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                var status: Int32 = 0
                let reaped = waitpid(pid, &status, WNOHANG)
                if reaped == 0 {
                    _ = kill(pid, SIGKILL)
                    _ = waitpid(pid, &status, 0)
                }
            }
            // Close the master fd. Safe to invoke multiple times.
            _ = handle.closeMaster()
        }

        if let claudeId = existing.claudeSessionId {
            lastClaudeSessionId = claudeId
        }
        sessions[id] = existing.with(status: .exited)
        releaseActivityScopeIfIdle()
    }

    /// Drops a session record entirely (after `terminate`, typically).
    public func remove(id: UUID) async {
        sessions.removeValue(forKey: id)
    }

    public func get(id: UUID) async -> Session? {
        return sessions[id]
    }

    /// Records the Claude session UUID extracted from the PTY stream. Idempotent
    /// — only the first call has any effect.
    public func updateClaudeSessionId(id: UUID, claudeId: String) {
        guard let existing = sessions[id], existing.claudeSessionId == nil else {
            return
        }
        sessions[id] = existing.with(claudeSessionId: .some(claudeId))
    }

    /// Number of live sessions (running or exited but not yet `remove`d).
    public func count() async -> Int {
        return sessions.count
    }
}
