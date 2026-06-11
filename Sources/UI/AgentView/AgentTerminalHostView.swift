import SwiftUI
import AppKit

/// agent-view 우측 라이브 터미널 호스트(P5.5 Day 2).
///
/// 선택된 tabId 의 기존 surface 를 `SurfaceRegistry.acquireExisting(id:)` 으로 가져와
/// mount 하는 NSViewRepresentable. 워크스페이스 탭과 같은 NSView(=같은 PTY/scrollback)
/// 를 공유한다 — agent-view 의 존재 이유.
///
/// ## 재부모화 규율 (ADR-I: 1 surface = 1 NSView)
///
/// `acquireExisting` 이 반환한 NSView 가 워크스페이스 탭 컨테이너에 이미 mount 돼
/// 있다면, SwiftUI 가 이를 본 호스트 컨테이너에 넣을 때 AppKit `addSubview` 가
/// 이전 superview 에서 자동 제거(재부모화)한다. 따라서 같은 surface 가 동시에 두
/// 곳에 보이지 않으며, 워크스페이스 탭으로 복귀하면 그쪽에서 다시 acquire 되어
/// 재부모화로 돌아간다(`SurfaceRegistryInvariantTests.test_reparent_*` 로 메커니즘
/// 실증, GUI walkthrough 로 라이브 scrollback 보존 확인).
///
/// ## CRITICAL: 같은 tabId 에 두 번째 surface 를 생성하지 않는다
///
/// `acquireExisting` 이 nil 일 때(한 번도 열리지 않은 lazy 탭)만 `acquire` factory 로
/// 1회 신규 spawn 한다. factory 내부의 단일 생성 외에 다른 직접 생성 경로가 없어야
/// ADR-I 불변식이 봉쇄된다(Day 2 grep 종료 조건으로 1건만 검증).
///
/// ## 타겟 제외 (P5.5 결정 항목)
///
/// 본 파일은 `GhosttyTerminalView`(GhosttyKit) 의존이므로 `project.yml` 에서
/// SessionTests/WorkspaceTests/DaemonTests/SessionVerifier/DaemonDevCLI 5개 타겟의
/// `Sources/UI` excludes 에 추가됐다(`GhosttyViewportProvider.swift` 와 동일 처리).
/// 앱 타겟에서만 컴파일되고 단위 테스트 대상이 아니다.
struct AgentTerminalHostView: NSViewRepresentable {
    let workspace: Workspace
    let pane: Pane
    let tab: Tab
    let ghosttyApp: GhosttyApp
    let registry: SurfaceRegistry

    @MainActor
    func makeNSView(context: Context) -> NSView {
        // (1) 기존 surface 가 있으면 재부모화 — 같은 PTY/scrollback 공유.
        //     이 NSView 가 워크스페이스 탭에 mount 돼 있었다면 본 컨테이너로 들어올 때
        //     AppKit addSubview 가 그쪽 superview 에서 자동 제거한다(재부모화 규율).
        if let existing = registry.acquireExisting(id: tab.id) {
            return existing
        }
        // (2) lazy 미생성 탭 — 신규 spawn. 같은 tabId 로 등록되므로 이후 워크스페이스
        //     탭과 공유된다. TerminalCommandBuilder 재사용(Day 0 공용 추출).
        return registry.acquire(id: tab.id) {
            let command = TerminalCommandBuilder.build(
                workspace: workspace, pane: pane, tab: tab
            )
            return GhosttyTerminalView(
                app: ghosttyApp,
                tabId: tab.id,
                command: command,
                cwd: workspace.cwd,
                frame: .zero
            )
        }
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // no-op. 우측 host frame 변경에 따른 SIGWINCH 리사이즈는
        // GhosttyTerminalView.setFrameSize/layout() 가 자체 처리(같은 PTY).
        // selectedTabId 변경 시 교체는 AgentSplitView 의 .id(tab.id) 가 트리거(Day 3).
    }
}
