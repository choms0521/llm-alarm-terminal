import SwiftUI

/// 단일 workspace 탭 row 의 UI 결정을 뷰와 분리한 순수 state.
/// 테스트는 `WorkspaceTabRowState(workspace:).canClose` 등을 직접 검증한다.
public struct WorkspaceTabRowState: Equatable {
    public let id: UUID
    public let displayName: String
    public let symbolName: String
    public let canClose: Bool
    public let closeButtonAccessibilityID: String?

    public init(workspace: Workspace) {
        self.id = workspace.id
        self.displayName = workspace.name
        self.symbolName = workspace.kind == .agentView ? "person.crop.rectangle" : "folder"
        self.canClose = workspace.canClose
        self.closeButtonAccessibilityID = workspace.canClose
            ? "close-workspace-\(workspace.id.uuidString)"
            : nil
    }
}

/// SwiftUI 탭 row. `canClose == false` 인 워크스페이스(agent-view)는 close 버튼 자체를
/// 렌더링하지 않는다(분기 검증은 `WorkspaceTabRowState.canClose` 단위 테스트).
public struct WorkspaceTabRow: View {
    public let workspace: Workspace
    public let onClose: () -> Void

    public init(workspace: Workspace, onClose: @escaping () -> Void) {
        self.workspace = workspace
        self.onClose = onClose
    }

    private var state: WorkspaceTabRowState { WorkspaceTabRowState(workspace: workspace) }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: state.symbolName)
                .foregroundStyle(.secondary)
            Text(state.displayName)
                .lineLimit(1)
            Spacer(minLength: 4)
            if state.canClose {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier(state.closeButtonAccessibilityID ?? "")
                .accessibilityLabel("워크스페이스 닫기")
            }
        }
        .contentShape(Rectangle())
    }
}
