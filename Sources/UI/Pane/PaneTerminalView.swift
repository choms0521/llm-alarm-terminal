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
        // P3.5 Day 1.5: SurfaceRegistry key 가 tabId 로 전환. active tab id 를 anchor 로
        // 사용. 2-tier 해소는 WorkspaceManager.activeTab 정착 패턴과 동일.
        guard let tid = pane.activeTabId ?? pane.tabs.first?.id else {
            Logger.r2.error("[R2-DIAG] PaneTerminalView.makeNSView: pane=\(pid.uuidString.prefix(8), privacy: .public) has no tabs — invariant violation")
            return NSView(frame: .zero)
        }
        return registry.acquire(id: tid) {
            let command = Self.buildCommand(workspace: workspace, pane: pane)
            let kindDesc = pane.activeTab.map { String(describing: $0.kind) } ?? "no-active-tab"
            Logger.r2.info("[R2-DIAG] PaneTerminalView.factory wsId=\(wid.uuidString.prefix(8), privacy: .public) paneId=\(pid.uuidString.prefix(8), privacy: .public) tabId=\(tid.uuidString.prefix(8), privacy: .public) kind=\(kindDesc, privacy: .public)")
            return GhosttyTerminalView(
                app: ghosttyApp,
                tabId: tid,
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
    ///
    /// P5.5 Day 0: 합성 로직은 `TerminalCommandBuilder`(Sources/Session/)로 공용
    /// 추출됐다. agent-view 우측 호스트가 lazy 미생성 탭을 클릭 시 동일 로직으로
    /// 신규 spawn 하기 위함이다. 여기서는 시그니처를 보존한 위임 스텁으로만 남는다.
    ///
    /// fallback 보존: 기존 동작은 `pane.activeTab?.kind ?? .shell` 로 active tab
    /// 이 없는 비정상 상태에서 shell command 를 산출했다. 빌더는 tab 을 직접 받으므로
    /// activeTab 부재 시 합성 shell tab 을 만들어 동일 .shell 경로를 타게 한다.
    static func buildCommand(workspace: Workspace, pane: Pane) -> String {
        // active tab 이 없으면 합성 shell tab 으로 fallback (UI 가 빈 화면으로 죽지 않도록).
        let tab = pane.activeTab ?? Tab(kind: .shell, name: Tab.defaultName(for: .shell))
        return TerminalCommandBuilder.build(workspace: workspace, pane: pane, tab: tab)
    }
}
