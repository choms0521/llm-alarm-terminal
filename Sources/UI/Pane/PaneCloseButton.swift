import SwiftUI

/// 각 pane 우측 상단에 overlay 되는 close 버튼. 클릭 시 coordinator.closePane 호출 트리거.
struct PaneCloseButton: View {
    let onClose: () -> Void

    var body: some View {
        Button(action: onClose) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.tertiary)
                .padding(4)
                .background(Circle().fill(Color.black.opacity(0.25)))
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Pane 닫기")
        .accessibilityIdentifier("pane-close-button")
        .help("이 pane 의 세션 종료")
    }
}
