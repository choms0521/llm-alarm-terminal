import SwiftUI

/// 앱의 최상위 SwiftUI 뷰. 좌측 sidebar + 우측 메인 content area 2 컬럼.
public struct RootView: View {
    @ObservedObject public var manager: WorkspaceManager

    public init(manager: WorkspaceManager) {
        self.manager = manager
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            SidebarView(manager: manager)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 400)
        } detail: {
            WorkspaceContentView(manager: manager)
        }
        .navigationSplitViewStyle(.balanced)
    }
}
