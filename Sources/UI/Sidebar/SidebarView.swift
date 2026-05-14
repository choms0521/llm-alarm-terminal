import SwiftUI
import UniformTypeIdentifiers

/// 왼쪽 vertical sidebar — workspace 탭 목록 + 새 workspace 추가 버튼.
///
/// Day 3 범위: 클릭으로 탭 전환, `+` 클릭으로 cwd picker(폴더 선택) → 새 normal workspace.
/// 키보드 단축키는 Day 8 에서 wiring.
public struct SidebarView: View {
    @ObservedObject public var manager: WorkspaceManager
    @State private var pickerPresented = false

    public init(manager: WorkspaceManager) {
        self.manager = manager
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
                        onClose: { manager.removeWorkspace(id: ws.id) }
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
                manager.addWorkspace(cwd: url.path, name: url.lastPathComponent)
            case .failure(let err):
                KoreanLogger.error("폴더 선택 실패: \(err.localizedDescription)")
            }
        }
    }
}
