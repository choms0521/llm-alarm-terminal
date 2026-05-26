import Foundation
import os

/// action_cb 가 main thread 로 hop 한 뒤의 dispatch 라우터.
///
/// 책임:
/// 1. 4 known tag 를 SessionStatusObserver.observe(action:) 로 변환
/// 2. unknown tag 는 pass-through 정책 (warn log + counter 증가, observer 미호출)
/// 3. surfaceUserdata 포인터 → tabId → sessionId 역인덱스 lookup
///
/// 본 라우터는 process-wide singleton 으로 shared 인스턴스에 wire 한다.
/// app boot 시점 `SessionActionRouter.shared` 를 설정하면 GhosttyApp 의 action_cb
/// hop 본문에서 dispatch 가 가능해진다.
///
/// P3.5 Day 1.5: SurfaceRegistry key 가 tabId 로 전환됨에 따라 GhosttyTerminalView 의
/// anchor 도 paneId → tabId. resolver 의 의미를 tab 단위로 갱신.
@MainActor
public final class SessionActionRouter {
    public static var shared: SessionActionRouter?

    private static let logger = Logger(
        subsystem: "com.choms0521.ClaudeAlarmTerminal",
        category: "AgentView.Router"
    )

    public private(set) var unknownActionCount: Int = 0

    private weak var observer: SessionStatusObserver?
    private let resolveTabId: (UnsafeMutableRawPointer?) -> UUID?
    private let resolveSessionId: (UUID) -> UUID?

    public init(
        observer: SessionStatusObserver,
        resolveTabId: @escaping (UnsafeMutableRawPointer?) -> UUID?,
        resolveSessionId: @escaping (UUID) -> UUID?
    ) {
        self.observer = observer
        self.resolveTabId = resolveTabId
        self.resolveSessionId = resolveSessionId
    }

    /// action_cb hop 본문에서 호출. surfaceUserdata 가 nil 이거나 tabId/sessionId
    /// 매핑이 끊긴 경우 silently drop (orphan surface 신호).
    public func dispatch(
        tag: ActionTag,
        surfaceUserdata: UnsafeMutableRawPointer?,
        payload: ActionPayload,
        at now: Date = Date()
    ) {
        guard let tabId = resolveTabId(surfaceUserdata),
              let sessionId = resolveSessionId(tabId) else {
            return
        }

        switch tag {
        case .ringBell:
            observer?.observe(sessionId: sessionId, action: .ringBell, at: now)
        case .commandFinished:
            observer?.observe(sessionId: sessionId, action: .commandFinished, at: now)
        case .promptTitle:
            if let title = payload.promptTitle {
                observer?.observe(sessionId: sessionId, action: .promptTitle(title), at: now)
            }
        case .progressReport:
            observer?.observe(sessionId: sessionId, action: .progressReport, at: now)
        case .unknown(let raw):
            unknownActionCount += 1
            Self.logger.warning("unknown action tag rawValue=\(raw, privacy: .public)")
        }
    }

    /// 테스트에서 카운터 리셋용.
    public func resetUnknownActionCount() {
        unknownActionCount = 0
    }
}
