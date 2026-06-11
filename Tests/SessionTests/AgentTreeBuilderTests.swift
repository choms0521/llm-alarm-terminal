import XCTest
import Foundation

/// AgentTreeBuilder 순수 함수의 정방향 join 을 전수 검증한다.
/// 빈/단일/다중/agentView제외/sessionId nil 포함/status join 케이스를 측정한다.
final class AgentTreeBuilderTests: XCTestCase {

    private let fixedDate = Date(timeIntervalSince1970: 1_778_716_800)

    private func makeSnapshot(
        sessionId: UUID,
        status: AgentStatus = .working
    ) -> SessionStatusSnapshot {
        SessionStatusSnapshot(
            sessionId: sessionId,
            agentStatus: status,
            latestPreview: "preview",
            lastActivityAt: fixedDate
        )
    }

    // MARK: - (a) 빈 workspaces → 빈 트리

    func test_build_emptyWorkspaces_yieldsEmptyTree() {
        let nodes = AgentTreeBuilder.build(workspaces: [], snapshots: [:])
        XCTAssertTrue(nodes.isEmpty)
    }

    // MARK: - (b) 1 ws / 1 pane / 2 tabs → 1 + 1 + 2 노드

    func test_build_oneWorkspaceOnePaneTwoTabs_yieldsNestedStructure() {
        let s1 = UUID()
        let s2 = UUID()
        let tab1 = Tab(sessionId: s1, kind: .claude, name: "Claude")
        let tab2 = Tab(sessionId: s2, kind: .shell, name: "셸")
        let pane = Pane(position: .left, tabs: [tab1, tab2], activeTabId: tab1.id)
        let ws = Workspace(name: "ws-0", cwd: "/tmp", panes: [pane], createdAt: fixedDate, kind: .normal)

        let nodes = AgentTreeBuilder.build(
            workspaces: [ws],
            snapshots: [s1: makeSnapshot(sessionId: s1), s2: makeSnapshot(sessionId: s2)]
        )

        XCTAssertEqual(nodes.count, 1, "workspace 노드 1개")
        let wsChildren = nodes[0].children
        XCTAssertEqual(wsChildren?.count, 1, "pane 노드 1개")
        let paneChildren = wsChildren?[0].children
        XCTAssertEqual(paneChildren?.count, 2, "tab leaf 2개")

        // workspace/pane 노드는 선택 불가, tab leaf 만 선택 가능
        XCTAssertNil(nodes[0].selectableTabId)
        XCTAssertNil(wsChildren?[0].selectableTabId)
        XCTAssertEqual(paneChildren?[0].selectableTabId, tab1.id)
        XCTAssertEqual(paneChildren?[1].selectableTabId, tab2.id)

        // tab leaf 는 children 이 nil
        XCTAssertNil(paneChildren?[0].children)
    }

    // MARK: - (c) sessionId nil tab 도 노드로 포함되되 snapshot 은 nil

    func test_build_tabWithNilSessionId_includedAsNodeWithoutSnapshot() {
        let live = UUID()
        let liveTab = Tab(sessionId: live, kind: .claude, name: "Claude")
        let deadTab = Tab(sessionId: nil, kind: .shell, name: "셸")
        let pane = Pane(position: .left, tabs: [liveTab, deadTab], activeTabId: liveTab.id)
        let ws = Workspace(name: "ws-0", cwd: "/tmp", panes: [pane], createdAt: fixedDate, kind: .normal)

        let nodes = AgentTreeBuilder.build(
            workspaces: [ws],
            snapshots: [live: makeSnapshot(sessionId: live)]
        )

        let tabNodes = nodes[0].children?[0].children
        XCTAssertEqual(tabNodes?.count, 2, "sessionId nil tab 도 노드로 포함")

        // 정방향 순회 전수: live tab 은 snapshot join, dead tab 은 snapshot nil
        guard case let .tab(_, liveSession, _, _, liveSnap) = tabNodes![0] else {
            return XCTFail("첫 노드는 tab case")
        }
        XCTAssertEqual(liveSession, live)
        XCTAssertEqual(liveSnap?.agentStatus, .working)

        guard case let .tab(_, deadSession, _, _, deadSnap) = tabNodes![1] else {
            return XCTFail("둘째 노드는 tab case")
        }
        XCTAssertNil(deadSession)
        XCTAssertNil(deadSnap, "sessionId nil → snapshot lookup 없이 nil")
    }

    // MARK: - (d) agentView kind workspace 제외

    func test_build_agentViewWorkspace_excludedFromTree() {
        let agentView = Workspace.makeAgentView()
        let s1 = UUID()
        let tab = Tab(sessionId: s1, kind: .shell, name: "셸")
        let pane = Pane(position: .left, tabs: [tab], activeTabId: tab.id)
        let normal = Workspace(name: "ws-0", cwd: "/tmp", panes: [pane], createdAt: fixedDate, kind: .normal)

        let nodes = AgentTreeBuilder.build(
            workspaces: [agentView, normal],
            snapshots: [s1: makeSnapshot(sessionId: s1)]
        )

        XCTAssertEqual(nodes.count, 1, "agentView 제외 후 normal 1개만")
        XCTAssertEqual(nodes[0].id, normal.id)
    }

    // MARK: - workspace 추가순 정렬 보존

    func test_build_preservesWorkspaceInsertionOrder() {
        let wsA = Workspace(name: "A", cwd: "/tmp", panes: [], createdAt: fixedDate, kind: .normal)
        let wsB = Workspace(name: "B", cwd: "/tmp", panes: [], createdAt: fixedDate, kind: .normal)
        let wsC = Workspace(name: "C", cwd: "/tmp", panes: [], createdAt: fixedDate, kind: .normal)

        let nodes = AgentTreeBuilder.build(workspaces: [wsC, wsA, wsB], snapshots: [:])

        XCTAssertEqual(nodes.map(\.id), [wsC.id, wsA.id, wsB.id])
    }

    // MARK: - status join: snapshot 미존재 sessionId 는 snapshot nil

    func test_build_sessionIdWithoutSnapshot_yieldsNilSnapshot() {
        let s1 = UUID()
        let tab = Tab(sessionId: s1, kind: .claude, name: "Claude")
        let pane = Pane(position: .left, tabs: [tab], activeTabId: tab.id)
        let ws = Workspace(name: "ws-0", cwd: "/tmp", panes: [pane], createdAt: fixedDate, kind: .normal)

        let nodes = AgentTreeBuilder.build(workspaces: [ws], snapshots: [:])

        guard case let .tab(_, _, _, _, snap) = nodes[0].children![0].children![0] else {
            return XCTFail("tab case 기대")
        }
        XCTAssertNil(snap, "snapshots dict 에 없는 sessionId → snapshot nil")
    }
}
