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
/// P2 추가 필드(`workspaceId`, `paneId`, `env`)는 모두 옵셔널/기본값을 가져
/// P1 레거시 콜러(SessionVerifier 등)의 init 호출을 깨지 않는다.
public struct Session: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let kind: SessionKind
    public let origin: SessionOrigin
    public let ptyHandle: PTYHandle?
    public let cwd: String
    public let createdAt: Date
    public let status: SessionStatus
    public let claudeSessionId: String?

    /// P2: 소속 Workspace 의 id. P1 레거시 경로(workspace 컨텍스트 없음)는 nil.
    public let workspaceId: UUID?
    /// P2: 소속 Pane 의 id. P1 레거시 경로는 nil.
    public let paneId: UUID?
    /// P2: spawn 시 PTY child 에 전달된 env dict (디버깅/검증 용도). 비전파 invariant 확인 anchor.
    public let env: [String: String]

    public init(
        id: UUID = UUID(),
        kind: SessionKind,
        origin: SessionOrigin = .external,
        ptyHandle: PTYHandle?,
        cwd: String,
        createdAt: Date = Date(),
        status: SessionStatus = .running,
        claudeSessionId: String? = nil,
        workspaceId: UUID? = nil,
        paneId: UUID? = nil,
        env: [String: String] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.origin = origin
        self.ptyHandle = ptyHandle
        self.cwd = cwd
        self.createdAt = createdAt
        self.status = status
        self.claudeSessionId = claudeSessionId
        self.workspaceId = workspaceId
        self.paneId = paneId
        self.env = env
    }

    /// 선택 필드만 override 하여 새 인스턴스 반환.
    /// 각 인자 default `nil` — 호출부는 변경하려는 필드만 지정.
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
            claudeSessionId: claudeSessionId ?? self.claudeSessionId,
            workspaceId: workspaceId,
            paneId: paneId,
            env: env
        )
    }
}
