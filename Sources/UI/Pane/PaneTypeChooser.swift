import SwiftUI

/// + Split Pane 클릭 시 등장하는 modal sheet — claude / shell 선택.
public struct PaneTypeChooser: View {
    public let onSelect: (PaneKind) -> Void
    public let onCancel: () -> Void

    public init(onSelect: @escaping (PaneKind) -> Void, onCancel: @escaping () -> Void) {
        self.onSelect = onSelect
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(spacing: 16) {
            Text("새 pane 종류 선택")
                .font(.headline)

            HStack(spacing: 12) {
                paneCard(
                    kind: .claude,
                    title: "Claude",
                    symbol: "sparkles",
                    description: "에이전트 세션을 새 pane 으로 분할"
                )
                paneCard(
                    kind: .shell,
                    title: "Shell",
                    symbol: "terminal",
                    description: "zsh 인터랙티브 셸을 새 pane 으로 분할"
                )
            }

            HStack {
                Spacer()
                Button("취소", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("pane-chooser-cancel")
            }
        }
        .padding(20)
        .frame(minWidth: 420)
    }

    @ViewBuilder
    private func paneCard(kind: PaneKind, title: String, symbol: String, description: String) -> some View {
        Button(action: { onSelect(kind) }) {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 28))
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(minWidth: 160, minHeight: 120)
            .padding()
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("pane-chooser-\(kind.rawValue)")
    }
}
