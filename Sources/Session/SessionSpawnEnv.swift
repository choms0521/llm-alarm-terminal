import Foundation

/// PTY spawn 시 사용되는 env / cwd / 격리 디렉터리 helper.
///
/// 다음 5개 sub-invariant 를 운영화한다(Day 6 통합 테스트로 검증):
/// 1. env snapshot: workspace 생성 시점에 `captureUserEnv()` 로 한 번 캡처 →
///    `Workspace.envSnapshot` 에 저장. 같은 workspace 의 모든 pane spawn 에 base 로 사용.
/// 2. cd/export 비전파: POSIX 격리에 의해 자연 보장 (PTY child 의 변경은 parent / 다른 pane 에 영향 없음).
/// 3. 새 pane cwd: 항상 `workspace.cwd` (직전 pane cwd 상속 금지).
/// 4. claude `CLAUDE_CONFIG_DIR` 격리: session 마다 독립 디렉터리.
/// 5. HISTFILE 격리: shell pane 마다 독립 디렉터리.
public enum SessionSpawnEnv {

    /// H6: workspace 생성 시점에 capture 하는 user env snapshot.
    public static func captureUserEnv() -> [String: String] {
        ProcessInfo.processInfo.environment
    }

    /// 세션마다 독립 `CLAUDE_CONFIG_DIR` 디렉터리를 생성하고 path 반환.
    /// 종료된 session 의 디렉터리는 P2 에서 보존(P4 reconnect 단계에서 활용 가능).
    /// 부팅 직후 stale 디렉터리 청소는 `cleanupStaleClaudeConfigDirs(liveSessionIds:)` 가 별도 수행.
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

    /// 부팅 직후 1회 실행. live SessionManager.sessions 에 없고 mtime 7일 이상인 dir 삭제.
    public static func cleanupStaleClaudeConfigDirs(liveSessionIds: Set<UUID>) throws {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false)
        let root = appSupport
            .appendingPathComponent("ClaudeAlarmTerminal/claude-config", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let sevenDaysAgo = Date().addingTimeInterval(-7 * 86400)
        for entry in entries {
            guard let id = UUID(uuidString: entry.lastPathComponent),
                  !liveSessionIds.contains(id),
                  let mtime = try? entry.resourceValues(forKeys: [.contentModificationDateKey])
                                          .contentModificationDate,
                  mtime < sevenDaysAgo else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    /// workspace.envSnapshot 을 base 로 kind 별 override 를 적용한 spawn env dict 반환.
    ///
    /// claude → `CLAUDE_CONFIG_DIR` 추가.
    /// shell  → `HISTFILE` 추가.
    /// 둘 다 base env 위에 추가만 하며, 기존 키를 제거하지 않는다.
    public static func buildSpawnEnv(
        workspace: Workspace,
        paneId: UUID,
        sessionId: UUID,
        kind: PaneKind
    ) throws -> [String: String] {
        var env = workspace.envSnapshot
        switch kind {
        case .claude:
            env["CLAUDE_CONFIG_DIR"] = try claudeConfigDir(forSession: sessionId)
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
