import Foundation

/// SessionId 가 어느 workspace / pane 에 속하는지를 가리키는 단일 매핑.
public struct SessionIndexEntry: Sendable, Equatable {
    public let sessionId: UUID
    public let workspaceId: UUID
    public let paneId: UUID

    public init(sessionId: UUID, workspaceId: UUID, paneId: UUID) {
        self.sessionId = sessionId
        self.workspaceId = workspaceId
        self.paneId = paneId
    }
}

/// `Workspace` 의 panes 트리에서 `sessionId → (workspaceId, paneId)` 역인덱스를
/// 한 번에 빌드한다. `AgentJumpAction` 이 카드 클릭 → workspace 선택 → pane focus
/// 점프 시 lookup 대상.
///
/// immutable struct. workspaces 가 바뀌면 새 인스턴스를 build 한다.
public struct SessionIndex: Sendable, Equatable {
    private let table: [UUID: SessionIndexEntry]
    public let entries: [SessionIndexEntry]

    public init(workspaces: [Workspace]) {
        var table: [UUID: SessionIndexEntry] = [:]
        var entries: [SessionIndexEntry] = []
        for workspace in workspaces {
            for pane in workspace.panes {
                // P3.5 schema v2: pane 의 모든 tab 의 sessionId 를 색인.
                for tab in pane.tabs {
                    guard let sessionId = tab.sessionId else { continue }
                    let entry = SessionIndexEntry(
                        sessionId: sessionId,
                        workspaceId: workspace.id,
                        paneId: pane.id
                    )
                    table[sessionId] = entry
                    entries.append(entry)
                }
            }
        }
        self.table = table
        self.entries = entries
    }

    /// `sessionId` 가 등록된 entry 를 반환한다. 매칭 없으면 nil.
    public func locate(sessionId: UUID) -> SessionIndexEntry? {
        table[sessionId]
    }

    /// 등록된 entry 의 개수. 시나리오 C (>20 세션 위반) 의 detect 신호.
    public var size: Int { entries.count }

    /// 모든 entry 가 비어 있는지(workspace 가 비었거나 모든 tab.sessionId 가 nil).
    public var isEmpty: Bool { entries.isEmpty }
}
