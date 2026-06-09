import SwiftUI

/// normal workspace 의 메인 컨텐츠. 최대 2개의 pane 을 좌우(HStack) 분할로 표시한다.
///
/// P3.5 schema v2 (REQ-1): 상하 분할에서 좌우 분할로 전환. 단일 pane 일 때는 전체 영역,
/// 두 pane 일 때는 left/right 50:50 (drag resize 는 out of scope).
/// pane 없는 빈 workspace 는 사용자가 직접 종류를 선택해 첫 pane 을 생성하도록 한다.
struct WorkspacePaneContentView: View {
    let workspace: Workspace
    let ghosttyApp: GhosttyApp
    let coordinator: WorkspaceCoordinator
    @ObservedObject var manager: WorkspaceManager

    @State private var chooserPresented = false
    @State private var addingFirstPane = false

    init(
        workspace: Workspace,
        ghosttyApp: GhosttyApp,
        coordinator: WorkspaceCoordinator
    ) {
        self.workspace = workspace
        self.ghosttyApp = ghosttyApp
        self.coordinator = coordinator
        self.manager = coordinator.manager
    }

    var body: some View {
        VStack(spacing: 0) {
            paneStack

            Divider()
            controlBar
        }
        .sheet(isPresented: $chooserPresented) {
            PaneTypeChooser(
                onSelect: { kind in
                    chooserPresented = false
                    let wantFirst = addingFirstPane
                    addingFirstPane = false
                    Task { @MainActor in
                        await coordinator.addPane(
                            workspaceId: workspace.id,
                            kind: kind,
                            position: wantFirst ? .left : .right
                        )
                    }
                },
                onCancel: {
                    chooserPresented = false
                    addingFirstPane = false
                }
            )
        }
    }

    @ViewBuilder
    private var paneStack: some View {
        let left = workspace.panes.first(where: { $0.position == .left })
        let right = workspace.panes.first(where: { $0.position == .right })

        if left == nil && right == nil {
            emptyState
        } else {
            // P3.5 schema v2 (REQ-1): VStack → HStack (좌/우 분할).
            HStack(spacing: 0) {
                if let left = left {
                    paneSlot(pane: left)
                }
                if let right = right {
                    Divider()
                    paneSlot(pane: right)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func paneSlot(pane: Pane) -> some View {
        // P3.5 Day 3 (REQ-2): bare PaneTerminalView 를 PaneTabContainer 로 wrap.
        // pane close 는 per-tab close + cascade(REQ-4)로 대체되므로 PaneCloseButton
        // overlay 를 제거한다(탭바의 "×" 가 마지막 tab 을 닫으면 pane 이 자동 정리됨).
        PaneTabContainer(
            workspace: workspace,
            pane: pane,
            ghosttyApp: ghosttyApp,
            coordinator: coordinator
        )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(pane.id)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("pane 이 없습니다.")
                .foregroundStyle(.secondary)
            Button(action: {
                addingFirstPane = true
                chooserPresented = true
            }) {
                Label("새 pane", systemImage: "plus.rectangle")
            }
            .accessibilityIdentifier("add-first-pane-button")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var controlBar: some View {
        HStack {
            PaneSplitButton(
                canSplit: manager.canSplit(workspaceId: workspace.id),
                onSplit: {
                    addingFirstPane = false
                    chooserPresented = true
                }
            )
            Spacer()
            Text(workspace.cwd)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}
