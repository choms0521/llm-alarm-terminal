import SwiftUI

/// 카드 한 장. workspace 이름 + status badge + AttributedString preview.
///
/// preview 는 `AnsiSGRParser.parse` 를 통해 raw ESC 가 strip 된 AttributedString.
/// click 동작은 부모 view (AgentDashboardView) 의 onTapGesture 가 담당한다.
public struct AgentCardView: View {
    public let card: AgentCard

    public init(card: AgentCard) {
        self.card = card
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(card.workspaceName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                AgentStatusBadge(status: card.snapshot.agentStatus)
            }
            Text(Self.renderedPreview(card.snapshot.latestPreview))
                .font(.system(.caption, design: .monospaced))
                .lineLimit(3)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(card.workspaceName), \(AgentStatusBadge.label(for: card.snapshot.agentStatus))")
    }

    /// 200 grapheme cluster 로 truncate 한 뒤 SGR 파싱.
    private static func renderedPreview(_ raw: String) -> AttributedString {
        let truncated = Utf8BoundaryTruncator.truncate(raw, maxGraphemes: 200)
        return AnsiSGRParser.parse(truncated)
    }
}
