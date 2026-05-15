import SwiftUI
import AppKit
import os

extension Logger {
    static let r2 = Logger(subsystem: "com.choms0521.ClaudeAlarmTerminal", category: "R2-DIAG")
}

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
        let pid = pane.id
        let wid = workspace.id
        return registry.acquire(paneId: pid) {
            let command = Self.buildCommand(workspace: workspace, pane: pane)
            Logger.r2.info("[R2-DIAG] PaneTerminalView.factory wsId=\(wid.uuidString.prefix(8), privacy: .public) paneId=\(pid.uuidString.prefix(8), privacy: .public) kind=\(String(describing: pane.kind), privacy: .public)")
            return GhosttyTerminalView(
                app: ghosttyApp,
                paneId: pid,
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
    ///
    /// R2 fix: claude pane 도 login+interactive shell 을 거쳐 spawn 한다.
    /// 이유 — 장군님 환경의 `node` 가 fnm 으로 관리되어 shell init 시점에만
    /// PATH 가 set 됨. claude 의 hook (SessionStart/PreToolUse/PostToolUse 등)
    /// 이 `node ./hook.mjs` 를 spawn 할 때 PATH 에 node 가 없으면
    /// "node: command not found" 가 매 prompt 마다 발생하여 hook stderr
    /// 가 TUI 화면을 침범 + cursor positioning 충돌 → 화면 corruption.
    /// `zsh -lic 'exec claude'` 가 .zprofile + .zshrc 를 모두 source 해
    /// fnm/nvm/asdf 류 모든 shell-managed 런타임을 정상 init 한 뒤 claude
    /// 가 zsh 를 대체한다.
    static func buildCommand(workspace: Workspace, pane: Pane) -> String {
        switch pane.kind {
        case .claude:
            let claudePath = (try? resolveClaudeBinary()) ?? "claude"
            let shell = workspace.envSnapshot["SHELL"] ?? "/bin/zsh"
            return "\(shell) -lic 'exec \(shellQuote(claudePath))'"
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
