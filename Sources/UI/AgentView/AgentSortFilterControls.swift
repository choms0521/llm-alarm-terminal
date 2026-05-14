import SwiftUI

/// agent-view 헤더의 정렬/필터 컨트롤. 두 Picker 가 ViewModel 의 sortOrder /
/// filter 에 직접 binding 된다. 변경 시 호출자가 `WorkspaceManager.
/// updateAgentViewExtraFields(_:)` 로 영속화한다.
public struct AgentSortFilterControls: View {
    @Binding public var sortOrder: AgentSortOrder
    @Binding public var filter: AgentFilterOption
    public let onChange: (() -> Void)?

    public init(
        sortOrder: Binding<AgentSortOrder>,
        filter: Binding<AgentFilterOption>,
        onChange: (() -> Void)? = nil
    ) {
        self._sortOrder = sortOrder
        self._filter = filter
        self.onChange = onChange
    }

    public var body: some View {
        HStack(spacing: 16) {
            Picker("정렬", selection: $sortOrder) {
                Text("최근 활동").tag(AgentSortOrder.lastActivityAtDesc)
                Text("오래된 활동").tag(AgentSortOrder.lastActivityAtAsc)
                Text("이름순").tag(AgentSortOrder.workspaceName)
                Text("상태 우선").tag(AgentSortOrder.statusFirst)
            }
            .pickerStyle(.menu)
            .onChange(of: sortOrder) { _, _ in onChange?() }

            Picker("필터", selection: $filter) {
                Text("전체").tag(AgentFilterOption.all)
                Text("입력 필요").tag(AgentFilterOption.needsInput)
                Text("작업 중").tag(AgentFilterOption.working)
                Text("Claude 전용").tag(AgentFilterOption.claudeOnly)
            }
            .pickerStyle(.menu)
            .onChange(of: filter) { _, _ in onChange?() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
