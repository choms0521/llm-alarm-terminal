import SwiftUI
import AppKit

/// libghostty surface 를 하나 호스팅하는 NSViewRepresentable.
///
/// 각 pane 인스턴스는 독립 `GhosttyTerminalView` (즉, 독립 `ghostty_surface_t`) 를 보유한다
/// — ADR-I cmux 패턴(동시 다중 surface alive). pane 종료 시 SurfaceRegistry 가
/// release 하여 NSView 의 deinit → `ghostty_surface_free` 가 child PTY 까지 정리.
///
/// Day 7: `SurfaceRegistry` 가 view 의 owner 이므로 workspace 전환 등으로 SwiftUI 트리가
/// 재구성되어도 surface 가 destroy 되지 않는다. makeNSView 는 registry 에서 기존 인스턴스
/// 를 acquire 하거나 새로 생성.
///
/// 환경 변수 격리(`HISTFILE`)는 `/usr/bin/env` prefix 로 command line 에 직접
/// 주입한다. libghostty 가 명령을 spawn 할 때 prefix env 가 적용된다(POSIX `env(1)` 동작).
///
/// P3.5 REQ-3: claude pane 의 config 디렉터리 격리는 폐지됐다. 사용자 기본
/// `~/.claude` 를 공유하므로 prefix env 없이 claude 바이너리를 직접 실행한다.
struct PaneTerminalView: NSViewRepresentable {
    let workspace: Workspace
    let pane: Pane
    let ghosttyApp: GhosttyApp
    let registry: SurfaceRegistry

    init(workspace: Workspace, pane: Pane, ghosttyApp: GhosttyApp, registry: SurfaceRegistry) {
        self.workspace = workspace
        self.pane = pane
        self.ghosttyApp = ghosttyApp
        self.registry = registry
    }

    func makeNSView(context: Context) -> NSView {
        registry.acquire(paneId: pane.id) {
            let command = Self.buildCommand(workspace: workspace, pane: pane)
            return GhosttyTerminalView(
                app: ghosttyApp,
                command: command,
                cwd: workspace.cwd,
                frame: .zero
            )
        }
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Day 7 범위: command 는 acquire 시점에 결정. update 는 no-op.
        // 향후 size / focus 변경은 GhosttyTerminalView 의 자체 layout 콜백이 처리.
    }

    /// kind 별 env 격리 prefix + 실제 실행 binary 를 합성한 command 문자열.
    /// 형태: `/usr/bin/env KEY=VAL /bin/zsh -l` (POSIX env(1) 호환).
    static func buildCommand(workspace: Workspace, pane: Pane) -> String {
        switch pane.kind {
        case .claude:
            // P3.5 REQ-3: 사용자 ~/.claude 공유. env prefix 없이 직접 실행.
            return (try? resolveClaudeBinary()) ?? "claude"
        case .shell:
            let dir = (try? SessionSpawnEnv.zshHistoryDir(workspaceId: workspace.id, paneId: pane.id)) ?? ""
            let histFile = dir + "/history"
            let shell = workspace.envSnapshot["SHELL"] ?? "/bin/zsh"
            return "/usr/bin/env HISTFILE=\(shellQuote(histFile)) \(shell) -l"
        }
    }

    /// 공백 / 특수문자 가 포함된 path 는 shell-quote (단일 인용부호).
    private static func shellQuote(_ path: String) -> String {
        guard path.contains(where: { $0 == " " || $0 == "\t" || $0 == "'" }) else { return path }
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}
