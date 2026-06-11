import Foundation
import Combine

/// agent-view 트리의 선택 상태 모델.
///
/// `selectedTabId` 가 우측 호스트가 mount 할 tab 을 결정하고, `expandedNodeIds`
/// 가 트리의 펼침 상태를 보유한다. workspaces 변경 시 dangling 선택을 수렴시키는
/// 로직(`selectFirstAvailable`)과 사이드바 동기화(`syncFromSidebar`)를 제공한다.
///
/// `selectFirstAvailable` 의 선택 우선순위는 workspace 추가순 → pane 순서 →
/// tab 순서로 첫 `sessionId != nil` tab 이다(`AgentTreeBuilder` 정방향 순회와
/// 동일 순서). 선택 가능한 tab 이 전무하면 nil(EmptyState 트리거).
@MainActor
public final class AgentTreeSelection: ObservableObject {
    @Published public var selectedTabId: UUID?
    @Published public var expandedNodeIds: Set<UUID> = []

    public init() {}

    /// 트리의 첫 sessionId 보유 tab 을 선택한다(추가순 first). 선택 후 그 tab 의
    /// 부모 workspace/pane 을 expand 한다. 전부 비면 selectedTabId 를 nil 로
    /// 두어 EmptyState 를 트리거한다.
    public func selectFirstAvailable(workspaces: [Workspace]) {
        for ws in workspaces where ws.kind == .normal {
            for pane in ws.panes {
                for tab in pane.tabs where tab.sessionId != nil {
                    selectedTabId = tab.id
                    expandedNodeIds.insert(ws.id)
                    expandedNodeIds.insert(pane.id)
                    return
                }
            }
        }
        selectedTabId = nil
    }

    /// 사이드바 클릭 동기화: 해당 workspace 만 expand 하고 selectedTabId 는
    /// 변경하지 않는다(P3.5 D3-6 R8 규칙).
    public func syncFromSidebar(workspaceId: UUID) {
        expandedNodeIds.insert(workspaceId)
    }
}
