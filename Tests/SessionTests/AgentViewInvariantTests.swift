import XCTest
import Foundation

@MainActor
final class AgentViewInvariantTests: XCTestCase {

    private let baseDate = Date(timeIntervalSince1970: 1_778_716_800)

    // MARK: - 1. agent-view 워크스페이스는 close 불가 (P2 invariant)

    func test_agentView_canCloseIsFalse() {
        let ws = Workspace.makeAgentView()
        XCTAssertFalse(ws.canClose)
    }

    func test_normalWorkspace_canCloseIsTrue() {
        let ws = Workspace(name: "test", cwd: "/tmp", kind: .normal)
        XCTAssertTrue(ws.canClose)
    }

    // MARK: - 2. WorkspaceFile.dedupAgentViews 가 단일 보장

    func test_dedupAgentViews_keepsSingleAgentView() {
        let av1 = Workspace.makeAgentView()
        let av2 = Workspace.makeAgentView()
        let normal = Workspace(name: "test", cwd: "/tmp", kind: .normal)
        let file = WorkspaceFile(
            version: 1,
            workspaces: [av1, av2, normal],
            lastActiveWorkspaceId: nil
        )
        let dedup = file.dedupAgentViews()
        XCTAssertEqual(dedup.workspaces.filter { $0.kind == .agentView }.count, 1)
    }

    // MARK: - 3. 점프 100회 후 agent-view 1개 보존 invariant

    func test_jump100times_preservesAgentViewInvariant() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-day6-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileURL = tempDir.appendingPathComponent("workspaces.json")

        var normals: [Workspace] = []
        var sessionIds: [UUID] = []
        for wIdx in 0..<2 {
            let sId = UUID()
            sessionIds.append(sId)
            normals.append(Workspace(
                name: "ws-\(wIdx)",
                cwd: "/tmp",
                panes: { let tab = Tab(sessionId: sId, kind: .shell, name: "셸"); return [Pane(position: .left, tabs: [tab], activeTabId: tab.id)] }(),
                createdAt: baseDate,
                kind: .normal
            ))
        }
        let file = WorkspaceFile(
            version: 1,
            workspaces: [Workspace.makeAgentView(createdAt: baseDate)] + normals,
            lastActiveWorkspaceId: normals[0].id
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(file).write(to: fileURL)

        let store = try WorkspaceStore(fileURL: fileURL)
        let manager = WorkspaceManager(store: store)
        let registry = SurfaceRegistry()
        let focusedPaneStore = FocusedPaneStore()
        let action = AgentJumpAction(
            manager: manager,
            focusedPaneStore: focusedPaneStore,
            surfaceRegistry: registry,
            handler: AgentJumpAction.DefaultHandler()
        )

        let index = SessionIndex(workspaces: normals)
        let snap = SessionStatusSnapshot(
            sessionId: sessionIds[0],
            agentStatus: .working,
            latestPreview: "x",
            lastActivityAt: baseDate
        )
        for _ in 0..<100 {
            action.jump(snapshot: snap, snapshotIndex: index)
        }
        let agentCount = manager.workspaces.filter { $0.kind == .agentView }.count
        XCTAssertEqual(agentCount, 1, "agent-view invariant 보존")
        let agent = manager.workspaces.first { $0.kind == .agentView }!
        XCTAssertFalse(agent.canClose)
    }

    // MARK: - 4. SessionStatus enum P1/P2 그대로 유지 invariant

    func test_sessionStatus_caseOrder() {
        XCTAssertEqual(SessionStatus.running.rawValue, "running")
        XCTAssertEqual(SessionStatus.exited.rawValue, "exited")
        // AgentStatus 와 별도 enum 임을 확인.
        XCTAssertNotEqual(SessionStatus.running.rawValue, AgentStatus.idle.rawValue)
    }

    // MARK: - 5. updateAgentViewExtraFields 영속화 + 재로드 보존

    func test_updateAgentViewExtraFields_persistsAcrossReload() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-day6-persist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileURL = tempDir.appendingPathComponent("workspaces.json")

        let agentView = Workspace.makeAgentView(createdAt: baseDate)
        let normal = Workspace(name: "test", cwd: "/tmp", kind: .normal)
        let file = WorkspaceFile(
            version: 1,
            workspaces: [agentView, normal],
            lastActiveWorkspaceId: normal.id
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(file).write(to: fileURL)

        // 1차 manager: settings 갱신
        let store1 = try WorkspaceStore(fileURL: fileURL)
        let manager1 = WorkspaceManager(store: store1)
        let settings = AgentViewSettings(sortOrder: .statusFirst, filter: .needsInput)
        let merged = settings.encoded(merging: manager1.agentViewExtraFields())
        manager1.updateAgentViewExtraFields(merged)

        // 2차 manager: 동일 파일 재로드
        let store2 = try WorkspaceStore(fileURL: fileURL)
        let manager2 = WorkspaceManager(store: store2)
        let restored = AgentViewSettings.decode(from: manager2.agentViewExtraFields())
        XCTAssertEqual(restored.sortOrder, .statusFirst)
        XCTAssertEqual(restored.filter, .needsInput)
    }
}
