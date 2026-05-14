import SwiftUI

/// 선택된 workspace 의 메인 컨텐츠 라우터.
/// agent-view → `AgentViewPlaceholder`, normal → Day 4 의 pane terminal (현재는 placeholder).
public struct WorkspaceContentView: View {
    @ObservedObject public var manager: WorkspaceManager

    public init(manager: WorkspaceManager) {
        self.manager = manager
    }

    public var body: some View {
        Group {
            if let id = manager.selectedID,
               let workspace = manager.workspaces.first(where: { $0.id == id }) {
                switch workspace.kind {
                case .agentView:
                    AgentViewPlaceholder()
                case .normal:
                    NormalWorkspacePlaceholder(workspace: workspace)
                }
            } else {
                Text("선택된 워크스페이스가 없습니다.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// Day 3 placeholder. Day 4 에서 pane split UI + libghostty 호스팅 뷰로 교체된다.
public struct NormalWorkspacePlaceholder: View {
    public let workspace: Workspace

    public init(workspace: Workspace) {
        self.workspace = workspace
    }

    public var body: some View {
        VStack(spacing: 8) {
            Text(workspace.name)
                .font(.title2)
                .bold()
            Text(workspace.cwd)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer()
            Text("Day 4 — pane 분할 UI 와 libghostty 터미널이 여기에 표시됩니다.")
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 24)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("normal-workspace-placeholder")
    }
}
