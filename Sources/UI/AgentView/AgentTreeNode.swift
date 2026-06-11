import Foundation

/// agent-view 좌측 트리의 단일 노드. workspace → pane → tab 3단 계층을 표현한다.
///
/// immutable enum. workspaces 변경 시 `AgentTreeBuilder.build` 가 새 트리를
/// 재계산한다(SessionIndex 패턴과 동일). SwiftUI 비의존 순수 데이터 레이어로
/// 단위 테스트가 전 경로를 측정한다.
///
/// 선택 가능 단위는 tab leaf 뿐이다. workspace/pane 노드는 컨테이너이며
/// `selectableTabId == nil`(선택 불가). tab leaf 만 `sessionId`/`snapshot` 을
/// 보유한다.
public enum AgentTreeNode: Identifiable, Equatable {
    case workspace(id: UUID, name: String, children: [AgentTreeNode])
    case pane(id: UUID, position: PanePosition, children: [AgentTreeNode])
    case tab(
        id: UUID,
        sessionId: UUID?,
        name: String,
        kind: PaneKind,
        snapshot: SessionStatusSnapshot?
    )

    /// 각 case 의 고유 id. workspace/pane 은 모델 id, tab 은 tabId.
    public var id: UUID {
        switch self {
        case let .workspace(id, _, _): return id
        case let .pane(id, _, _): return id
        case let .tab(id, _, _, _, _): return id
        }
    }

    /// OutlineGroup 자식. workspace/pane 만 non-nil, tab leaf 는 nil.
    public var children: [AgentTreeNode]? {
        switch self {
        case let .workspace(_, _, children): return children
        case let .pane(_, _, children): return children
        case .tab: return nil
        }
    }

    /// 선택 가능한 tabId. tab case 일 때만 자신의 id, 나머지는 nil.
    public var selectableTabId: UUID? {
        switch self {
        case let .tab(id, _, _, _, _): return id
        default: return nil
        }
    }
}
