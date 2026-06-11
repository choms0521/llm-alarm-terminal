import SwiftUI

/// 선택된 workspace 의 메인 컨텐츠 라우터.
///
/// P5.5: agent-view 는 좌우 스플릿(`AgentSplitView`)으로 진화했다. 그러나 그
/// 스플릿 뷰는 GhosttyApp/AgentTerminalHostView(GhosttyKit) 의존이므로, normal
/// workspace 와 동일하게 `agentContent` closure 로 주입하여 본 라우터가 libghostty
/// 비의존을 유지한다(테스트 타겟 컴파일 가능). 케이스 라우팅만 본 파일이 담당한다.
public struct WorkspaceContentView<NormalContent: View, AgentContent: View>: View {
    @ObservedObject public var manager: WorkspaceManager
    @ObservedObject public var coordinator: SessionStatusCoordinator
    public let normalContent: (Workspace) -> NormalContent
    public let agentContent: () -> AgentContent

    public init(
        manager: WorkspaceManager,
        coordinator: SessionStatusCoordinator,
        @ViewBuilder normalContent: @escaping (Workspace) -> NormalContent,
        @ViewBuilder agentContent: @escaping () -> AgentContent
    ) {
        self.manager = manager
        self.coordinator = coordinator
        self.normalContent = normalContent
        self.agentContent = agentContent
    }

    public var body: some View {
        Group {
            if let id = manager.selectedID,
               let workspace = manager.workspaces.first(where: { $0.id == id }) {
                switch workspace.kind {
                case .agentView:
                    agentContent()
                case .normal:
                    normalContent(workspace)
                }
            } else {
                Text("선택된 워크스페이스가 없습니다.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
