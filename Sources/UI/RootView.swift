import SwiftUI

/// 앱의 최상위 SwiftUI 뷰. 좌측 sidebar + 우측 메인 content area 2 컬럼.
///
/// normal workspace 의 content, agent-view content(P5.5 좌우 스플릿), 설정 페이지
/// content 를 모두 closure 로 주입받아 libghostty / PairingModel / AppSettingsState
/// 의존을 격리한다(테스트 타겟 컴파일 가능). isShowingSettings 가 true 이면
/// HSplitView 전체를 settingsContent closure 결과로 교체한다.
public struct RootView<NormalContent: View, AgentContent: View, SettingsContent: View>: View {
    @ObservedObject public var manager: WorkspaceManager
    @ObservedObject public var coordinator: SessionStatusCoordinator
    public let normalContent: (Workspace) -> NormalContent
    public let agentContent: () -> AgentContent
    public let onCloseWorkspace: ((UUID) -> Void)?
    public let onAddWorkspace: ((String, String) -> Void)?
    /// 설정 페이지 표시 여부 바인딩. AppSettingsState 의존 없이 Bool 바인딩으로 격리한다.
    @Binding public var isShowingSettings: Bool
    /// 설정 버튼 탭 시 실행할 콜백. nil 이면 사이드바 설정 버튼을 숨긴다.
    public let onOpenSettings: (() -> Void)?
    /// 설정 페이지 뷰. SettingsPageView 의존을 격리하기 위해 closure 로 주입한다.
    public let settingsContent: () -> SettingsContent

    public init(
        manager: WorkspaceManager,
        coordinator: SessionStatusCoordinator,
        onCloseWorkspace: ((UUID) -> Void)? = nil,
        onAddWorkspace: ((String, String) -> Void)? = nil,
        isShowingSettings: Binding<Bool>,
        onOpenSettings: (() -> Void)? = nil,
        @ViewBuilder settingsContent: @escaping () -> SettingsContent,
        @ViewBuilder normalContent: @escaping (Workspace) -> NormalContent,
        @ViewBuilder agentContent: @escaping () -> AgentContent
    ) {
        self.manager = manager
        self.coordinator = coordinator
        self.onCloseWorkspace = onCloseWorkspace
        self.onAddWorkspace = onAddWorkspace
        self._isShowingSettings = isShowingSettings
        self.onOpenSettings = onOpenSettings
        self.settingsContent = settingsContent
        self.normalContent = normalContent
        self.agentContent = agentContent
    }

    public var body: some View {
        if isShowingSettings {
            // 설정 페이지 모드: HSplitView 전체를 설정 페이지로 교체
            settingsContent()
        } else {
            // 일반 모드: 기존 HSplitView 레이아웃
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
                    onAddWorkspace: onAddWorkspace,
                    onOpenSettings: onOpenSettings
                )
                .frame(minWidth: 200, idealWidth: 240, maxWidth: 360)

                WorkspaceContentView(
                    manager: manager,
                    coordinator: coordinator,
                    normalContent: normalContent,
                    agentContent: agentContent
                )
                .frame(minWidth: 480)
            }
        }
    }
}
