import XCTest
import Foundation

final class SessionIndexTests: XCTestCase {

    private let fixedDate = Date(timeIntervalSince1970: 1_778_716_800)

    /// workspace 3개 × pane 2개 = 6 session 시나리오로 SessionIndex 를 빌드한다.
    /// 각 pane 에는 고유 sessionId 가 부여된다.
    private func makeFixture() -> (workspaces: [Workspace], sessionIds: [UUID], paneIds: [UUID], workspaceIds: [UUID]) {
        var sessionIds: [UUID] = []
        var paneIds: [UUID] = []
        var workspaceIds: [UUID] = []
        var workspaces: [Workspace] = []
        for wIdx in 0..<3 {
            var panes: [Pane] = []
            let wsId = UUID()
            workspaceIds.append(wsId)
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
        return (workspaces, sessionIds, paneIds, workspaceIds)
    }

    // MARK: - 1. workspace 3 × pane 2 = 6 정확 매핑

    func test_locate_workspace3_pane2_6sessions_allMatched() {
        let fixture = makeFixture()
        let index = SessionIndex(workspaces: fixture.workspaces)
        XCTAssertEqual(index.size, 6)
        for (i, sId) in fixture.sessionIds.enumerated() {
            let entry = index.locate(sessionId: sId)
            XCTAssertNotNil(entry, "session \(i) 매칭 실패")
            XCTAssertEqual(entry?.sessionId, sId)
            XCTAssertEqual(entry?.paneId, fixture.paneIds[i])
            XCTAssertEqual(entry?.workspaceId, fixture.workspaceIds[i / 2])
        }
    }

    // MARK: - 2. miss → nil

    func test_locate_missingSessionId_returnsNil() {
        let fixture = makeFixture()
        let index = SessionIndex(workspaces: fixture.workspaces)
        XCTAssertNil(index.locate(sessionId: UUID()))
    }

    // MARK: - 3. size 정합

    func test_size_equalsRegisteredEntryCount() {
        let fixture = makeFixture()
        let index = SessionIndex(workspaces: fixture.workspaces)
        XCTAssertEqual(index.size, 6)
        XCTAssertEqual(index.entries.count, 6)
    }

    // MARK: - 4. empty workspaces

    func test_emptyWorkspaces_isEmpty() {
        let index = SessionIndex(workspaces: [])
        XCTAssertTrue(index.isEmpty)
        XCTAssertEqual(index.size, 0)
        XCTAssertNil(index.locate(sessionId: UUID()))
    }

    // MARK: - 5. tab.sessionId nil 제외 (P3.5 schema v2)

    func test_paneWithNilSessionId_excludedFromIndex() {
        let tabNil = Tab(sessionId: nil, kind: .claude, name: "Claude")
        let tabHas = Tab(sessionId: UUID(), kind: .shell, name: "셸")
        let pNil = Pane(position: .left, tabs: [tabNil], activeTabId: tabNil.id)
        let pHas = Pane(position: .right, tabs: [tabHas], activeTabId: tabHas.id)
        let ws = Workspace(
            name: "ws",
            cwd: "/tmp",
            panes: [pNil, pHas],
            createdAt: fixedDate,
            kind: .normal
        )
        let index = SessionIndex(workspaces: [ws])
        XCTAssertEqual(index.size, 1)
        XCTAssertNotNil(index.locate(sessionId: tabHas.sessionId!))
    }

    // MARK: - 6. workspace 가 비어 있는 경우 (panes == [])

    func test_workspaceWithNoPanes_excludedFromIndex() {
        let ws = Workspace.makeAgentView(id: UUID(), createdAt: fixedDate)
        let index = SessionIndex(workspaces: [ws])
        XCTAssertTrue(index.isEmpty)
    }

    // MARK: - 7. Equatable

    func test_equatable_sameWorkspaces_producesEqualIndex() {
        let fixture = makeFixture()
        let a = SessionIndex(workspaces: fixture.workspaces)
        let b = SessionIndex(workspaces: fixture.workspaces)
        XCTAssertEqual(a, b)
    }
}
