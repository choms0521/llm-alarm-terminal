import Foundation

/// kind 별 env 격리 prefix + 실제 실행 binary 를 합성한 command 문자열 빌더.
///
/// SwiftUI 비의존 공용 타입. `Sources/Session/` 에 위치하여 SessionTests/
/// WorkspaceTests/DaemonTests/SessionVerifier/DaemonDevCLI 5개 타겟에 자동
/// 포함된다. 의존하는 `resolveClaudeBinary`(BinaryResolver.swift) / `SessionSpawnEnv`
/// 가 같은 디렉터리(동일 타겟)에 있어 의존이 그 안에서 해소된다.
///
/// `PaneTerminalView`(위임 스텁) 와 agent-view 우측 호스트(`AgentTerminalHostView`)
/// 가 공유한다. lazy 미생성 탭을 우측에서 클릭 시 동일 로직으로 신규 spawn 한다.
///
/// R2 fix 이유 보존: claude pane 도 login+interactive shell 을 거쳐 spawn 한다.
/// 장군님 환경의 `node` 가 fnm 으로 관리되어 shell init 시점에만 PATH 가 set
/// 되므로, claude 의 hook 이 `node ./hook.mjs` 를 spawn 할 때 PATH 에 node 가
/// 없으면 "node: command not found" 가 매 prompt 마다 발생하여 TUI 화면을
/// 침범한다. `zsh -lic 'exec claude'` 가 .zprofile + .zshrc 를 모두 source 해
/// fnm/nvm/asdf 류 런타임을 정상 init 한 뒤 claude 가 zsh 를 대체한다.
public enum TerminalCommandBuilder {
    /// 특정 tab 의 kind 로 실행 command 문자열을 합성한다.
    /// 형태: `/usr/bin/env KEY=VAL /bin/zsh -l` (POSIX env(1) 호환).
    ///
    /// 동작은 기존 `PaneTerminalView.buildCommand` 와 byte-identical 이어야 한다.
    /// tab 을 직접 받는 단일 시그니처. activeTab fallback 은 호출부(위임 스텁)가 담당.
    public static func build(workspace: Workspace, pane: Pane, tab: Tab) -> String {
        switch tab.kind {
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
    public static func shellQuote(_ path: String) -> String {
        guard path.contains(where: { $0 == " " || $0 == "\t" || $0 == "'" }) else { return path }
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}
