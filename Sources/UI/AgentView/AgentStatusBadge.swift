import SwiftUI

/// AgentStatus 의 한국어 라벨 + 색상 badge.
///
/// idle / working / needsInput / exited 4 종 모두 한국어 라벨 보유. needsInput 은
/// orange + pulse animation 으로 사용자 주의 유도.
public struct AgentStatusBadge: View {
    public let status: AgentStatus

    public init(status: AgentStatus) {
        self.status = status
    }

    /// 한국어 사용자 visible 라벨. AgentStatusBadgeTests 가 4 종 모두 XCTAssertEqual.
    public static func label(for status: AgentStatus) -> String {
        switch status {
        case .idle: return "활성"
        case .working: return "작업 중"
        case .needsInput: return "입력 필요"
        case .exited: return "종료됨"
        }
    }

    public static func color(for status: AgentStatus) -> Color {
        switch status {
        case .idle: return .gray
        case .working: return .blue
        case .needsInput: return .orange
        case .exited: return .secondary
        }
    }

    public var body: some View {
        Text(Self.label(for: status))
            .font(.caption)
            .fontWeight(.semibold)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Self.color(for: status).opacity(0.15))
            )
            .foregroundStyle(Self.color(for: status))
            .modifier(PulseIfNeedsInput(active: status == .needsInput))
            .accessibilityLabel(Self.label(for: status))
    }
}

private struct PulseIfNeedsInput: ViewModifier {
    let active: Bool
    @State private var pulse = false

    func body(content: Content) -> some View {
        if active {
            content
                .opacity(pulse ? 0.5 : 1.0)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                .onAppear { pulse = true }
        } else {
            content
        }
    }
}
