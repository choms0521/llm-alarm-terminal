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
        // P3 Recovery: NavigationSplitView with `.balanced` style could hide or
        // overlay the sidebar at typical desktop window widths (~900px) on
        // macOS 14+, leaving the workspace surface to fill the entire window
        // while the workspace list became inaccessible. HSplitView gives a
        // deterministic two-pane layout with a draggable divider and a
        // minimum sidebar width — both required for the agent-view UX.
        HSplitView {
            SidebarView(
                manager: manager,
                onCloseWorkspace: onCloseWorkspace,
                onAddWorkspace: onAddWorkspace
            )
            .frame(minWidth: 200, idealWidth: 240, maxWidth: 360)

            WorkspaceContentView(
                manager: manager,
                coordinator: coordinator,
                jumpAction: jumpAction,
                normalContent: normalContent
            )
            .frame(minWidth: 480)
        }
    }
}
