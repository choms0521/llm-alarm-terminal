import XCTest
import Foundation

@MainActor
final class WorkspaceManagerTests: XCTestCase {

    // MARK: - Bootstrap

    func test_bootstrap_emptyStore_addsAgentViewAndDefaultNormalWorkspace() throws {
        let store = try makeTempStore()
        let manager = WorkspaceManager(store: store)

        XCTAssertEqual(manager.workspaces.count, 2, "empty 부팅 시 agent-view + default normal 2개 생성")
        XCTAssertEqual(manager.workspaces.first?.kind, .agentView)
        XCTAssertEqual(manager.workspaces.last?.kind, .normal)
        XCTAssertNotNil(manager.selectedID)
    }

    func test_bootstrap_defaultNormal_usesEnvWorkspaceRoot_orHome() throws {
        setenv("CHAT_TERMINAL_WORKSPACE_ROOT", "/private/tmp/p2-default-root", 1)
        defer { unsetenv("CHAT_TERMINAL_WORKSPACE_ROOT") }
        let store = try makeTempStore()
        let manager = WorkspaceManager(store: store)
        let normal = manager.workspaces.first(where: { $0.kind == .normal })
        XCTAssertEqual(normal?.cwd, "/private/tmp/p2-default-root",
                       "CHAT_TERMINAL_WORKSPACE_ROOT 환경 변수가 default cwd 로 적용됨")
    }

    func test_bootstrap_existingAgentView_doesNotDuplicate() throws {
        let store = try makeTempStore()
        // 의도적으로 agent-view + normal 2 개를 영속화한 후 manager 부팅.
        let preAgent = Workspace.makeAgentView()
        let preNormal = Workspace(name: "기존", cwd: "/tmp/existing", kind: .normal)
        try store.save(WorkspaceFile(
            workspaces: [preAgent, preNormal],
            lastActiveWorkspaceId: preNormal.id
        ))

        let manager = WorkspaceManager(store: store)
        XCTAssertEqual(manager.workspaces.count, 2)
        XCTAssertEqual(manager.workspaces.filter { $0.kind == .agentView }.count, 1,
                       "agent-view 는 정확히 1개")
        XCTAssertEqual(manager.selectedID, preNormal.id, "lastActiveWorkspaceId 가 선택 복원됨")
    }

    // MARK: - addWorkspace / removeWorkspace

    func test_addWorkspace_appendsAndSelects() throws {
        let store = try makeTempStore()
        let manager = WorkspaceManager(store: store)
        let before = manager.workspaces.count

        let added = manager.addWorkspace(cwd: "/tmp/new", name: "새 작업")

        XCTAssertEqual(manager.workspaces.count, before + 1)
        XCTAssertEqual(manager.workspaces.last?.id, added.id)
        XCTAssertEqual(manager.selectedID, added.id)
        XCTAssertEqual(added.kind, .normal)
        XCTAssertFalse(added.envSnapshot.isEmpty,
                       "addWorkspace 시 envSnapshot 이 캡처됨 (H6)")
    }

    func test_removeWorkspace_canCloseNormal() throws {
        let store = try makeTempStore()
        let manager = WorkspaceManager(store: store)
        let normal = manager.addWorkspace(cwd: "/tmp/x", name: "x")
        let before = manager.workspaces.count

        manager.removeWorkspace(id: normal.id)

        XCTAssertEqual(manager.workspaces.count, before - 1)
        XCTAssertFalse(manager.workspaces.contains(where: { $0.id == normal.id }))
    }

    func test_removeWorkspace_refusesAgentView_invariant() throws {
        let store = try makeTempStore()
        let manager = WorkspaceManager(store: store)
        guard let agent = manager.workspaces.first(where: { $0.kind == .agentView }) else {
            XCTFail("agent-view 가 부팅 후 존재해야 함")
            return
        }
        let before = manager.workspaces.count

        manager.removeWorkspace(id: agent.id)

        XCTAssertEqual(manager.workspaces.count, before,
                       "agent-view 제거 시도는 무시되어 갯수 변화 없음 (canClose=false)")
        XCTAssertTrue(manager.workspaces.contains(where: { $0.id == agent.id }))
    }

    // MARK: - Persistence round-trip

    func test_state_persistsAcrossManagerRestart() throws {
        let store = try makeTempStore()
        let m1 = WorkspaceManager(store: store)
        let added = m1.addWorkspace(cwd: "/tmp/persistent", name: "지속")
        m1.select(id: added.id)

        // Same store, new manager → load + select 복원.
        let m2 = WorkspaceManager(store: store)
        XCTAssertTrue(m2.workspaces.contains(where: { $0.id == added.id }))
        XCTAssertEqual(m2.selectedID, added.id)
    }

    // MARK: - Helpers

    private func makeTempStore() throws -> WorkspaceStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceManagerTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try WorkspaceStore(fileURL: dir.appendingPathComponent("workspaces.json"))
    }
}
