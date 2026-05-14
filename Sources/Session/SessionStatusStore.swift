import Foundation
import Combine

/// 모든 세션의 최신 SessionStatusSnapshot 을 sessionId 단위로 보관하는 publisher.
///
/// SwiftUI 뷰가 `@ObservedObject` 로 구독하여 카드 그리드를 렌더링한다.
/// 모든 mutation 은 `@MainActor` 격리되며, SessionStatusCoordinator 가
/// throttle + fast-lane 분리로 emit 한다(Day 4).
@MainActor
public final class SessionStatusStore: ObservableObject {
    @Published public private(set) var snapshots: [UUID: SessionStatusSnapshot] = [:]

    public init() {}

    /// 단일 snapshot 추가 또는 교체. 동일 sessionId 가 이미 있으면 새 값으로 대체.
    public func upsert(_ snapshot: SessionStatusSnapshot) {
        snapshots[snapshot.sessionId] = snapshot
    }

    /// 세션이 SessionManager 에서 제거된 경우 store 에서도 제거.
    public func remove(sessionId: UUID) {
        snapshots.removeValue(forKey: sessionId)
    }

    /// 전체 스냅샷 초기화 (테스트 + reset 시나리오).
    public func removeAll() {
        snapshots.removeAll()
    }

    public func snapshot(for sessionId: UUID) -> SessionStatusSnapshot? {
        snapshots[sessionId]
    }
}
