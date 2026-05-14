import SwiftUI

/// pane 분할 트리거 버튼. workspace.panes.count >= 2 이면 disabled (3rd split block).
public struct PaneSplitButton: View {
    public let canSplit: Bool
    public let onSplit: () -> Void

    public init(canSplit: Bool, onSplit: @escaping () -> Void) {
        self.canSplit = canSplit
        self.onSplit = onSplit
    }

    public var body: some View {
        Button(action: onSplit) {
            Label("Pane 분할", systemImage: "rectangle.split.1x2")
        }
        .disabled(!canSplit)
        .accessibilityIdentifier("pane-split-button")
        .help(canSplit ? "현재 워크스페이스에 두 번째 pane 추가" : "이미 두 개의 pane 이 있습니다.")
    }
}
