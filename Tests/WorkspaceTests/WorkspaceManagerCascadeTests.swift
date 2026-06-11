import XCTest
import AppKit
import Foundation

/// P3.5 Day 3 (REQ-2/REQ-4): Tab API(addTab/selectTab/closeTab) + 자동 정리 cascade 검증.
///
/// 모델 cascade(tab → pane → workspace 제거)는 `WorkspaceManager` 순수 메서드로,
/// session terminate / surface release 는 `WorkspaceCoordinator` 래퍼로 검증한다.
@MainActor
final class WorkspaceManagerCascadeTests: XCTestCase {

    // MARK: - addTab / selectTab (모델)

    func test_addTab_appendsTab_andActivatesIt() throws {
        let manager = try makeManager()
        let ws = manager.addWorkspace(cwd: "/tmp/cas-add", name: "add")
        guard let pane = ws.panes.first else { return XCTFail("default pane 부재") }
        let before = pane.tabs.count

        let added = manager.addTab(workspaceId: ws.id, paneId: pane.id, kind: .claude)

        let updated = manager.workspaces.first(where: { $0.id == ws.id })?.panes.first(where: { $0.id == pane.id })
        XCTAssertNotNil(added)
        XCTAssertEqual(updated?.tabs.count, before + 1, "탭이 1개 추가됨")
        XCTAssertEqual(updated?.activeTabId, added?.id, "추가된 탭이 활성탭으로 설정됨")
        XCTAssertEqual(updated?.tabs.last?.kind, .claude)
    }

    func test_addTab_onAgentView_returnsNil() throws {
        let manager = try makeManager()
        guard let agent = manager.workspaces.first(where: { $0.kind == .agentView }) else {
            return XCTFail("agent-view 부재")
        }
        let result = manager.addTab(workspaceId: agent.id, paneId: UUID(), kind: .shell)
        XCTAssertNil(result, "agent-view 에는 탭 추가 불가")
    }

    func test_selectTab_changesActiveTabId() throws {
        let manager = try makeManager()
        let ws = manager.addWorkspace(cwd: "/tmp/cas-sel", name: "sel")
        guard let pane = ws.panes.first, let firstTab = pane.tabs.first else { return XCTFail() }
        let second = manager.addTab(workspaceId: ws.id, paneId: pane.id, kind: .shell)!
        // addTab 이 second 를 활성화했으므로 다시 first 로 전환.
        manager.selectTab(workspaceId: ws.id, paneId: pane.id, tabId: firstTab.id)

        let active = manager.workspaces.first(where: { $0.id == ws.id })?
            .panes.first(where: { $0.id == pane.id })?.activeTabId
        XCTAssertEqual(active, firstTab.id)
        XCTAssertNotEqual(active, second.id)
    }

    // MARK: - closeTab cascade (모델)

    func test_closeTab_withMultipleTabs_removesOnlyTab_paneSurvives() throws {
        let manager = try makeManager()
        let ws = manager.addWorkspace(cwd: "/tmp/cas-multi", name: "multi")
        guard let pane = ws.panes.first, let firstTab = pane.tabs.first else { return XCTFail() }
        let second = manager.addTab(workspaceId: ws.id, paneId: pane.id, kind: .claude)!

        manager.closeTab(workspaceId: ws.id, paneId: pane.id, tabId: second.id)

        let updated = manager.workspaces.first(where: { $0.id == ws.id })
        XCTAssertEqual(updated?.panes.count, 1, "pane 은 유지 (cascade 미발동)")
        XCTAssertEqual(updated?.panes.first?.tabs.count, 1, "탭만 1개 제거")
        XCTAssertEqual(updated?.panes.first?.tabs.first?.id, firstTab.id)
    }

    func test_closeTab_activeTab_movesActiveToRemaining() throws {
        let manager = try makeManager()
        let ws = manager.addWorkspace(cwd: "/tmp/cas-active", name: "active")
        guard let pane = ws.panes.first, let firstTab = pane.tabs.first else { return XCTFail() }
        let second = manager.addTab(workspaceId: ws.id, paneId: pane.id, kind: .claude)!
        // 현재 활성 = second. 활성 탭을 닫으면 활성이 남은 first 로 이동해야 한다.
        manager.closeTab(workspaceId: ws.id, paneId: pane.id, tabId: second.id)

        let updated = manager.workspaces.first(where: { $0.id == ws.id })?.panes.first
        XCTAssertEqual(updated?.activeTabId, firstTab.id, "활성 탭 close 후 남은 탭이 활성")
    }

    func test_closeTab_lastTabInPane_cascadeRemovesPane() throws {
        let manager = try makeManager()
        let ws = manager.addWorkspace(cwd: "/tmp/cas-pane", name: "pane")
        // 두 번째 pane 추가(.right).
        let rightPane = manager.addPane(workspaceId: ws.id, kind: .claude, position: .right)!
        XCTAssertEqual(manager.workspaces.first(where: { $0.id == ws.id })?.panes.count, 2)
        guard let onlyTab = rightPane.tabs.first else { return XCTFail() }

        manager.closeTab(workspaceId: ws.id, paneId: rightPane.id, tabId: onlyTab.id)

        let updated = manager.workspaces.first(where: { $0.id == ws.id })
        XCTAssertEqual(updated?.panes.count, 1, "마지막 탭 close → pane 제거 (cascade)")
        XCTAssertFalse(updated?.panes.contains(where: { $0.id == rightPane.id }) ?? true)
    }

