import SwiftUI

/// normal workspace 의 메인 컨텐츠. 최대 2개의 pane 을 가로(VStack) 분할로 표시한다.
///
/// 단일 pane 일 때는 전체 영역, 두 pane 일 때는 top/bottom 50:50 (drag resize 는 out of scope).
/// pane 없는 빈 workspace 는 사용자가 직접 종류를 선택해 첫 pane 을 생성하도록 한다.
struct WorkspacePaneContentView: View {
    let workspace: Workspace
    let ghosttyApp: GhosttyApp
    @ObservedObject var manager: WorkspaceManager

    @State private var chooserPresented = false
    @State private var addingFirstPane = false

    init(workspace: Workspace, ghosttyApp: GhosttyApp, manager: WorkspaceManager) {
        self.workspace = workspace
        self.ghosttyApp = ghosttyApp
        self.manager = manager
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
                    if addingFirstPane {
                        manager.addPane(workspaceId: workspace.id, kind: kind, position: .top)
                        addingFirstPane = false
                    } else {
                        manager.addPane(workspaceId: workspace.id, kind: kind, position: .bottom)
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
        let top = workspace.panes.first(where: { $0.position == .top })
        let bottom = workspace.panes.first(where: { $0.position == .bottom })

        if top == nil && bottom == nil {
            emptyState
        } else {
            VStack(spacing: 0) {
                if let top = top {
                    PaneTerminalView(workspace: workspace, pane: top, ghosttyApp: ghosttyApp)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .id(top.id)
                }
                if let bottom = bottom {
                    Divider()
                    PaneTerminalView(workspace: workspace, pane: bottom, ghosttyApp: ghosttyApp)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .id(bottom.id)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
