import Foundation

/// PTY spawn 시 사용되는 env / cwd / 격리 디렉터리 helper.
///
/// 운영 중인 sub-invariant:
/// 1. env snapshot: workspace 생성 시점에 `captureUserEnv()` 로 한 번 캡처 →
///    `Workspace.envSnapshot` 에 저장. 같은 workspace 의 모든 pane spawn 에 base 로 사용.
/// 2. cd/export 비전파: POSIX 격리에 의해 자연 보장 (PTY child 의 변경은 parent / 다른 pane 에 영향 없음).
/// 3. 새 pane cwd: 항상 `workspace.cwd` (직전 pane cwd 상속 금지).
/// 4. HISTFILE 격리: shell pane 마다 독립 디렉터리.
///
/// P3.5 REQ-3 (격리 폐지): 이전 P2 invariant 4("claude 세션마다 독립 config 디렉터리") 는
/// 폐지되었다. claude pane 은 사용자 기본 config (`~/.claude`) 를 공유하여 매번 재로그인
/// 문제를 해소한다. `claudeConfigDir(forSession:)` / `cleanupStaleClaudeConfigDirs(...)`
/// 두 helper 는 deprecated 마커로 보존 (호출 site 부재) — 향후 사용자 opt-in 격리 모드 도입 시 복원 후보.
public enum SessionSpawnEnv {

    /// H6: workspace 생성 시점에 capture 하는 user env snapshot.
    public static func captureUserEnv() -> [String: String] {
        ProcessInfo.processInfo.environment
    }

    /// (deprecated, P3.5 REQ-3) 세션별 격리 config 디렉터리 path 반환.
    /// 호출 site 부재 — 사용자 opt-in 격리 모드 도입 시 복원 후보로 보존.
    @available(*, deprecated, message: "P3.5 REQ-3: 격리 폐지. 사용자 ~/.claude 공유.")
    public static func claudeConfigDir(forSession id: UUID) throws -> String {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true)
        let dir = appSupport
            .appendingPathComponent("ClaudeAlarmTerminal", isDirectory: true)
            .appendingPathComponent("claude-config", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    /// pane 별 zsh `HISTFILE` 격리 디렉터리.
    /// 두 셸 pane 의 명령 기록이 섞이지 않도록 workspaceId + paneId 로 path 분기.
    public static func zshHistoryDir(workspaceId: UUID, paneId: UUID) throws -> String {
        let caches = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true)
        let dir = caches
            .appendingPathComponent("ClaudeAlarmTerminal", isDirectory: true)
            .appendingPathComponent("zsh_history", isDirectory: true)
            .appendingPathComponent(workspaceId.uuidString, isDirectory: true)
            .appendingPathComponent(paneId.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    /// (deprecated, P3.5 REQ-3) 부팅 직후 stale 격리 config 디렉터리 청소.
    /// 호출 site 부재. 1회용 마이그레이션은 `scripts/cleanup-legacy-claude-config-dirs.sh` 가 담당.
    @available(*, deprecated, message: "P3.5 REQ-3: 격리 폐지. cleanup 은 1회용 스크립트로 일임.")
    public static func cleanupStaleClaudeConfigDirs(liveSessionIds: Set<UUID>) throws {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false)
        let root = appSupport
            .appendingPathComponent("ClaudeAlarmTerminal/claude-config", isDirectory: true)
        try cleanupStaleConfigDirs(
            rootDir: root,
            liveSessionIds: liveSessionIds,
            olderThan: Date().addingTimeInterval(-7 * 86400)
        )
    }

    /// 테스트 가능한 generic 변종 — rootDir / threshold 주입 가능.
    /// rootDir 부재 시 silent return. 1회용 cleanup 스크립트 + deprecated wrapper 가 공통 사용.
    public static func cleanupStaleConfigDirs(
        rootDir: URL,
        liveSessionIds: Set<UUID>,
        olderThan: Date
    ) throws {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: rootDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for entry in entries {
            guard let id = UUID(uuidString: entry.lastPathComponent),
                  !liveSessionIds.contains(id),
                  let mtime = try? entry.resourceValues(forKeys: [.contentModificationDateKey])
                                          .contentModificationDate,
                  mtime < olderThan else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    /// workspace.envSnapshot 을 base 로 kind 별 override 를 적용한 spawn env dict 반환.
    ///
    /// shell  → `HISTFILE` 추가.
    /// claude → 추가 키 없음. 사용자 base env (`~/.claude` 공유) 그대로 사용.
    public static func buildSpawnEnv(
        workspace: Workspace,
        paneId: UUID,
        sessionId: UUID,
        kind: PaneKind
    ) throws -> [String: String] {
        var env = workspace.envSnapshot
        switch kind {
        case .claude:
            // P3.5 REQ-3: 격리 폐지. 사용자 base env (~/.claude 공유) 그대로 사용.
            break
        case .shell:
            let dir = try zshHistoryDir(workspaceId: workspace.id, paneId: paneId)
            env["HISTFILE"] = dir + "/history"
        }
        return env
    }

    /// PaneKind ↔ SessionKind 변환. P2 도입 두 enum 의 1:1 매핑.
    public static func sessionKind(from pane: PaneKind) -> SessionKind {
        switch pane {
        case .claude: return .claude
        case .shell:  return .shell
        }
    }
}
