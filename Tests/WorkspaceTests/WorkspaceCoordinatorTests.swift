import XCTest
import Foundation

@MainActor
final class WorkspaceCoordinatorTests: XCTestCase {

    // MARK: - addPane / addWorkspace attaches session

    func test_addPane_attachesSessionId_toPane() async throws {
        let (manager, sessionManager) = try makeFixture()
        let coordinator = WorkspaceCoordinator(manager: manager, sessionManager: sessionManager)

        let ws = await coordinator.addWorkspace(cwd: "/tmp/ws1", name: "ws1")
        // default shell pane 이 attach 된 상태로 반환. P3.5 schema v2: sessionId 는 active tab.
        guard let leftPane = ws.panes.first else {
            XCTFail("default pane 부재"); return
        }
        XCTAssertNotNil(leftPane.activeTab?.sessionId, "default pane 의 active tab 에 session id 부착")

        // 추가 pane.
        let added = await coordinator.addPane(workspaceId: ws.id, kind: .claude)
        XCTAssertNotNil(added?.activeTab?.sessionId, "추가 pane 의 active tab 에 session id 부착")
    }

    func test_addWorkspace_attachesSessionForDefaultPane() async throws {
        let (manager, sessionManager) = try makeFixture()
        let coordinator = WorkspaceCoordinator(manager: manager, sessionManager: sessionManager)

        let ws = await coordinator.addWorkspace(cwd: "/tmp/ws-default", name: "default")
        let pane = ws.panes.first
        XCTAssertNotNil(pane?.activeTab?.sessionId)

        // SessionManager 도 동일 sessionId 보유 + workspaceId 가 정합.
        if let sessionId = pane?.activeTab?.sessionId {
            let session = await sessionManager.get(id: sessionId)
            XCTAssertNotNil(session)
            XCTAssertEqual(session?.workspaceId, ws.id)
            XCTAssertEqual(session?.paneId, pane?.id)
            XCTAssertEqual(session?.origin, .internal)
        }
    }

    // MARK: - closePane

    func test_closePane_terminatesSession_andRemovesPaneFromWorkspace() async throws {
        let (manager, sessionManager) = try makeFixture()
        let coordinator = WorkspaceCoordinator(manager: manager, sessionManager: sessionManager)

        let ws = await coordinator.addWorkspace(cwd: "/tmp/ws-close", name: "x")
        guard let pane = ws.panes.first, let sessionId = pane.activeTab?.sessionId else {
            XCTFail("default pane / activeTab.sessionId 부재"); return
        }
        // 두 번째 pane 추가.
        _ = await coordinator.addPane(workspaceId: ws.id, kind: .claude)
        let beforeCount = manager.workspaces.first(where: { $0.id == ws.id })?.panes.count ?? 0
        XCTAssertEqual(beforeCount, 2)

        await coordinator.closePane(workspaceId: ws.id, paneId: pane.id)

        // pane 제거 확인.
        let updated = manager.workspaces.first(where: { $0.id == ws.id })
        XCTAssertEqual(updated?.panes.count, 1)
        XCTAssertFalse(updated?.panes.contains(where: { $0.id == pane.id }) ?? true)

        // session 도 registry 에서 제거(또는 .exited).
        let session = await sessionManager.get(id: sessionId)
        // remove() 호출 후이므로 nil 이어야 한다.
        XCTAssertNil(session, "closePane 후 session registry 에서 제거")

        // 첫 pane(.left) 제거 후 남은 pane 이 .left 으로 승격.
        XCTAssertEqual(updated?.panes.first?.position, .left)
    }

    // MARK: - closeWorkspace

    func test_closeWorkspace_terminatesAllSessions_andRemovesWorkspace() async throws {
        let (manager, sessionManager) = try makeFixture()
        let coordinator = WorkspaceCoordinator(manager: manager, sessionManager: sessionManager)

        let ws = await coordinator.addWorkspace(cwd: "/tmp/ws-bulk", name: "bulk")
        _ = await coordinator.addPane(workspaceId: ws.id, kind: .claude)
        let sessionIdsBefore = await sessionManager.sessionIds(inWorkspace: ws.id)
        XCTAssertEqual(sessionIdsBefore.count, 2,
                       "default shell + 추가 claude = 2 sessions")

        await coordinator.closeWorkspace(id: ws.id)

        XCTAssertFalse(manager.workspaces.contains(where: { $0.id == ws.id }),
                       "workspace 가 제거됨")

        let sessionIdsAfter = await sessionManager.sessionIds(inWorkspace: ws.id)
        XCTAssertTrue(sessionIdsAfter.isEmpty,
                      "workspace 의 모든 session 이 registry 에서 제거됨")
    }

    func test_closeWorkspace_agentView_isRejected() async throws {
        let (manager, sessionManager) = try makeFixture()
        let coordinator = WorkspaceCoordinator(manager: manager, sessionManager: sessionManager)
        guard let agent = manager.workspaces.first(where: { $0.kind == .agentView }) else {
            XCTFail("agent-view 부재"); return
        }
        let beforeCount = manager.workspaces.count

        await coordinator.closeWorkspace(id: agent.id)

        XCTAssertEqual(manager.workspaces.count, beforeCount,
                       "agent-view 는 closeWorkspace 호출에도 제거되지 않음")
    }

    // MARK: - Helpers

    private func makeFixture() throws -> (WorkspaceManager, SessionManager) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceCoordinatorTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try WorkspaceStore(fileURL: dir.appendingPathComponent("workspaces.json"))
        let manager = WorkspaceManager(store: store)
        let sessionManager = SessionManager(maxSessionsOverride: 10)
        return (manager, sessionManager)
    }
}
