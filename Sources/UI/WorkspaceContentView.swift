import SwiftUI

/// 선택된 workspace 의 메인 컨텐츠 라우터. agent-view 는 P3 Day 5 부터
/// `AgentDashboardView` 가 실데이터 카드 그리드를 표시한다. normal workspace 의
/// libghostty 의존 view 는 `normalContent` closure 로 분리한다.
public struct WorkspaceContentView<NormalContent: View>: View {
    @ObservedObject public var manager: WorkspaceManager
    @ObservedObject public var coordinator: SessionStatusCoordinator
    public let jumpAction: AgentJumpAction
    public let normalContent: (Workspace) -> NormalContent

    public init(
        manager: WorkspaceManager,
        coordinator: SessionStatusCoordinator,
        jumpAction: AgentJumpAction,
        @ViewBuilder normalContent: @escaping (Workspace) -> NormalContent
    ) {
        self.manager = manager
        self.coordinator = coordinator
        self.jumpAction = jumpAction
        self.normalContent = normalContent
    }

    public var body: some View {
        Group {
            if let id = manager.selectedID,
               let workspace = manager.workspaces.first(where: { $0.id == id }) {
                switch workspace.kind {
                case .agentView:
                    AgentDashboardView(
                        manager: manager,
                        coordinator: coordinator,
                        jumpAction: jumpAction
                    )
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
