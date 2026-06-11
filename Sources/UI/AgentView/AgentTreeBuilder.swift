import Foundation

/// `WorkspaceManager.workspaces` × `SessionStatusCoordinator.snapshots` 를
/// 3단 트리(`AgentTreeNode`)로 join 하는 순수 함수.
///
/// SwiftUI 비의존. 정방향 순회(workspaces → panes → tabs)에 snapshot lookup 만
/// 더한다(AgentDashboardViewModel 의 역인덱스 순회와 다름). 정렬은 workspace
/// 추가순(P3.5 Q-β) — `workspaces` 배열 순서를 그대로 보존한다.
///
/// agent-view workspace 자신(`kind == .agentView`, panes 빈 배열)은 트리에서
/// 제외하고 `kind == .normal` 만 순회한다.
public enum AgentTreeBuilder {
    /// workspaces × snapshots 를 3단 트리로 join 한다.
    /// - Parameters:
    ///   - workspaces: 추가순 정렬된 워크스페이스 배열. agentView kind 는 필터링됨.
    ///   - snapshots: sessionId 별 상태 스냅샷. tab.sessionId 로 lookup.
    /// - Returns: workspace 노드 배열. 각 노드의 children 은 pane, 그 아래는 tab leaf.
    public static func build(
        workspaces: [Workspace],
        snapshots: [UUID: SessionStatusSnapshot]
    ) -> [AgentTreeNode] {
        workspaces
            .filter { $0.kind == .normal }
            .map { ws in
                let paneNodes = ws.panes.map { pane in
                    let tabNodes = pane.tabs.map { tab in
                        AgentTreeNode.tab(
                            id: tab.id,
                            sessionId: tab.sessionId,
                            name: tab.name,
                            kind: tab.kind,
                            snapshot: tab.sessionId.flatMap { snapshots[$0] }
                        )
                    }
                    return AgentTreeNode.pane(
                        id: pane.id,
                        position: pane.position,
                        children: tabNodes
                    )
                }
                return AgentTreeNode.workspace(
                    id: ws.id,
                    name: ws.name,
                    children: paneNodes
                )
            }
    }
}
