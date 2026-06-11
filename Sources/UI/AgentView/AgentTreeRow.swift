import SwiftUI

/// agent-view 좌측 트리의 한 row. 노드 종류(workspace/pane/tab)에 따라 다른
/// leading 표현을 그린다.
///
/// - workspace: 폴더 심볼 + 이름.
/// - pane: 좌/우 위치 심볼 + 라벨.
/// - tab: leading `AgentStatusBadge`(snapshot 보유 시, 기존 컴포넌트 재활용) +
///   tab name + 한 줄 preview(snapshot.latestPreview 를 truncate).
///
/// SwiftUI 의존이나 GhosttyKit 비의존이다. 선택 여부는 `List(selection:)` 이
/// 외부에서 관리하므로 본 row 는 표시만 담당한다.
struct AgentTreeRow: View {
    let node: AgentTreeNode

    var body: some View {
        switch node {
        case let .workspace(_, name, _):
            Label(name, systemImage: "folder")
                .font(.headline)
                .lineLimit(1)
        case let .pane(_, position, _):
            Label(Self.paneLabel(for: position), systemImage: Self.paneSymbol(for: position))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case let .tab(_, _, name, kind, snapshot):
            tabRow(name: name, kind: kind, snapshot: snapshot)
        }
    }

    @ViewBuilder
    private func tabRow(name: String, kind: PaneKind, snapshot: SessionStatusSnapshot?) -> some View {
        HStack(spacing: 8) {
            if let snapshot {
                AgentStatusBadge(status: snapshot.agentStatus)
            } else {
                Image(systemName: Self.kindSymbol(for: kind))
                    .foregroundStyle(.tertiary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .lineLimit(1)
                if let preview = snapshot.map({ Self.renderedPreview($0.latestPreview) }),
                   !preview.isEmpty {
                    Text(preview)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private static func paneLabel(for position: PanePosition) -> String {
        switch position {
        case .left: return "좌측 페인"
        case .right: return "우측 페인"
        }
    }

    private static func paneSymbol(for position: PanePosition) -> String {
        switch position {
        case .left: return "rectangle.lefthalf.filled"
        case .right: return "rectangle.righthalf.filled"
        }
    }

    private static func kindSymbol(for kind: PaneKind) -> String {
        switch kind {
        case .claude: return "sparkles"
        case .shell: return "terminal"
        }
    }

    /// 한 줄 preview 용 truncate. 카드 그리드의 200 grapheme 보다 짧게 한 줄에 맞춘다.
    /// ANSI SGR/CSI/OSC 시퀀스는 truncate 전에 strip 한다 — raw ESC 가 리스트에
    /// 노출되는 것과 절단이 시퀀스 중간을 가르는 것을 동시에 방지(카드 그리드가
    /// AnsiSGRParser 로 처리하던 것과 동일한 안전선).
    private static func renderedPreview(_ raw: String) -> String {
        let stripped = String(AnsiSGRParser.parse(raw).characters)
        let collapsed = stripped
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Utf8BoundaryTruncator.truncate(collapsed, maxGraphemes: 80)
    }
}
