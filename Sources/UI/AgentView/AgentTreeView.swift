import SwiftUI

/// agent-view 좌측 트리 UI. `AgentTreeBuilder.build` 가 만든 `[AgentTreeNode]` 를
/// `List(selection:)` + `OutlineGroup` 으로 3단 펼침 트리로 그린다.
///
/// 선택 단위는 tab leaf 뿐이다(R8 규칙: tab 클릭만 우측 호스트 교체). workspace/pane
/// 노드는 컨테이너로 expand/collapse 만 한다. `List(selection:)` 의 선택은
/// `selection.selectedTabId` 와 양방향 바인딩되며, workspace/pane 노드 id 가
/// 선택되면 무시하고 마지막 유효 tabId 를 유지한다.
///
/// SwiftUI 의존이나 GhosttyKit 비의존이다.
struct AgentTreeView: View {
    let nodes: [AgentTreeNode]
    @ObservedObject var selection: AgentTreeSelection

    var body: some View {
        List(selection: tabSelectionBinding) {
            OutlineGroup(nodes, children: \.children) { node in
                AgentTreeRow(node: node)
                    .tag(node.id)
                    // tab leaf 만 선택 가능. workspace/pane 은 선택 비활성.
                    .selectionDisabled(node.selectableTabId == nil)
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("agent-tree-list")
    }

    /// `List(selection:)` 은 임의 노드 id 를 set 하려 시도하므로, set 경로에서
    /// 그 id 가 실제 tab leaf 인지 검사해 tab 일 때만 selectedTabId 를 갱신한다.
    /// (방어적이지만 `.selectionDisabled` 로 컨테이너 노드는 애초에 선택되지 않는다.)
    private var tabSelectionBinding: Binding<UUID?> {
        Binding(
            get: { selection.selectedTabId },
            set: { newValue in
                guard let id = newValue else { return }
                if Self.isSelectableTab(id, in: nodes) {
                    selection.selectedTabId = id
                }
            }
        )
    }

    /// 트리에서 id 가 tab leaf 인지 재귀 탐색.
    private static func isSelectableTab(_ id: UUID, in nodes: [AgentTreeNode]) -> Bool {
        for node in nodes {
            if node.selectableTabId == id { return true }
            if let children = node.children, isSelectableTab(id, in: children) {
                return true
            }
        }
        return false
    }
}
