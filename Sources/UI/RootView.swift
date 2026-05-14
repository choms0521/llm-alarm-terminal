import SwiftUI

/// 앱의 최상위 SwiftUI 뷰. 좌측 sidebar + 우측 메인 content area 2 컬럼.
/// normal workspace 의 content 는 closure 로 주입받아 libghostty 의존을 격리한다.
public struct RootView<NormalContent: View>: View {
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
        NavigationSplitView(columnVisibility: .constant(.all)) {
            SidebarView(manager: manager)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 400)
        } detail: {
            WorkspaceContentView(manager: manager, normalContent: normalContent)
        }
        .navigationSplitViewStyle(.balanced)
    }
}
