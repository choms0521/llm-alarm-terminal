import SwiftUI

/// agent-view 탭 선택 시 표시되는 P3 진입 전 placeholder.
public struct AgentViewPlaceholder: View {
    public init() {}

    public var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.rectangle.stack")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)
            Text("에이전트 뷰")
                .font(.title2)
                .bold()
            Text("P3 단계에서 에이전트 대시보드(Pinned First Tab)가 여기에 표시됩니다.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 400)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .accessibilityIdentifier("agent-view-placeholder")
    }
}
