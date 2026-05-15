import XCTest
import AppKit
import Foundation

@MainActor
final class MockFirstResponderHandler: AgentJumpAction.Handler {
    var callCount: Int = 0
    var lastView: NSView?
    func makeFirstResponder(_ view: NSView) -> Bool {
        callCount += 1
        lastView = view
        return true
    }
}

@MainActor
final class AgentJumpActionTests: XCTestCase {

    private let fixedDate = Date(timeIntervalSince1970: 1_778_716_800)

    private struct Bundle {
        let action: AgentJumpAction
        let handler: MockFirstResponderHandler
        let manager: WorkspaceManager
        let focusedPaneStore: FocusedPaneStore
        let registry: SurfaceRegistry
        let normalWorkspaces: [Workspace]
        let sessionIds: [UUID]
        let paneIds: [UUID]
        let workspaceIds: [UUID]
        let views: [UUID: NSView]
        let tempDir: URL
    }

    private func makeBundle() throws -> Bundle {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3-day5-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("workspaces.json")

        var workspaceIds: [UUID] = []
        var sessionIds: [UUID] = []
        var paneIds: [UUID] = []
        var normalWorkspaces: [Workspace] = []
        for wIdx in 0..<3 {
            let wsId = UUID()
            workspaceIds.append(wsId)
            var panes: [Pane] = []
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
            normalWorkspaces.append(Workspace(
                id: wsId,
                name: "ws-\(wIdx)",
                cwd: "/tmp",
                panes: panes,
                createdAt: fixedDate,
                kind: .normal
            ))
        }
        let agentView = Workspace.makeAgentView(createdAt: fixedDate)
        let file = WorkspaceFile(
            version: 1,
            workspaces: [agentView] + normalWorkspaces,
            lastActiveWorkspaceId: normalWorkspaces[0].id
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(file)
        try data.write(to: fileURL)

        let store = try WorkspaceStore(fileURL: fileURL)
        let manager = WorkspaceManager(store: store)

        let registry = SurfaceRegistry()
        var views: [UUID: NSView] = [:]
        for pid in paneIds {
            let v = NSView(frame: .zero)
            _ = registry.acquire(paneId: pid) { v }
            views[pid] = v
        }

        let handler = MockFirstResponderHandler()
        let focusedPaneStore = FocusedPaneStore()
        let action = AgentJumpAction(
            manager: manager,
            focusedPaneStore: focusedPaneStore,
            surfaceRegistry: registry,
            handler: handler
        )

        return Bundle(
            action: action,
            handler: handler,
            manager: manager,
            focusedPaneStore: focusedPaneStore,
            registry: registry,
            normalWorkspaces: normalWorkspaces,
            sessionIds: sessionIds,
            paneIds: paneIds,
            workspaceIds: workspaceIds,
            views: views,
            tempDir: tempDir
        )
    }

    private func cleanup(_ tempDir: URL) {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func snapshot(for sid: UUID) -> SessionStatusSnapshot {
        SessionStatusSnapshot(
            sessionId: sid,
            agentStatus: .working,
            latestPreview: "test",
            lastActivityAt: fixedDate
        )
    }

    // MARK: - 1. jump → manager.selectedID 갱신

    func test_jump_setsSelectedID() throws {
        let b = try makeBundle()
        defer { cleanup(b.tempDir) }
        let index = SessionIndex(workspaces: b.normalWorkspaces)
        b.action.jump(snapshot: snapshot(for: b.sessionIds[2]), snapshotIndex: index)
        XCTAssertEqual(b.manager.selectedID, b.workspaceIds[1])
    }

    // MARK: - 2. jump → focusedPaneStore 갱신

    func test_jump_setsFocusedPane() throws {
        let b = try makeBundle()
        defer { cleanup(b.tempDir) }
        let index = SessionIndex(workspaces: b.normalWorkspaces)
        b.action.jump(snapshot: snapshot(for: b.sessionIds[3]), snapshotIndex: index)
        XCTAssertEqual(b.focusedPaneStore.focused[b.workspaceIds[1]], b.paneIds[3])
    }

    // MARK: - 3. handler.makeFirstResponder 호출 1회

    func test_jump_callsMakeFirstResponderOnce() throws {
        let b = try makeBundle()
        defer { cleanup(b.tempDir) }
        let index = SessionIndex(workspaces: b.normalWorkspaces)
        b.action.jump(snapshot: snapshot(for: b.sessionIds[0]), snapshotIndex: index)
        XCTAssertEqual(b.handler.callCount, 1)
        XCTAssertEqual(b.handler.lastView, b.views[b.paneIds[0]])
    }

    // MARK: - 4. 6 카드 매트릭스

    func test_jump_6CardMatrix_allCorrect() throws {
        let b = try makeBundle()
        defer { cleanup(b.tempDir) }
        let index = SessionIndex(workspaces: b.normalWorkspaces)
        for i in 0..<6 {
            b.action.jump(snapshot: snapshot(for: b.sessionIds[i]), snapshotIndex: index)
            XCTAssertEqual(b.manager.selectedID, b.workspaceIds[i / 2], "iter \(i) selectedID")
            XCTAssertEqual(b.focusedPaneStore.focused[b.workspaceIds[i / 2]], b.paneIds[i], "iter \(i) focused")
        }
        XCTAssertEqual(b.handler.callCount, 6)
    }

    // MARK: - 5. 미등록 sessionId → noop

    func test_jump_unknownSessionId_noop() throws {
        let b = try makeBundle()
        defer { cleanup(b.tempDir) }
        let index = SessionIndex(workspaces: b.normalWorkspaces)
        let priorSelected = b.manager.selectedID
        b.action.jump(snapshot: snapshot(for: UUID()), snapshotIndex: index)
        XCTAssertEqual(b.manager.selectedID, priorSelected)
        XCTAssertEqual(b.handler.callCount, 0)
    }

    // MARK: - 6. registry 누락 → handler 미호출, selectedID 는 갱신

    func test_jump_paneNotInRegistry_skipsHandler() throws {
        let b = try makeBundle()
        defer { cleanup(b.tempDir) }
        b.registry.release(paneId: b.paneIds[1])
        let index = SessionIndex(workspaces: b.normalWorkspaces)
        b.action.jump(snapshot: snapshot(for: b.sessionIds[1]), snapshotIndex: index)
        XCTAssertEqual(b.manager.selectedID, b.workspaceIds[0])
        XCTAssertEqual(b.focusedPaneStore.focused[b.workspaceIds[0]], b.paneIds[1])
        XCTAssertEqual(b.handler.callCount, 0)
    }

    // MARK: - 7. focused 격리

    func test_jump_focusIsolatedPerWorkspace() throws {
        let b = try makeBundle()
        defer { cleanup(b.tempDir) }
        let index = SessionIndex(workspaces: b.normalWorkspaces)
        b.action.jump(snapshot: snapshot(for: b.sessionIds[0]), snapshotIndex: index)
        b.action.jump(snapshot: snapshot(for: b.sessionIds[2]), snapshotIndex: index)
        XCTAssertEqual(b.focusedPaneStore.focused[b.workspaceIds[0]], b.paneIds[0])
        XCTAssertEqual(b.focusedPaneStore.focused[b.workspaceIds[1]], b.paneIds[2])
    }

    // MARK: - 8. DefaultHandler 인스턴스화

    func test_defaultHandler_canBeInstantiated() {
        let _: AgentJumpAction.Handler = AgentJumpAction.DefaultHandler()
    }

    // MARK: - 9. 100회 반복 stable

    func test_jump_repeated100times_handlerCount100() throws {
        let b = try makeBundle()
        defer { cleanup(b.tempDir) }
        let index = SessionIndex(workspaces: b.normalWorkspaces)
        for _ in 0..<100 {
            b.action.jump(snapshot: snapshot(for: b.sessionIds[5]), snapshotIndex: index)
        }
        XCTAssertEqual(b.handler.callCount, 100)
        XCTAssertEqual(b.manager.selectedID, b.workspaceIds[2])
    }

    // MARK: - 10. agent-view invariant 보존

    func test_jump_doesNotDuplicateAgentView() throws {
        let b = try makeBundle()
        defer { cleanup(b.tempDir) }
        let agentBefore = b.manager.workspaces.filter { $0.kind == .agentView }.count
        XCTAssertEqual(agentBefore, 1)
        let index = SessionIndex(workspaces: b.normalWorkspaces)
        for i in 0..<6 {
            b.action.jump(snapshot: snapshot(for: b.sessionIds[i]), snapshotIndex: index)
        }
        let agentAfter = b.manager.workspaces.filter { $0.kind == .agentView }.count
        XCTAssertEqual(agentAfter, 1, "agent-view 1개 invariant 보존")
    }
}
