import Foundation
import Combine

/// workspace 단위로 현재 focus 가 있는 pane.id 를 기록하는 ObservableObject.
///
/// agent-view 카드 click → AgentJumpAction 이 (workspaceId, paneId) 를 set 하고,
/// 사용자가 다른 pane 에 click 하면 `WorkspaceContentView` 가 갱신한다.
/// ViewportPollingTimer 는 본 store 와 `WorkspaceManager.selectedID` 를 join 하여
/// "focused pane" 을 판정 (4Hz / 1Hz 빈도 분기 기준).
@MainActor
public final class FocusedPaneStore: ObservableObject {
    @Published public private(set) var focused: [UUID: UUID] = [:]

    public init() {}

    public func setFocus(workspaceId: UUID, paneId: UUID) {
        focused[workspaceId] = paneId
    }

    public func clearFocus(workspaceId: UUID) {
        focused.removeValue(forKey: workspaceId)
    }

    public func currentFocus(workspaceId: UUID) -> UUID? {
        focused[workspaceId]
    }
}
