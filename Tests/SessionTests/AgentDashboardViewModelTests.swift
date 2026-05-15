import XCTest
import Foundation

@MainActor
final class AgentDashboardViewModelTests: XCTestCase {

    private let fixedDate = Date(timeIntervalSince1970: 1_778_716_800)

    private func makeWorkspaces() -> (workspaces: [Workspace], sessionIds: [UUID], paneIds: [UUID]) {
        var workspaces: [Workspace] = []
        var sessionIds: [UUID] = []
        var paneIds: [UUID] = []
        for wIdx in 0..<3 {
            var panes: [Pane] = []
            let wsId = UUID()
            for pIdx in 0..<2 {
                let sId = UUID()
                let pId = UUID()
                sessionIds.append(sId)
                paneIds.append(pId)
                let tab = Tab(sessionId: sId, kind: .shell, name: Tab.defaultName(for: .shell))
                panes.append(Pane(
                    id: pId,
                    position: pIdx == 0 ? .left : .right,
                    tabs: [tab],
                    activeTabId: tab.id
                ))
            }
            workspaces.append(Workspace(
                id: wsId,
                name: "ws-\(wIdx)",
                cwd: "/tmp",
                panes: panes,
                createdAt: fixedDate,
                kind: .normal
            ))
        }
        return (workspaces, sessionIds, paneIds)
    }

    private func makeSnapshot(sessionId: UUID, at offset: TimeInterval = 0, status: AgentStatus = .working) -> SessionStatusSnapshot {
        SessionStatusSnapshot(
            sessionId: sessionId,
            agentStatus: status,
            latestPreview: "preview",
            lastActivityAt: fixedDate.addingTimeInterval(offset)
        )
    }

    // MARK: - 1. 3 workspace × 2 pane = 6 cards

    func test_refresh_3workspace2pane_yields6Cards() {
        let (workspaces, sessionIds, _) = makeWorkspaces()
        var snapshots: [UUID: SessionStatusSnapshot] = [:]
        for (i, sid) in sessionIds.enumerated() {
            snapshots[sid] = makeSnapshot(sessionId: sid, at: TimeInterval(i))
        }
        let vm = AgentDashboardViewModel()
        let index = SessionIndex(workspaces: workspaces)
        vm.refresh(snapshots: snapshots, workspaces: workspaces, sessionIndex: index)
        XCTAssertEqual(vm.cards.count, 6)
    }

    // MARK: - 2. empty snapshots → empty cards

    func test_refresh_emptySnapshots_yieldsEmptyCards() {
        let (workspaces, _, _) = makeWorkspaces()
        let vm = AgentDashboardViewModel()
        let index = SessionIndex(workspaces: workspaces)
        vm.refresh(snapshots: [:], workspaces: workspaces, sessionIndex: index)
        XCTAssertTrue(vm.cards.isEmpty)
    }

    // MARK: - 3. snapshot 없는 entry 제외

    func test_refresh_partialSnapshots_excludesMissingEntries() {
        let (workspaces, sessionIds, _) = makeWorkspaces()
        var snapshots: [UUID: SessionStatusSnapshot] = [:]
        snapshots[sessionIds[0]] = makeSnapshot(sessionId: sessionIds[0])
        snapshots[sessionIds[3]] = makeSnapshot(sessionId: sessionIds[3])
        let vm = AgentDashboardViewModel()
        let index = SessionIndex(workspaces: workspaces)
        vm.refresh(snapshots: snapshots, workspaces: workspaces, sessionIndex: index)
        XCTAssertEqual(vm.cards.count, 2)
    }

    // MARK: - 4. sort by lastActivityAt desc

    func test_refresh_sortedByLastActivityAtDesc() {
        let (workspaces, sessionIds, _) = makeWorkspaces()
        var snapshots: [UUID: SessionStatusSnapshot] = [:]
        // 의도적으로 sessionIds[2] 가 가장 최근
        snapshots[sessionIds[0]] = makeSnapshot(sessionId: sessionIds[0], at: 0)
        snapshots[sessionIds[1]] = makeSnapshot(sessionId: sessionIds[1], at: 60)
        snapshots[sessionIds[2]] = makeSnapshot(sessionId: sessionIds[2], at: 120)
        let vm = AgentDashboardViewModel()
        let index = SessionIndex(workspaces: workspaces)
        vm.refresh(snapshots: snapshots, workspaces: workspaces, sessionIndex: index)
        XCTAssertEqual(vm.cards.first?.sessionId, sessionIds[2])
        XCTAssertEqual(vm.cards.last?.sessionId, sessionIds[0])
    }

    // MARK: - 5. workspace 누락 → 카드 제외

    func test_refresh_missingWorkspace_excludesCard() {
        let (workspaces, sessionIds, _) = makeWorkspaces()
        var snapshots: [UUID: SessionStatusSnapshot] = [:]
        for sid in sessionIds {
            snapshots[sid] = makeSnapshot(sessionId: sid)
        }
        let vm = AgentDashboardViewModel()
        // workspaces 의 첫번째만 사용 — 2개 카드만 매칭
        let limitedWorkspaces = [workspaces[0]]
        let index = SessionIndex(workspaces: workspaces)  // index 는 6개 entries
        vm.refresh(snapshots: snapshots, workspaces: limitedWorkspaces, sessionIndex: index)
        XCTAssertEqual(vm.cards.count, 2, "workspace 누락 entry 는 제외")
    }

    // MARK: - 6. filterStatus 적용

    func test_refresh_filterStatusNeedsInput_onlyMatching() {
        let (workspaces, sessionIds, _) = makeWorkspaces()
        var snapshots: [UUID: SessionStatusSnapshot] = [:]
        snapshots[sessionIds[0]] = makeSnapshot(sessionId: sessionIds[0], status: .working)
        snapshots[sessionIds[1]] = makeSnapshot(sessionId: sessionIds[1], status: .needsInput)
        snapshots[sessionIds[2]] = makeSnapshot(sessionId: sessionIds[2], status: .needsInput)
        snapshots[sessionIds[3]] = makeSnapshot(sessionId: sessionIds[3], status: .idle)
        let vm = AgentDashboardViewModel()
        vm.filterStatus = .needsInput
        let index = SessionIndex(workspaces: workspaces)
        vm.refresh(snapshots: snapshots, workspaces: workspaces, sessionIndex: index)
        XCTAssertEqual(vm.cards.count, 2)
        XCTAssertTrue(vm.cards.allSatisfy { $0.snapshot.agentStatus == .needsInput })
    }

    // MARK: - 7. AgentStatusBadge 한국어 라벨 4종 (종료 조건 9)

    func test_agentStatusBadge_koreanLabels() {
        XCTAssertEqual(AgentStatusBadge.label(for: .idle), "활성")
        XCTAssertEqual(AgentStatusBadge.label(for: .working), "작업 중")
        XCTAssertEqual(AgentStatusBadge.label(for: .needsInput), "입력 필요")
        XCTAssertEqual(AgentStatusBadge.label(for: .exited), "종료됨")
    }
}
