import SwiftUI

/// agent-view workspace 의 메인 컨텐츠. LazyVGrid 로 모든 활성 세션을 카드 그리드로
/// 표시한다. 카드 click → AgentJumpAction.jump 로 workspace/pane 전환 + first
/// responder 전환.
///
/// Day 6: 헤더에 AgentSortFilterControls 추가. 설정 변경 시 agent-view workspace
/// 의 extraFields["agentView.settings"] 에 영속화. 카드 0개 시 "활성 세션이
/// 없습니다" placeholder (accessibilityIdentifier "agent-dashboard-empty").
public struct AgentDashboardView: View {
    @ObservedObject public var manager: WorkspaceManager
    @ObservedObject public var coordinator: SessionStatusCoordinator
    public let jumpAction: AgentJumpAction
    @StateObject private var viewModel = AgentDashboardViewModel()
    @State private var didLoadSettings: Bool = false

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
        VStack(spacing: 0) {
            AgentSortFilterControls(
                sortOrder: $viewModel.sortOrder,
                filter: $viewModel.filter,
                onChange: { persistSettings(); refresh() }
            )
            Divider()
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
        }
        .onAppear {
            loadSettingsIfNeeded()
            refresh()
        }
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

    private func loadSettingsIfNeeded() {
        guard !didLoadSettings else { return }
        didLoadSettings = true
        let settings = AgentViewSettings.decode(from: manager.agentViewExtraFields())
        viewModel.sortOrder = settings.sortOrder
        viewModel.filter = settings.filter
    }

    private func persistSettings() {
        let settings = AgentViewSettings(
            sortOrder: viewModel.sortOrder,
            filter: viewModel.filter
        )
        let merged = settings.encoded(merging: manager.agentViewExtraFields())
        manager.updateAgentViewExtraFields(merged)
    }
}
