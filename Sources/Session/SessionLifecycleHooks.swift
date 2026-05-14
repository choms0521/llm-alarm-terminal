import Foundation
import Combine

/// SessionManager 의 lifecycle 이벤트 publisher 모음.
///
/// `nonisolated let` 으로 SessionManager actor 가 보유하여 외부에서
/// `await` 없이 구독 가능하도록 한다. PassthroughSubject 의 `send(_:)` 는
/// Combine 보장에 의해 thread-safe.
public final class SessionLifecycleHooks: @unchecked Sendable {
    public let onSessionCreated: PassthroughSubject<Session, Never>
    public let onSessionTerminated: PassthroughSubject<UUID, Never>

    public init() {
        self.onSessionCreated = PassthroughSubject()
        self.onSessionTerminated = PassthroughSubject()
    }
}
