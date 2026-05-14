import SwiftUI

/// agent-view workspace 의 메인 컨텐츠. LazyVGrid 로 모든 활성 세션을 카드 그리드로
/// 표시한다. 카드 click → AgentJumpAction.jump 로 workspace/pane 전환 + first
/// responder 전환.
///
/// 카드 0개 시 "활성 세션이 없습니다" placeholder (accessibilityIdentifier
/// "agent-dashboard-empty") 를 표시한다.
public struct AgentDashboardView: View {
    @ObservedObject public var manager: WorkspaceManager
    @ObservedObject public var coordinator: SessionStatusCoordinator
    public let jumpAction: AgentJumpAction
    @StateObject private var viewModel = AgentDashboardViewModel()

    public init(
        manager: WorkspaceManager,
        coordinator: SessionStatusCoordinator,
        jumpAction: AgentJumpAction
    ) {
        self.manager = manager
        self.coordinator = coordinator
        self.jumpAction = jumpAction
    }

    public var body: some View {
        Group {
            if viewModel.cards.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 280), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(viewModel.cards) { card in
                            AgentCardView(card: card)
                                .onTapGesture { performJump(for: card) }
                                .contentShape(Rectangle())
                        }
                    }
                    .padding(16)
                }
            }
        }
        .onAppear { refresh() }
        .onChange(of: coordinator.snapshots) { _, _ in refresh() }
        .onChange(of: manager.workspaces) { _, _ in refresh() }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("활성 세션이 없습니다")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("agent-dashboard-empty")
    }

    private func refresh() {
        let index = SessionIndex(workspaces: manager.workspaces)
        viewModel.refresh(
            snapshots: coordinator.snapshots,
            workspaces: manager.workspaces,
            sessionIndex: index
        )
    }

    private func performJump(for card: AgentCard) {
        let index = SessionIndex(workspaces: manager.workspaces)
        jumpAction.jump(snapshot: card.snapshot, snapshotIndex: index)
    }
}
