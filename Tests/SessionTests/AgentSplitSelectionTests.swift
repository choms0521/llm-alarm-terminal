import XCTest
import Foundation

/// AgentSplitView 의 dangling 선택 수렴(A11)을 SwiftUI 비의존 순수 로직 레벨에서
/// 검증한다. AgentSplitView 자체는 GhosttyKit 의존(앱 타겟 전용)이라 단위 테스트
/// 대상이 아니므로, 수렴 로직을 `AgentTreeSelection.reconcile` 로 추출하여 측정한다.
///
/// 핵심: 선택 tab 이 workspaces 에서 제거되면 reconcile 이 selectFirstAvailable 을
/// 호출해 유효 tab 또는 nil 로 수렴한다. 여전히 존재하면 무변경.
@MainActor
final class AgentSplitSelectionTests: XCTestCase {

    private let fixedDate = Date(timeIntervalSince1970: 1_778_716_800)

    private func makeWorkspace(
        name: String,
        tabs: [Tab],
        kind: WorkspaceKind = .normal
    ) -> Workspace {
        let pane = Pane(position: .left, tabs: tabs, activeTabId: tabs.first?.id)
        return Workspace(name: name, cwd: "/tmp", panes: [pane], createdAt: fixedDate, kind: kind)
    }

    // MARK: - reconcile: 선택 tab 이 제거되면 다른 유효 tab 으로 수렴

    func test_reconcile_danglingSelection_convergesToValidTab() {
        let removedTab = Tab(sessionId: UUID(), kind: .claude, name: "Claude")
        let survivingSession = UUID()
        let survivingTab = Tab(sessionId: survivingSession, kind: .shell, name: "셸")
        let wsBefore = makeWorkspace(name: "A", tabs: [removedTab, survivingTab])

        let selection = AgentTreeSelection()
        selection.selectedTabId = removedTab.id

        // removedTab 이 사라진 새 workspaces
        let wsAfter = makeWorkspace(name: "A", tabs: [survivingTab])
        selection.reconcile(workspaces: [wsAfter])

        XCTAssertEqual(selection.selectedTabId, survivingTab.id,
                       "제거된 선택 tab 은 살아남은 유효 tab 으로 수렴")
        _ = wsBefore
    }

    // MARK: - reconcile: 선택 tab 이 제거되고 유효 tab 전무 → nil 수렴

    func test_reconcile_danglingSelection_noValidTab_convergesToNil() {
        let removedTab = Tab(sessionId: UUID(), kind: .claude, name: "Claude")
        let selection = AgentTreeSelection()
        selection.selectedTabId = removedTab.id

        // 모든 normal workspace 가 사라짐
        selection.reconcile(workspaces: [])

        XCTAssertNil(selection.selectedTabId, "유효 tab 이 없으면 nil 로 수렴")
    }

    // MARK: - reconcile: 선택 tab 이 여전히 존재하면 무변경

    func test_reconcile_validSelection_remainsUnchanged() {
        let keepSession = UUID()
        let keepTab = Tab(sessionId: keepSession, kind: .claude, name: "Claude")
        let otherTab = Tab(sessionId: UUID(), kind: .shell, name: "셸")
        let ws = makeWorkspace(name: "A", tabs: [otherTab, keepTab])

        let selection = AgentTreeSelection()
        selection.selectedTabId = keepTab.id
        selection.reconcile(workspaces: [ws])

        XCTAssertEqual(selection.selectedTabId, keepTab.id,
                       "존재하는 선택은 reconcile 후에도 무변경(첫 tab 으로 점프하지 않음)")
    }

    // MARK: - reconcile: nil 선택 + 유효 tab 존재 → 첫 tab 으로 수렴

    func test_reconcile_nilSelection_picksFirstAvailable() {
        let firstSession = UUID()
        let firstTab = Tab(sessionId: firstSession, kind: .claude, name: "Claude")
        let ws = makeWorkspace(name: "A", tabs: [firstTab])

        let selection = AgentTreeSelection()
        XCTAssertNil(selection.selectedTabId)
        selection.reconcile(workspaces: [ws])

        XCTAssertEqual(selection.selectedTabId, firstTab.id)
    }

    // MARK: - reconcile: lazy 탭(sessionId nil)도 dangling 판정에서 존재로 인정

    func test_reconcile_lazyTabSelection_remainsUnchanged() {
        // sessionId 가 nil 인 lazy 탭을 선택한 상태에서도, 트리에 그 tabId 가 있으면
        // reconcile 은 무변경(우측 호스트가 클릭 시 신규 spawn 하므로 유효 선택).
        let lazyTab = Tab(sessionId: nil, kind: .shell, name: "셸")
        let liveTab = Tab(sessionId: UUID(), kind: .claude, name: "Claude")
        let ws = makeWorkspace(name: "A", tabs: [liveTab, lazyTab])

        let selection = AgentTreeSelection()
        selection.selectedTabId = lazyTab.id
        selection.reconcile(workspaces: [ws])

        XCTAssertEqual(selection.selectedTabId, lazyTab.id,
                       "lazy 탭도 트리에 존재하므로 dangling 이 아니다(무변경)")
    }

    // MARK: - containsTab: normal workspace 의 tab 만 인정

    func test_containsTab_onlyMatchesNormalWorkspaceTabs() {
        let normalTab = Tab(sessionId: UUID(), kind: .claude, name: "Claude")
        let agentTab = Tab(sessionId: UUID(), kind: .shell, name: "셸")
        let normal = makeWorkspace(name: "n", tabs: [normalTab])
        let agentView = makeWorkspace(name: "a", tabs: [agentTab], kind: .agentView)

        XCTAssertTrue(AgentTreeSelection.containsTab(normalTab.id, in: [normal, agentView]))
        XCTAssertFalse(AgentTreeSelection.containsTab(agentTab.id, in: [normal, agentView]),
                       "agentView kind 의 tab 은 트리에 없으므로 false")
        XCTAssertFalse(AgentTreeSelection.containsTab(UUID(), in: [normal, agentView]),
                       "미등록 tabId 는 false")
    }
}
