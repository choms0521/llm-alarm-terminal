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

    // MARK: - 3. SessionStatus enum P1/P2 그대로 유지 invariant

    func test_sessionStatus_caseOrder() {
        XCTAssertEqual(SessionStatus.running.rawValue, "running")
        XCTAssertEqual(SessionStatus.exited.rawValue, "exited")
        // AgentStatus 와 별도 enum 임을 확인.
        XCTAssertNotEqual(SessionStatus.running.rawValue, AgentStatus.idle.rawValue)
    }
}
