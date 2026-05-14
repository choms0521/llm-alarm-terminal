import Foundation
import Combine

/// agent-view 카드 한 장의 source data. SessionStatusSnapshot 과 그 세션이
/// 속한 workspace 컨텍스트 (workspaceId / paneId / name) 를 묶는다.
public struct AgentCard: Identifiable, Equatable {
    public var id: UUID { sessionId }
    public let sessionId: UUID
    public let workspaceId: UUID
    public let paneId: UUID
    public let workspaceName: String
    public let snapshot: SessionStatusSnapshot

    public init(
        sessionId: UUID,
        workspaceId: UUID,
        paneId: UUID,
        workspaceName: String,
        snapshot: SessionStatusSnapshot
    ) {
        self.sessionId = sessionId
        self.workspaceId = workspaceId
        self.paneId = paneId
        self.workspaceName = workspaceName
        self.snapshot = snapshot
    }
}

/// agent-view 그리드의 데이터 소스. `SessionStatusCoordinator.snapshots`,
/// `WorkspaceManager.workspaces`, `SessionIndex` 를 join 하여 카드 배열을 만든다.
///
/// 정렬 default 는 `lastActivityAt` desc. Day 6 에서 sort/filter UI 가 본 모델의
/// `sortOrder` / `filterStatus` 를 변경하면 cards 가 재정렬된다.
@MainActor
public final class AgentDashboardViewModel: ObservableObject {
    @Published public private(set) var cards: [AgentCard] = []
    @Published public var filterStatus: AgentStatus? = nil

    public init() {}

    /// snapshots × workspaces × sessionIndex 를 join 하여 카드를 재계산한다.
    public func refresh(
        snapshots: [UUID: SessionStatusSnapshot],
        workspaces: [Workspace],
        sessionIndex: SessionIndex
    ) {
        var newCards: [AgentCard] = []
        for entry in sessionIndex.entries {
            guard let snap = snapshots[entry.sessionId] else { continue }
            guard let ws = workspaces.first(where: { $0.id == entry.workspaceId }) else { continue }
            if let filter = filterStatus, snap.agentStatus != filter { continue }
            newCards.append(AgentCard(
                sessionId: entry.sessionId,
                workspaceId: entry.workspaceId,
                paneId: entry.paneId,
                workspaceName: ws.name,
                snapshot: snap
            ))
        }
        newCards.sort { $0.snapshot.lastActivityAt > $1.snapshot.lastActivityAt }
        cards = newCards
    }
}
