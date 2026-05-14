import SwiftUI

/// 선택된 workspace 의 메인 컨텐츠 라우터. 의도적으로 `normalContent` 를 closure 로 받아
/// libghostty 의존 view(`WorkspacePaneContentView`) 와 분리한다 — 본 라우터 자체는
/// 의존 없이 pure SwiftUI 로 테스트 가능하다.
public struct WorkspaceContentView<NormalContent: View>: View {
    @ObservedObject public var manager: WorkspaceManager
    public let normalContent: (Workspace) -> NormalContent

    public init(
        manager: WorkspaceManager,
        @ViewBuilder normalContent: @escaping (Workspace) -> NormalContent
    ) {
        self.manager = manager
        self.normalContent = normalContent
    }

    public var body: some View {
        Group {
            if let id = manager.selectedID,
               let workspace = manager.workspaces.first(where: { $0.id == id }) {
                switch workspace.kind {
                case .agentView:
                    AgentViewPlaceholder()
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
