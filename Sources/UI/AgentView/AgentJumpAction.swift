import AppKit
import Foundation

/// 카드 click → workspace 선택 + pane focus + first responder 전환을 묶는 action.
///
/// 종료 조건:
/// (1) `manager.selectedID == location.workspaceId`
/// (2) `focusedPaneStore.focused[location.workspaceId] == location.paneId`
/// (3) view 가 `makeFirstResponder` 를 통해 키보드 입력 받기 시작
///
/// 마지막 단계는 `AgentJumpActionFirstResponderHandler` 를 거치므로 단위 테스트에서
/// mock handler 가 호출 횟수를 검증할 수 있다.
@MainActor
public final class AgentJumpAction {
    public protocol Handler: AnyObject {
        @discardableResult
        func makeFirstResponder(_ view: NSView) -> Bool
    }

    /// production default: 현재 window 에 대해 makeFirstResponder 호출.
    @MainActor
    public final class DefaultHandler: Handler {
        public init() {}
        @discardableResult
        public func makeFirstResponder(_ view: NSView) -> Bool {
            return view.window?.makeFirstResponder(view) ?? false
        }
    }

    private let manager: WorkspaceManager
    private let focusedPaneStore: FocusedPaneStore
    private let surfaceRegistry: SurfaceRegistry
    private let handler: Handler

    public init(
        manager: WorkspaceManager,
        focusedPaneStore: FocusedPaneStore,
        surfaceRegistry: SurfaceRegistry,
        handler: Handler? = nil
    ) {
        self.manager = manager
        self.focusedPaneStore = focusedPaneStore
        self.surfaceRegistry = surfaceRegistry
        self.handler = handler ?? DefaultHandler()
    }

    public func jump(snapshot: SessionStatusSnapshot, snapshotIndex: SessionIndex) {
        guard let location = snapshotIndex.locate(sessionId: snapshot.sessionId) else { return }
        manager.select(id: location.workspaceId)
        focusedPaneStore.setFocus(workspaceId: location.workspaceId, paneId: location.paneId)
        if let view = surfaceRegistry.acquireExisting(paneId: location.paneId) {
            handler.makeFirstResponder(view)
        }
    }
}
