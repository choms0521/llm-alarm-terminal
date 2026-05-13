import Foundation

/// The kind of process running inside a session's PTY.
public enum SessionKind: String, Sendable, Equatable {
    case claude
    case shell
}

/// Lifecycle state of a session.
public enum SessionStatus: String, Sendable, Equatable {
    case running
    case exited
}

/// Origin of the PTY backing a session.
///
/// Day 5b discovery: libghostty owns the PTY for surfaces created with
/// `ghostty_surface_config_s.command` set. We track this distinction so the
/// SessionManager terminate path can do the right thing for each kind.
public enum SessionOrigin: String, Sendable, Equatable {
    /// PTY spawned by `PTYSpawner` (Day 4 path). `ptyHandle` is non-nil.
    /// Used by headless verifiers + future tests.
    case external
    /// PTY owned internally by libghostty (Day 5b GUI path). `ptyHandle` is
    /// nil because there is no externally-visible master fd to drive.
    case `internal`
}

/// Immutable per-session record. Mutations are expressed by constructing a
/// new `Session` via `with(...)` so that `SessionManager` only needs to swap
/// values in its dictionary — no in-place mutation of the model itself.
///
/// `PTYHandle` is a value type (`Equatable` struct of fd + pid + slave path),
/// so this struct can stay `Sendable` even though it transitively carries the
/// master fd integer.
///
/// `ptyHandle` is optional starting Day 5b: when `origin == .internal` the
/// libghostty surface owns the PTY and there is no external handle.
public struct Session: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let kind: SessionKind
    public let origin: SessionOrigin
    public let ptyHandle: PTYHandle?
    public let cwd: String
    public let createdAt: Date
    public let status: SessionStatus
    public let claudeSessionId: String?

    public init(
        id: UUID = UUID(),
        kind: SessionKind,
        origin: SessionOrigin = .external,
        ptyHandle: PTYHandle?,
        cwd: String,
        createdAt: Date = Date(),
        status: SessionStatus = .running,
        claudeSessionId: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.origin = origin
        self.ptyHandle = ptyHandle
        self.cwd = cwd
        self.createdAt = createdAt
        self.status = status
        self.claudeSessionId = claudeSessionId
    }

    /// Returns a copy with selected fields overridden. Each argument defaults
    /// to `nil` so callers only specify what they want to change. The Swift
    /// type system lets us keep this immutable-friendly without the per-call
    /// boilerplate of a builder.
    public func with(
        status: SessionStatus? = nil,
        claudeSessionId: String?? = nil
    ) -> Session {
        return Session(
            id: id,
            kind: kind,
            origin: origin,
            ptyHandle: ptyHandle,
            cwd: cwd,
            createdAt: createdAt,
            status: status ?? self.status,
            claudeSessionId: claudeSessionId ?? self.claudeSessionId
        )
    }
}
