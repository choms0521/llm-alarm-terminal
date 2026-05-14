import XCTest
import Foundation
import SwiftUI

/// agent-view 탭의 close 버튼 부재 invariant 단위 검증.
///
/// 검증 전략:
/// 1. `WorkspaceTabRowState` — view 의 모든 분기 결정(canClose, accessibility ID, symbol)을
///    SwiftUI 와 분리된 순수 값으로 노출. 이 state 의 canClose 가 분기를 결정한다.
/// 2. `WorkspaceManager.removeWorkspace(id:)` — agent-view 제거 시도는 silently 거부됨
///    (단위 테스트는 `WorkspaceManagerTests.test_removeWorkspace_refusesAgentView_invariant`).
///
/// SwiftUI body 의 `if state.canClose { Button ... }` 분기는 state.canClose 가 false 면
/// Button 자체가 view tree 에 삽입되지 않음(SwiftUI 의 conditional rendering invariant).
/// XCUITest 로 hit-test 자체를 확인하는 행위는 Day 8 단축키 wiring 단계에서 통합 검증한다.
@MainActor
final class AgentViewCloseInvariantTests: XCTestCase {

    func test_state_agentView_canCloseIsFalse_andNoCloseButtonID() {
        let agent = Workspace.makeAgentView()
        let state = WorkspaceTabRowState(workspace: agent)
        XCTAssertFalse(state.canClose, "agent-view 의 canClose 는 항상 false")
        XCTAssertNil(state.closeButtonAccessibilityID,
                     "agent-view 에는 close 버튼 accessibility ID 가 발급되지 않음")
        XCTAssertEqual(state.symbolName, "person.crop.rectangle")
    }

    func test_state_normalWorkspace_canCloseIsTrue_withButtonID() {
        let normal = Workspace(name: "x", cwd: "/tmp", kind: .normal)
        let state = WorkspaceTabRowState(workspace: normal)
        XCTAssertTrue(state.canClose, "normal workspace 의 canClose 는 true")
        XCTAssertEqual(state.closeButtonAccessibilityID,
                       "close-workspace-\(normal.id.uuidString)",
                       "normal workspace 에는 결정적 close 버튼 accessibility ID 발급")
        XCTAssertEqual(state.symbolName, "folder")
    }

    /// state 가 분기 결정의 단일 진입점임을 강화: `Workspace.canClose` 와 `WorkspaceTabRowState.canClose`
    /// 가 항상 일치하므로 view 분기는 모델 invariant 와 1:1 동등하다.
    func test_state_canClose_mirrorsWorkspaceCanClose() {
        let agent = Workspace.makeAgentView()
        let normal = Workspace(name: "n", cwd: "/tmp", kind: .normal)
        XCTAssertEqual(WorkspaceTabRowState(workspace: agent).canClose, agent.canClose)
        XCTAssertEqual(WorkspaceTabRowState(workspace: normal).canClose, normal.canClose)
        XCTAssertFalse(agent.canClose)
        XCTAssertTrue(normal.canClose)
    }
}
