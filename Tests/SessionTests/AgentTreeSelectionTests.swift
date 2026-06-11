import XCTest
import Foundation

/// AgentTreeSelection 의 선택 수렴(selectFirstAvailable)과 사이드바 동기화
/// (syncFromSidebar)를 검증한다.
@MainActor
final class AgentTreeSelectionTests: XCTestCase {

    private let fixedDate = Date(timeIntervalSince1970: 1_778_716_800)

    private func makeWorkspace(
        name: String,
        tabs: [Tab],
        kind: WorkspaceKind = .normal
    ) -> Workspace {
        let pane = Pane(position: .left, tabs: tabs, activeTabId: tabs.first?.id)
        return Workspace(name: name, cwd: "/tmp", panes: [pane], createdAt: fixedDate, kind: kind)
    }

    // MARK: - selectFirstAvailable: 추가순 첫 sessionId tab 반환

    func test_selectFirstAvailable_picksFirstSessionTabInInsertionOrder() {
        let firstSession = UUID()
        let firstTab = Tab(sessionId: firstSession, kind: .claude, name: "Claude")
        let secondTab = Tab(sessionId: UUID(), kind: .shell, name: "셸")
        let wsA = makeWorkspace(name: "A", tabs: [firstTab, secondTab])
        let wsB = makeWorkspace(name: "B", tabs: [Tab(sessionId: UUID(), kind: .shell, name: "셸")])

        let selection = AgentTreeSelection()
        selection.selectFirstAvailable(workspaces: [wsA, wsB])

        XCTAssertEqual(selection.selectedTabId, firstTab.id)
        // 선택된 tab 의 부모 workspace/pane 이 expand 됨
        XCTAssertTrue(selection.expandedNodeIds.contains(wsA.id))
    }

    // MARK: - selectFirstAvailable: sessionId nil tab 은 skip

    func test_selectFirstAvailable_skipsTabsWithoutSession() {
        let deadTab = Tab(sessionId: nil, kind: .shell, name: "셸")
        let liveSession = UUID()
        let liveTab = Tab(sessionId: liveSession, kind: .claude, name: "Claude")
        let ws = makeWorkspace(name: "A", tabs: [deadTab, liveTab])

        let selection = AgentTreeSelection()
        selection.selectFirstAvailable(workspaces: [ws])

        XCTAssertEqual(selection.selectedTabId, liveTab.id, "sessionId nil tab 은 건너뛰고 첫 live tab 선택")
    }

    // MARK: - selectFirstAvailable: agentView kind 는 순회 제외

    func test_selectFirstAvailable_skipsAgentViewWorkspace() {
        let agentSession = UUID()
        let agentTab = Tab(sessionId: agentSession, kind: .shell, name: "셸")
        let agentView = makeWorkspace(name: "agent", tabs: [agentTab], kind: .agentView)
        let normalSession = UUID()
        let normalTab = Tab(sessionId: normalSession, kind: .claude, name: "Claude")
        let normal = makeWorkspace(name: "normal", tabs: [normalTab])

        let selection = AgentTreeSelection()
        selection.selectFirstAvailable(workspaces: [agentView, normal])

        XCTAssertEqual(selection.selectedTabId, normalTab.id, "agentView 는 제외하고 normal 의 tab 선택")
    }

    // MARK: - selectFirstAvailable: 전부 빈 경우 nil

    func test_selectFirstAvailable_allEmpty_yieldsNil() {
        let selection = AgentTreeSelection()
        selection.selectedTabId = UUID() // 기존 dangling 선택
        selection.selectFirstAvailable(workspaces: [])

        XCTAssertNil(selection.selectedTabId)
    }

    // MARK: - selectFirstAvailable: sessionId 보유 tab 전무 → nil 수렴

    func test_selectFirstAvailable_noSessionTabs_convergesToNil() {
        let danglingId = UUID()
        let deadTab = Tab(sessionId: nil, kind: .shell, name: "셸")
        let ws = makeWorkspace(name: "A", tabs: [deadTab])

        let selection = AgentTreeSelection()
        selection.selectedTabId = danglingId
        selection.selectFirstAvailable(workspaces: [ws])

        XCTAssertNil(selection.selectedTabId, "live tab 이 없으면 dangling 선택이 nil 로 수렴")
    }

    // MARK: - syncFromSidebar: selectedTabId 무변경 + workspace expand

    func test_syncFromSidebar_doesNotMutateSelectedTabId() {
        let preselected = UUID()
        let workspaceId = UUID()
        let selection = AgentTreeSelection()
        selection.selectedTabId = preselected

        let before = selection.selectedTabId
        selection.syncFromSidebar(workspaceId: workspaceId)
        let after = selection.selectedTabId

        XCTAssertEqual(before, after, "syncFromSidebar 호출 전후 selectedTabId 무변경")
        XCTAssertEqual(after, preselected)
        XCTAssertTrue(selection.expandedNodeIds.contains(workspaceId), "해당 workspace 만 expand")
    }
}
