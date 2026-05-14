import SwiftUI

/// 앱의 최상위 SwiftUI 뷰. 좌측 sidebar + 우측 메인 content area 2 컬럼.
/// normal workspace 의 content 는 closure 로 주입받아 libghostty 의존을 격리한다.
/// agent-view content 는 P3 Day 5 부터 `AgentDashboardView` 로 직접 wire.
public struct RootView<NormalContent: View>: View {
    @ObservedObject public var manager: WorkspaceManager
    @ObservedObject public var coordinator: SessionStatusCoordinator
    public let jumpAction: AgentJumpAction
    public let normalContent: (Workspace) -> NormalContent
    public let onCloseWorkspace: ((UUID) -> Void)?
    public let onAddWorkspace: ((String, String) -> Void)?

    public init(
        manager: WorkspaceManager,
        coordinator: SessionStatusCoordinator,
        jumpAction: AgentJumpAction,
        onCloseWorkspace: ((UUID) -> Void)? = nil,
        onAddWorkspace: ((String, String) -> Void)? = nil,
        @ViewBuilder normalContent: @escaping (Workspace) -> NormalContent
    ) {
        self.manager = manager
        self.coordinator = coordinator
        self.jumpAction = jumpAction
        self.onCloseWorkspace = onCloseWorkspace
        self.onAddWorkspace = onAddWorkspace
        self.normalContent = normalContent
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            SidebarView(
                manager: manager,
                onCloseWorkspace: onCloseWorkspace,
                onAddWorkspace: onAddWorkspace
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 400)
        } detail: {
            WorkspaceContentView(
                manager: manager,
                coordinator: coordinator,
                jumpAction: jumpAction,
                normalContent: normalContent
            )
        }
        .navigationSplitViewStyle(.balanced)
    }
}
