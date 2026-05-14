import Foundation
import Combine

/// agent-view 카드 한 장의 source data. SessionStatusSnapshot 과 그 세션이
/// 속한 workspace 컨텍스트 (workspaceId / paneId / name / paneKind) 를 묶는다.
public struct AgentCard: Identifiable, Equatable {
    public var id: UUID { sessionId }
    public let sessionId: UUID
    public let workspaceId: UUID
    public let paneId: UUID
    public let workspaceName: String
    public let paneKind: PaneKind
    public let snapshot: SessionStatusSnapshot

    public init(
        sessionId: UUID,
        workspaceId: UUID,
        paneId: UUID,
        workspaceName: String,
        paneKind: PaneKind,
        snapshot: SessionStatusSnapshot
    ) {
        self.sessionId = sessionId
        self.workspaceId = workspaceId
        self.paneId = paneId
        self.workspaceName = workspaceName
        self.paneKind = paneKind
        self.snapshot = snapshot
    }
}

/// agent-view 그리드의 데이터 소스. `SessionStatusCoordinator.snapshots`,
/// `WorkspaceManager.workspaces`, `SessionIndex` 를 join 하여 카드 배열을 만든다.
///
/// Day 6: sortOrder / filterStatus 가 변경되면 cards 가 재정렬된다. settings 는
/// 외부에서 `AgentSortFilterControls` 가 binding 하며, 변경 시 `WorkspaceManager.
/// updateAgentViewExtraFields(_:)` 가 영속화한다.
@MainActor
public final class AgentDashboardViewModel: ObservableObject {
    @Published public private(set) var cards: [AgentCard] = []
    @Published public var sortOrder: AgentSortOrder = .lastActivityAtDesc
    @Published public var filter: AgentFilterOption = .all

    /// 호환 anchor: 기존 코드가 `filterStatus` 를 직접 set 하던 경로.
    public var filterStatus: AgentStatus? {
        get {
            switch filter {
            case .needsInput: return .needsInput
            case .working: return .working
            case .all, .claudeOnly: return nil
            }
        }
        set {
            switch newValue {
            case .needsInput: filter = .needsInput
            case .working: filter = .working
            case .none: filter = .all
            default: filter = .all
            }
        }
    }

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
            let paneKind = ws.panes.first(where: { $0.id == entry.paneId })?.kind ?? .shell

            switch filter {
            case .all: break
            case .needsInput: if snap.agentStatus != .needsInput { continue }
            case .working: if snap.agentStatus != .working { continue }
            case .claudeOnly: if paneKind != .claude { continue }
            }

            newCards.append(AgentCard(
                sessionId: entry.sessionId,
                workspaceId: entry.workspaceId,
                paneId: entry.paneId,
                workspaceName: ws.name,
                paneKind: paneKind,
                snapshot: snap
            ))
        }

        newCards.sort(by: Self.comparator(for: sortOrder))
        cards = newCards
    }

    /// 정렬 비교자.
    public static func comparator(for order: AgentSortOrder) -> (AgentCard, AgentCard) -> Bool {
        switch order {
        case .lastActivityAtDesc:
            return { $0.snapshot.lastActivityAt > $1.snapshot.lastActivityAt }
        case .lastActivityAtAsc:
            return { $0.snapshot.lastActivityAt < $1.snapshot.lastActivityAt }
        case .workspaceName:
            return { $0.workspaceName < $1.workspaceName }
        case .statusFirst:
            return {
                Self.statusPriority($0.snapshot.agentStatus) < Self.statusPriority($1.snapshot.agentStatus)
            }
        }
    }

    /// needsInput → working → idle → exited 우선순위. 작은 숫자가 먼저.
    public static func statusPriority(_ status: AgentStatus) -> Int {
        switch status {
        case .needsInput: return 0
        case .working: return 1
        case .idle: return 2
        case .exited: return 3
        }
    }
}
