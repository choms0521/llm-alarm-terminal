import SwiftUI

/// agent-view workspace 의 메인 컨텐츠(P5.5). 좌측 3단 트리(`AgentTreeView`) +
/// 우측 라이브 터미널 호스트(`AgentTerminalHostView`)를 `HSplitView` 로 조립한다.
///
/// 이전 카드 그리드 UI 를 대체한다. 트리는 `WorkspaceManager.workspaces` ×
/// `SessionStatusCoordinator.snapshots` 의 파생 view 일 뿐이며 신규 영속 모델은 없다.
///
/// ## navigation 분기 (P3.5 D3-6 R8)
///
/// - 사이드바 클릭(`manager.selectedID` 변경) → 해당 workspace 만 expand,
///   `selectedTabId` 무변경(`syncFromSidebar`).
/// - 트리 tab 클릭(`selection.selectedTabId` 변경) → 우측 호스트 교체.
///
/// ## dangling / graceful
///
/// - `manager.workspaces` 변경 시 선택 tab 이 더 이상 트리에 없으면(직접 탐색 실패)
///   `selectFirstAvailable` 로 유효 tab 또는 nil 로 수렴한다.
/// - 선택 tab 의 세션이 `.exited` 이고 surface 도 release 된 경우(`registry.contains`
///   false) 우측을 EmptyState 로 graceful 전환한다. 세션이 `.exited` 라도 surface 가
///   살아 있으면(closeTab 전) 마지막 화면을 그대로 표시한다 — normal 워크스페이스
///   탭이 종료된 세션을 보여주는 방식과 동일(같은 surface 공유의 일관성).
///
/// GhosttyKit 의존(`AgentTerminalHostView`)이므로 앱 타겟 전용이다.
struct AgentSplitView: View {
    @ObservedObject var manager: WorkspaceManager
    @ObservedObject var coordinator: SessionStatusCoordinator
    @ObservedObject var registry: SurfaceRegistry
    let ghosttyApp: GhosttyApp
    // 선택/펼침 상태는 호출측(AppDelegate)이 단일 인스턴스로 소유하여 주입한다.
    // @StateObject 로 뷰가 소유하면 agent-view 이탈(뷰 계층 제거) 시 상태가
    // 파괴되어 복귀할 때 트리가 모두 접히고 선택이 초기화된다.
    @ObservedObject var selection: AgentTreeSelection

    var body: some View {
        HSplitView {
            AgentTreeView(nodes: treeNodes, selection: selection)
                .frame(minWidth: 240, idealWidth: 300, maxWidth: 420)

            rightHost
                .frame(minWidth: 320)
        }
        .onAppear {
            // agent-view 밖에서 탭/워크스페이스가 닫혔을 수 있으므로 복귀 시 항상
            // 수렴시킨다 — 유효 선택이면 무변경, 유실됐으면 첫 유효 tab 또는 nil,
            // nil 이면 selectFirstAvailable 과 동일 동작(reconcile 내부 분기).
            selection.reconcile(workspaces: manager.workspaces)
        }
        .onChange(of: manager.workspaces) { _, newWorkspaces in
            // dangling 선택 수렴: 선택 tab 이 제거됐으면 유효 tab 또는 nil 로 수렴.
            selection.reconcile(workspaces: newWorkspaces)
        }
        .onChange(of: manager.selectedID) { _, newID in
            // 사이드바 클릭 동기화: workspace 만 expand, selectedTabId 무변경.
            if let id = newID,
               manager.workspaces.first(where: { $0.id == id })?.kind == .normal {
                selection.syncFromSidebar(workspaceId: id)
            }
        }
    }

    // MARK: - 우측 호스트 / EmptyState 분기

    @ViewBuilder
    private var rightHost: some View {
        if let target = selectedTarget, isHostable(target) {
            AgentTerminalHostView(
                workspace: target.workspace,
                pane: target.pane,
                tab: target.tab,
                ghosttyApp: ghosttyApp,
                registry: registry
            )
            .id(target.tab.id)
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sidebar.left")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("좌측 트리에서 세션을 선택하세요")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("agent-split-empty")
    }

    // MARK: - 파생 데이터

    private var treeNodes: [AgentTreeNode] {
        AgentTreeBuilder.build(
            workspaces: manager.workspaces,
            snapshots: coordinator.snapshots
        )
    }

    /// 선택된 tabId 가 가리키는 (workspace, pane, tab). 트리에 없으면 nil.
    private var selectedTarget: (workspace: Workspace, pane: Pane, tab: Tab)? {
        guard let tabId = selection.selectedTabId else { return nil }
        return Self.locateTab(tabId: tabId, in: manager.workspaces)
    }

    /// 호스팅 가능 여부(graceful 판정).
    /// - lazy 미생성 탭(sessionId nil): 호스트가 클릭 시 신규 spawn 하므로 hostable.
    /// - 세션 있는 탭: surface 가 살아 있으면 hostable — `.exited` 라도 surface 가
    ///   release 되기 전(closeTab 전)이면 마지막 화면을 표시한다(워크스페이스 탭과
    ///   동일 동작). `.exited` 이면서 surface 까지 release 된 경우에만 EmptyState.
    private func isHostable(_ target: (workspace: Workspace, pane: Pane, tab: Tab)) -> Bool {
        guard let sessionId = target.tab.sessionId else {
            // 한 번도 안 열린 lazy 탭 — 우측 클릭 시 신규 spawn(제약 2).
            return true
        }
        guard registry.contains(id: target.tab.id) || coordinator.snapshots[sessionId] != nil else {
            // surface 미생성이고 snapshot 도 없으면 아직 한 번도 안 뜬 셈 → spawn 가능.
            return true
        }
        // 세션이 종료됐고 surface 도 release 됐으면(closeTab/closeWorkspace 이후)
        // 재호스팅이 불가능하므로 graceful EmptyState.
        if coordinator.snapshots[sessionId]?.agentStatus == .exited,
           !registry.contains(id: target.tab.id) {
            return false
        }
        return true
    }

    /// tabId 로 (workspace, pane, tab) 직접 탐색. sessionId 무관(lazy 탭 포함).
    static func locateTab(
        tabId: UUID,
        in workspaces: [Workspace]
    ) -> (workspace: Workspace, pane: Pane, tab: Tab)? {
        for ws in workspaces where ws.kind == .normal {
            for pane in ws.panes {
                if let tab = pane.tabs.first(where: { $0.id == tabId }) {
                    return (ws, pane, tab)
                }
            }
        }
        return nil
    }
}
