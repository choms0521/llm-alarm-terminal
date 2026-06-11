import SwiftUI

/// agent-view 좌측 트리 UI. `AgentTreeBuilder.build` 가 만든 `[AgentTreeNode]` 를
/// `List(selection:)` + `DisclosureGroup` 재귀로 3단 펼침 트리로 그린다.
///
/// 선택 단위는 tab leaf 뿐이다(R8 규칙: tab 클릭만 우측 호스트 교체). workspace/pane
/// 노드는 컨테이너로 expand/collapse 만 한다. `List(selection:)` 의 선택은
/// `selection.selectedTabId` 와 양방향 바인딩되며, workspace/pane 노드 id 가
/// 선택되면 무시하고 마지막 유효 tabId 를 유지한다.
///
/// 펼침 상태는 SwiftUI 내부 상태가 아니라 `selection.expandedNodeIds` 가 보유한다
/// — agent-view 를 떠났다 돌아와도(뷰 재생성) 펼침/선택이 보존되는 근거.
///
/// SwiftUI 의존이나 GhosttyKit 비의존이다.
struct AgentTreeView: View {
    let nodes: [AgentTreeNode]
    @ObservedObject var selection: AgentTreeSelection

    var body: some View {
        List(selection: tabSelectionBinding) {
            ForEach(nodes) { node in
                AgentTreeNodeView(node: node, selection: selection)
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

/// 트리 노드 1개의 재귀 렌더. 컨테이너(workspace/pane)는 `DisclosureGroup` 으로,
/// tab leaf 는 row 단독으로 그린다. 펼침 바인딩은 `AgentTreeSelection` 의
/// `isExpanded`/`setExpanded` 로 위임하여 뷰 생명주기와 상태를 분리한다.
private struct AgentTreeNodeView: View {
    let node: AgentTreeNode
    @ObservedObject var selection: AgentTreeSelection

    var body: some View {
        if let children = node.children {
            DisclosureGroup(isExpanded: expansionBinding) {
                ForEach(children) { child in
                    AgentTreeNodeView(node: child, selection: selection)
                }
            } label: {
                AgentTreeRow(node: node)
            }
            .tag(node.id)
            // 컨테이너 노드는 expand/collapse 전용 — 선택 비활성.
            .selectionDisabled(node.selectableTabId == nil)
        } else {
            AgentTreeRow(node: node)
                .tag(node.id)
                .selectionDisabled(node.selectableTabId == nil)
        }
    }

    private var expansionBinding: Binding<Bool> {
        Binding(
            get: { selection.isExpanded(node.id) },
            set: { selection.setExpanded(node.id, expanded: $0) }
        )
    }
}
