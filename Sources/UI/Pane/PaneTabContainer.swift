import SwiftUI

/// 단일 pane 을 표시하는 컨테이너(REQ-2): 상단 탭바 + 활성 tab 의 터미널 surface.
///
/// `PaneTerminalView` 는 `pane.activeTabId` 를 anchor 로 SurfaceRegistry 에서 surface 를
/// acquire 한다. 활성 tab 이 바뀌면 `.id(pane.activeTabId)` 가 NSViewRepresentable 을
/// 재생성하여 새 활성 tab 의 surface 로 교체한다. 비활성 tab 의 surface 는 registry 에
/// 그대로 alive 로 남으므로(ADR-I) 탭 전환만으로는 release 되지 않고 상태가 보존된다.
struct PaneTabContainer: View {
    let workspace: Workspace
    let pane: Pane
    let ghosttyApp: GhosttyApp
    let coordinator: WorkspaceCoordinator

    @State private var chooserPresented = false

    var body: some View {
        VStack(spacing: 0) {
            TabBarView(
                pane: pane,
                onSelect: { tabId in
                    coordinator.manager.selectTab(
                        workspaceId: workspace.id, paneId: pane.id, tabId: tabId
                    )
                },
                onClose: { tabId in
                    Task { @MainActor in
                        await coordinator.closeTab(
                            workspaceId: workspace.id, paneId: pane.id, tabId: tabId
                        )
                    }
                },
                onAddTab: { chooserPresented = true }
            )
            Divider()
            PaneTerminalView(
                workspace: workspace,
                pane: pane,
                ghosttyApp: ghosttyApp,
                registry: coordinator.surfaceRegistry
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 활성 tab 변경 시 surface 교체. 비활성 tab surface 는 registry 에 보존.
            .id(pane.activeTabId)
        }
        .sheet(isPresented: $chooserPresented) {
            PaneTypeChooser(
                onSelect: { kind in
                    chooserPresented = false
                    Task { @MainActor in
                        await coordinator.addTab(
                            workspaceId: workspace.id, paneId: pane.id, kind: kind
                        )
                    }
                },
                onCancel: { chooserPresented = false }
            )
        }
    }
}
