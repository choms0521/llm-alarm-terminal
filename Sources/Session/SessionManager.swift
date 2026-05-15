import Darwin
import Foundation

/// SessionManager 가 발생시키는 에러. 메시지는 한국어 user-visible copy 이며
/// 호출부의 에러 다이얼로그/로그에 surface 된다.
public enum ManagerError: Error, CustomStringConvertible, Equatable {
    case maxSessionsReached(currentMax: Int)
    case notFound(id: UUID)
    case spawnFailed(underlying: String)

    public var description: String {
        switch self {
        case .maxSessionsReached(let currentMax):
            // P2 Day 8 spec: master § 4.2 MAX_SESSIONS_REACHED 에러 메시지.
            return "최대 세션 개수에 도달했습니다 (N=\(currentMax)). 기존 세션을 종료하세요."
        case .notFound(let id):
            return "세션을 찾을 수 없습니다 (id=\(id.uuidString))."
        case .spawnFailed(let underlying):
            return "세션을 시작하지 못했습니다: \(underlying)"
        }
    }
}

/// Process-wide session registry. Single-actor 로 모든 mutation 을 executor 에 직렬화.
///
/// P2 변경 사항:
/// - `maxSessions` clamp 제거. `CHAT_TERMINAL_MAX_SESSIONS` env (default 20) 활용.
/// - `lastClaudeSessionId` 를 `[UUID: String]` 로 확장 (max=N 시 per-session 추적).
/// - `terminateAll(inWorkspace:)` 추가 — 3-Step 패턴으로 actor reentrancy 회피 (N2).
/// - `create(workspace:paneId:kind:rows:cols:)` 추가 — workspace.envSnapshot base + kind 별 override.
/// - `SessionLifecycleHooks` Combine publisher 연동 (onSessionCreated/onSessionTerminated).
/// - P1 의 actor isolation invariant 그대로 유지(모든 mutating public 메서드 `async`).
public actor SessionManager {
    public private(set) var sessions: [UUID: Session] = [:]

    /// H3: P1 max=1 시 단일 Optional 이었던 `lastClaudeSessionId` 가
    /// P2 max=N 으로 풀리면서 sessionId(=Session.id) keyed dict 로 자연 확장.
    public private(set) var lastClaudeSessionId: [UUID: String] = [:]

    /// Held while at least one session exists. Released 는 모든 session 이 .exited 인 시점에만.
    private var activityScope: ActivityScope?

    /// `CHAT_TERMINAL_MAX_SESSIONS` 가 정한 최대 동시 세션 수 (default 20).
    private let maxSessions: Int

    /// Combine publisher 모음. 외부 콜러는 init 주입한 인스턴스를 직접 보유하여
    /// `await` 없이 sink 한다(actor entry 점이 아님). Actor 내부에서는 `hooks.onXxx.send(...)` 호출.
    public let hooks: SessionLifecycleHooks

    public init(
        maxSessionsOverride: Int? = nil,
        hooks: SessionLifecycleHooks = SessionLifecycleHooks()
    ) {
        if let override = maxSessionsOverride {
            self.maxSessions = max(1, override)
        } else if let envStr = ProcessInfo.processInfo.environment["CHAT_TERMINAL_MAX_SESSIONS"],
                  let envInt = Int(envStr), envInt > 0 {
            self.maxSessions = envInt
        } else {
            self.maxSessions = 20
        }
        self.hooks = hooks
    }

    /// 현재 maxSessions 값 (테스트/디버깅용).
    public func currentMaxSessions() -> Int { maxSessions }

    // MARK: - Create (P2 path: workspace-aware)

    /// P2: workspace.envSnapshot 을 base 로 한 PTY spawn.
    /// kind 별 override(shell: HISTFILE) 적용 후 PTYSpawner 위임.
    /// P3.5 REQ-3: claude pane 의 CLAUDE_CONFIG_DIR 격리 override 는 폐지됐다.
    public func create(
        workspace: Workspace,
        paneId: UUID,
        kind: PaneKind,
        rows: UInt16,
        cols: UInt16
    ) async throws -> Session {
        guard sessions.count < maxSessions else {
            throw ManagerError.maxSessionsReached(currentMax: maxSessions)
        }

        let sessionId = UUID()
        let env: [String: String]
        do {
            env = try SessionSpawnEnv.buildSpawnEnv(
                workspace: workspace,
                paneId: paneId,
                sessionId: sessionId,
                kind: kind
            )
        } catch {
            throw ManagerError.spawnFailed(underlying: String(describing: error))
        }

        let command: String
        let args: [String]
        switch kind {
        case .claude:
            command = try resolveClaudeBinary()
            args = []
        case .shell:
            command = env["SHELL"] ?? "/bin/zsh"
            args = ["-l"]
        }

        // P2: 새 pane 의 cwd 는 항상 workspace.cwd (직전 pane 상속 금지).
        let cwd = workspace.cwd

        let handle: PTYHandle
        do {
            handle = try PTYSpawner.spawn(
                command: command,
                args: args,
                cwd: cwd,
                env: env,
                rows: rows,
                cols: cols
            )
        } catch {
            throw ManagerError.spawnFailed(underlying: String(describing: error))
        }

        let session = Session(
            id: sessionId,
            kind: SessionSpawnEnv.sessionKind(from: kind),
            origin: .external,
            ptyHandle: handle,
            cwd: cwd,
            workspaceId: workspace.id,
            paneId: paneId,
            env: env
        )
        sessions[session.id] = session
        ensureActivityScope()
        hooks.onSessionCreated.send(session)
        return session
    }

    // MARK: - Create (P1 legacy path: kept for SessionVerifier compatibility)

    /// P1 호환 경로. workspace 컨텍스트 없는 직접 spawn (verifier 도구 전용).
    /// 새 코드는 `create(workspace:paneId:kind:rows:cols:)` 를 사용한다.
    public func create(
        kind: SessionKind,
        cwd: String,
        rows: UInt16,
        cols: UInt16
    ) async throws -> Session {
        guard sessions.count < maxSessions else {
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
        hooks.onSessionCreated.send(session)
        return session
    }

    /// libghostty 내부 소유 PTY 의 등록 (GUI path). ptyHandle 은 nil.
    public func createInternal(
        kind: SessionKind,
        cwd: String
    ) async throws -> Session {
        guard sessions.count < maxSessions else {
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
        hooks.onSessionCreated.send(session)
        return session
    }

    /// P2 lifecycle wiring 용 createInternal — workspace + pane 컨텍스트 부착.
    /// libghostty 가 PTY 를 소유하므로 ptyHandle = nil. `terminateAll(inWorkspace:)`
    /// 는 internal 세션을 skip 하지만, sessions 레지스트리에는 등록되어 카운트 / hook 발행 / claudeSessionId 보존이 정상 동작한다.
    public func createInternal(
        workspace: Workspace,
        paneId: UUID,
        kind: PaneKind
    ) async throws -> Session {
        guard sessions.count < maxSessions else {
            throw ManagerError.maxSessionsReached(currentMax: maxSessions)
        }
        let session = Session(
            kind: SessionSpawnEnv.sessionKind(from: kind),
            origin: .internal,
            ptyHandle: nil,
            cwd: workspace.cwd,
            workspaceId: workspace.id,
            paneId: paneId,
            env: workspace.envSnapshot
        )
        sessions[session.id] = session
        ensureActivityScope()
        hooks.onSessionCreated.send(session)
        return session
    }

    /// 주어진 workspace 에 속한 모든 session id 목록 (lifecycle 정리에 사용).
    public func sessionIds(inWorkspace workspaceId: UUID) -> [UUID] {
        sessions.compactMap { $0.value.workspaceId == workspaceId ? $0.key : nil }
    }

    // MARK: - Terminate

    /// 단일 세션 종료: SIGTERM → 1s grace → (필요 시) SIGKILL → polling WNOHANG → close master fd → status=.exited.
    /// `origin == .internal` 인 경우 libghostty 가 PTY 를 소유하므로 status 만 갱신.
    public func terminate(id: UUID) async throws {
        guard let existing = sessions[id] else {
            throw ManagerError.notFound(id: id)
        }

        if let handle = existing.ptyHandle {
            let pid = handle.childPID
            if existing.status == .running {
                _ = kill(pid, SIGTERM)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                var status: Int32 = 0
                let reaped = waitpid(pid, &status, WNOHANG)
                if reaped == 0 {
                    _ = kill(pid, SIGKILL)
                    // polling WNOHANG: 호스트 환경(SIGCHLD reaper 등)에서 blocking waitpid 가
                    // 행에 빠지는 사례 회피. 최대 500ms 까지 10ms 간격 폴링.
                    for _ in 0..<50 {
                        let r = waitpid(pid, &status, WNOHANG)
                        if r != 0 { break }
                        try? await Task.sleep(nanoseconds: 10_000_000)
                    }
                }
            }
            _ = handle.closeMaster()
        }

        if let claudeId = existing.claudeSessionId {
            lastClaudeSessionId[id] = claudeId
        }
        sessions[id] = existing.with(status: .exited)
        releaseActivityScopeIfIdle()
        hooks.onSessionTerminated.send(id)
    }

    /// M1 + N2: workspace 의 모든 세션을 병렬로 종료. 1초 SIGTERM grace ×N 의 직렬 누적을 회피.
    ///
    /// 3-Step 패턴:
    /// 1) in-actor: kill 대상 자원(masterFD, childPID, claudeSessionId) 추출.
    /// 2) out-of-actor: child task 가 actor 재진입 없이 kill / waitpid / close 만 수행.
    ///                  모든 child 완료 await — reentrancy 발현 0건.
    /// 3) in-actor: 단일 pass 로 상태 갱신 + activityScope 체크 + hooks 발행.
    public func terminateAll(inWorkspace workspaceId: UUID) async {
        // Step 1
        let targets: [(UUID, Int32, pid_t, String?, SessionOrigin)] = sessions
            .filter { $0.value.workspaceId == workspaceId }
            .map { ($0.key,
                    $0.value.ptyHandle?.masterFD ?? -1,
                    $0.value.ptyHandle?.childPID ?? -1,
                    $0.value.claudeSessionId,
                    $0.value.origin) }

        // Step 2
        await withTaskGroup(of: UUID.self) { group in
            for (id, masterFD, childPID, _, origin) in targets where origin == .external {
                group.addTask {
                    _ = kill(childPID, SIGTERM)
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    var status: Int32 = 0
                    let reaped = waitpid(childPID, &status, WNOHANG)
                    if reaped == 0 {
                        _ = kill(childPID, SIGKILL)
                        for _ in 0..<50 {
                            let r = waitpid(childPID, &status, WNOHANG)
                            if r != 0 { break }
                            try? await Task.sleep(nanoseconds: 10_000_000)
                        }
                    }
                    Darwin.close(masterFD)
                    return id
                }
            }
            for await _ in group {}
        }

        // Step 3 — invariant: activityScope == nil iff sessions.allSatisfy { .exited }
        for (id, _, _, claudeId, _) in targets {
            if let claudeId = claudeId {
                lastClaudeSessionId[id] = claudeId
            }
            if let s = sessions[id] {
                sessions[id] = s.with(status: .exited)
            }
            hooks.onSessionTerminated.send(id)
        }
        releaseActivityScopeIfIdle()
    }

    public func remove(id: UUID) async {
        sessions.removeValue(forKey: id)
    }

    public func get(id: UUID) async -> Session? {
        sessions[id]
    }

    /// Claude session UUID 를 PTY 스트림에서 추출 후 갱신. Idempotent.
    public func updateClaudeSessionId(id: UUID, claudeId: String) {
        guard let existing = sessions[id], existing.claudeSessionId == nil else {
            return
        }
        sessions[id] = existing.with(claudeSessionId: .some(claudeId))
    }

    /// Live (running + exited 미 remove) 세션 개수.
    public func count() async -> Int {
        sessions.count
    }

    /// 테스트용: activityScope 활성 상태 noisolated 관찰을 위한 async getter.
    public func activityScopeIsActive() -> Bool {
        activityScope != nil
    }

    // MARK: - Private

    private func ensureActivityScope() {
        if activityScope == nil {
            activityScope = ActivityScope(reason: "PTY session active")
        }
    }

    private func releaseActivityScopeIfIdle() {
        if sessions.values.allSatisfy({ $0.status == .exited }) {
            activityScope = nil
        }
    }
}
