import SwiftUI
import UniformTypeIdentifiers

/// 왼쪽 vertical sidebar — workspace 탭 목록 + 새 workspace 추가 버튼.
///
/// Day 3 범위: 클릭으로 탭 전환, `+` 클릭으로 cwd picker(폴더 선택) → 새 normal workspace.
/// Day 5 추가: close 버튼은 `coordinator.closeWorkspace(id:)` 를 호출하여 session lifecycle 동시 정리.
/// 키보드 단축키는 Day 8 에서 wiring.
public struct SidebarView: View {
    @ObservedObject public var manager: WorkspaceManager
    /// closeWorkspace 트리거. Day 3 단독 빌드에서는 nil 허용; Day 5 coordinator 가 wiring.
    public var onCloseWorkspace: ((UUID) -> Void)?
    public var onAddWorkspace: ((String, String) -> Void)?
    /// 설정 창 열기 트리거. nil이면 설정 버튼을 숨긴다(테스트 단독 빌드 호환).
    public var onOpenSettings: (() -> Void)?
    @State private var pickerPresented = false

    public init(
        manager: WorkspaceManager,
        onCloseWorkspace: ((UUID) -> Void)? = nil,
        onAddWorkspace: ((String, String) -> Void)? = nil,
        onOpenSettings: (() -> Void)? = nil
    ) {
        self.manager = manager
        self.onCloseWorkspace = onCloseWorkspace
        self.onAddWorkspace = onAddWorkspace
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        VStack(spacing: 0) {
            List(selection: Binding(
                get: { manager.selectedID },
                set: { newValue in
                    if let id = newValue { manager.select(id: id) }
                }
            )) {
                ForEach(manager.workspaces) { ws in
                    WorkspaceTabRow(
                        workspace: ws,
                        onClose: {
                            if let close = onCloseWorkspace {
                                close(ws.id)
                            } else {
                                manager.removeWorkspace(id: ws.id)
                            }
                        }
                    )
                    .tag(ws.id)
                }
            }
            .listStyle(.sidebar)
            .accessibilityIdentifier("workspace-sidebar-list")

            Divider()

            Button(action: { pickerPresented = true }) {
                Label("새 워크스페이스", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .padding(8)
            .accessibilityIdentifier("new-workspace-button")

            if let openSettings = onOpenSettings {
                Divider()

                Button(action: openSettings) {
                    Label("설정", systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .padding(8)
                .accessibilityIdentifier("open-settings-button")
            }
        }
        .frame(minWidth: 200, idealWidth: 240)
        .fileImporter(
            isPresented: $pickerPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let needsScope = url.startAccessingSecurityScopedResource()
                defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
                if let add = onAddWorkspace {
                    add(url.path, url.lastPathComponent)
                } else {
                    manager.addWorkspace(cwd: url.path, name: url.lastPathComponent)
                }
            case .failure(let err):
                KoreanLogger.error("폴더 선택 실패: \(err.localizedDescription)")
            }
        }
    }
}