    func test_closeTab_lastTab_leftPane_promotesRightToLeft() throws {
        let manager = try makeManager()
        let ws = manager.addWorkspace(cwd: "/tmp/cas-promote", name: "promote")
        guard let leftPane = ws.panes.first, let leftTab = leftPane.tabs.first else { return XCTFail() }
        let rightPane = manager.addPane(workspaceId: ws.id, kind: .claude, position: .right)!

        // .left pane 의 마지막 탭 close → .left pane 제거 → .right 이 .left 으로 승격.
        manager.closeTab(workspaceId: ws.id, paneId: leftPane.id, tabId: leftTab.id)

        let updated = manager.workspaces.first(where: { $0.id == ws.id })
        XCTAssertEqual(updated?.panes.count, 1)
        XCTAssertEqual(updated?.panes.first?.id, rightPane.id, "남은 pane 은 우측 pane")
        XCTAssertEqual(updated?.panes.first?.position, .left, ".right → .left 승격")
    }

    func test_closeTab_lastTabOfLastPane_cascadeRemovesWorkspace() throws {
        let manager = try makeManager()
        let ws = manager.addWorkspace(cwd: "/tmp/cas-ws", name: "ws")
        guard let pane = ws.panes.first, let tab = pane.tabs.first else { return XCTFail() }
        let agentBefore = manager.workspaces.filter { $0.kind == .agentView }.count

        manager.closeTab(workspaceId: ws.id, paneId: pane.id, tabId: tab.id)

        XCTAssertNil(manager.workspaces.first(where: { $0.id == ws.id }),
                     "마지막 pane 의 마지막 탭 close → workspace 제거 (cascade)")
        XCTAssertEqual(manager.workspaces.filter { $0.kind == .agentView }.count, agentBefore,
                       "agent-view 는 cascade 영향 없음")
    }

    func test_closeTab_agentView_isNoop_andNeverRemovesAgentView() throws {
        let manager = try makeManager()
        guard let agent = manager.workspaces.first(where: { $0.kind == .agentView }) else {
            return XCTFail("agent-view 부재")
        }
        let beforeCount = manager.workspaces.count

        // agent-view 는 panes 가 없으므로 closeTab 은 guard 에서 조기 반환.
        manager.closeTab(workspaceId: agent.id, paneId: UUID(), tabId: UUID())

        XCTAssertEqual(manager.workspaces.count, beforeCount, "변화 없음")
        XCTAssertNotNil(manager.workspaces.first(where: { $0.id == agent.id }), "agent-view 보존")
    }

    // MARK: - Coordinator: session terminate + surface release

    func test_coordinator_addTab_createsSession_andAssignsToTab() async throws {
        let (manager, sessionManager, registry) = try makeCoordinatorFixture()
        let coordinator = WorkspaceCoordinator(
            manager: manager, sessionManager: sessionManager, surfaceRegistry: registry
        )
        let ws = await coordinator.addWorkspace(cwd: "/tmp/cas-co-add", name: "co-add")
        guard let pane = ws.panes.first else { return XCTFail() }

        let tab = await coordinator.addTab(workspaceId: ws.id, paneId: pane.id, kind: .claude)

        XCTAssertNotNil(tab?.sessionId, "addTab 후 탭에 session id 부착")
        if let sid = tab?.sessionId {
            let session = await sessionManager.get(id: sid)
            XCTAssertNotNil(session, "SessionManager 에 session 레코드 존재")
            XCTAssertEqual(session?.workspaceId, ws.id)
            XCTAssertEqual(session?.paneId, pane.id)
        }
    }

    func test_coordinator_closeTab_terminatesSession_andReleasesSurface() async throws {
        let (manager, sessionManager, registry) = try makeCoordinatorFixture()
        let coordinator = WorkspaceCoordinator(
            manager: manager, sessionManager: sessionManager, surfaceRegistry: registry
        )
        let ws = await coordinator.addWorkspace(cwd: "/tmp/cas-co-close", name: "co-close")
        guard let pane = ws.panes.first else { return XCTFail() }
        // 두 번째 탭 추가 후 그 탭을 닫음(첫 탭은 남으므로 cascade 미발동).
        let tab = await coordinator.addTab(workspaceId: ws.id, paneId: pane.id, kind: .claude)
        guard let tab, let sid = tab.sessionId else { return XCTFail("탭/세션 부재") }
        // surface mount 를 흉내내어 registry 에 더미 surface 등록.
        _ = registry.acquire(id: tab.id) { NSView(frame: .zero) }
        XCTAssertTrue(registry.contains(id: tab.id))

        await coordinator.closeTab(workspaceId: ws.id, paneId: pane.id, tabId: tab.id)

        let session = await sessionManager.get(id: sid)
        XCTAssertNil(session, "closeTab 후 session 제거")
        XCTAssertFalse(registry.contains(id: tab.id), "closeTab 후 해당 탭 surface release")
        // 첫 탭은 남아 pane 유지(cascade 미발동).
        XCTAssertEqual(manager.workspaces.first(where: { $0.id == ws.id })?.panes.first?.tabs.count, 1)
    }

    // MARK: - Fixtures

    private func makeManager() throws -> WorkspaceManager {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceCascadeTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try WorkspaceStore(fileURL: dir.appendingPathComponent("workspaces.json"))
        return WorkspaceManager(store: store)
    }

    private func makeCoordinatorFixture() throws -> (WorkspaceManager, SessionManager, SurfaceRegistry) {
        let manager = try makeManager()
        let sessionManager = SessionManager(maxSessionsOverride: 20)
        return (manager, sessionManager, SurfaceRegistry())
    }
}
