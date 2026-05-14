import SwiftUI
import AppKit

/// libghostty surface 를 하나 호스팅하는 NSViewRepresentable.
///
/// 각 pane 인스턴스는 독립 `GhosttyTerminalView` (즉, 독립 `ghostty_surface_t`) 를 보유한다
/// — ADR-I cmux 패턴(동시 다중 surface alive). pane 종료 시 `deinit` 가
/// `ghostty_surface_free` 를 호출하여 child PTY 까지 정리.
///
/// 환경 변수 격리(`HISTFILE`, `CLAUDE_CONFIG_DIR`)는 `/usr/bin/env` prefix 로
/// command line 에 직접 주입한다. libghostty 가 명령을 spawn 할 때 prefix env 가
/// 적용된다(POSIX `env(1)` 동작).
struct PaneTerminalView: NSViewRepresentable {
    let workspace: Workspace
    let pane: Pane
    let ghosttyApp: GhosttyApp

    init(workspace: Workspace, pane: Pane, ghosttyApp: GhosttyApp) {
        self.workspace = workspace
        self.pane = pane
        self.ghosttyApp = ghosttyApp
    }

    func makeNSView(context: Context) -> GhosttyTerminalView {
        let command = Self.buildCommand(workspace: workspace, pane: pane)
        return GhosttyTerminalView(
            app: ghosttyApp,
            command: command,
            cwd: workspace.cwd,
            frame: .zero
        )
    }

    func updateNSView(_ nsView: GhosttyTerminalView, context: Context) {
        // Day 4 범위: command 는 makeNSView 시점에 결정. update 는 no-op.
    }

    /// kind 별 env 격리 prefix + 실제 실행 binary 를 합성한 command 문자열.
    /// 형태: `/usr/bin/env KEY=VAL /bin/zsh -l` (POSIX env(1) 호환).
    static func buildCommand(workspace: Workspace, pane: Pane) -> String {
        switch pane.kind {
        case .claude:
            let configDir = (try? SessionSpawnEnv.claudeConfigDir(forSession: pane.id)) ?? ""
            let claude = (try? resolveClaudeBinary()) ?? "claude"
            return "/usr/bin/env CLAUDE_CONFIG_DIR=\(shellQuote(configDir)) \(claude)"
        case .shell:
            let dir = (try? SessionSpawnEnv.zshHistoryDir(workspaceId: workspace.id, paneId: pane.id)) ?? ""
            let histFile = dir + "/history"
            let shell = workspace.envSnapshot["SHELL"] ?? "/bin/zsh"
            return "/usr/bin/env HISTFILE=\(shellQuote(histFile)) \(shell) -l"
        }
    }

    /// 공백 / 특수문자 가 포함된 path 는 shell-quote (단일 인용부호).
    /// libghostty 의 command parser 가 단순 split 방식이라 가정 — 공백 보호.
    private static func shellQuote(_ path: String) -> String {
        guard path.contains(where: { $0 == " " || $0 == "\t" || $0 == "'" }) else { return path }
        // 안에 있는 ' 는 '\'' 로 이스케이프.
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}
