import Foundation

/// 에이전트 뷰에서 카드로 표시되는 동적 상태.
///
/// P1/P2 의 `SessionStatus` (running/exited) 와는 다른 도메인이다.
/// 라이프사이클(running/exited) 은 SessionManager 가, agent-status 는
/// SessionStatusCoordinator 가 단방향 소비하여 갱신한다.
public enum AgentStatus: String, Sendable, Equatable {
    case idle
    case working
    case needsInput
    case exited
}

/// SessionId 단위로 카드에 표시할 동적 상태 스냅샷.
///
/// 모든 stored property 는 `let` 으로 불변이다. 변경은 `with(...)` 빌더가
/// 새 인스턴스를 반환한다. `Session` 모델은 손대지 않는다(P3 Option C).
///
/// `latestPreview` 는 grapheme cluster 단위로 200개 이하이며 UTF-8 boundary
/// safe 하다(Day 3 의 `Utf8BoundaryTruncator` 가 보장).
public struct SessionStatusSnapshot: Sendable, Equatable {
    public let sessionId: UUID
    public let agentStatus: AgentStatus
    public let latestPreview: String
    public let lastActivityAt: Date

    public init(
        sessionId: UUID,
        agentStatus: AgentStatus,
        latestPreview: String,
        lastActivityAt: Date
    ) {
        self.sessionId = sessionId
        self.agentStatus = agentStatus
        self.latestPreview = latestPreview
        self.lastActivityAt = lastActivityAt
    }

    /// 변경하지 않는 필드는 self 값을 그대로 복사하는 immutable builder.
    public func with(
        agentStatus: AgentStatus? = nil,
        latestPreview: String? = nil,
        lastActivityAt: Date? = nil
    ) -> SessionStatusSnapshot {
        SessionStatusSnapshot(
            sessionId: sessionId,
            agentStatus: agentStatus ?? self.agentStatus,
            latestPreview: latestPreview ?? self.latestPreview,
            lastActivityAt: lastActivityAt ?? self.lastActivityAt
        )
    }

    /// 신규 세션 등록 시 사용되는 기본 스냅샷 (idle, 빈 preview).
    public static func makeInitial(
        sessionId: UUID,
        at date: Date = Date()
    ) -> SessionStatusSnapshot {
        SessionStatusSnapshot(
            sessionId: sessionId,
            agentStatus: .idle,
            latestPreview: "",
            lastActivityAt: date
        )
    }
}
