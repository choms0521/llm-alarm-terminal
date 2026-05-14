import Foundation

/// libghostty action_cb 가 발행하는 high-level 시그널의 정규화된 tag.
///
/// GhosttyKit C enum (`ghostty_action_tag_e`) 을 직접 노출하지 않고 Swift 측에서
/// 4 known tag + unknown 으로 환원한다. SessionTests target 이 GhosttyKit 의존성
/// 없이도 라우터를 단위 테스트할 수 있게 한다.
public enum ActionTag: Sendable, Equatable {
    case ringBell
    case commandFinished
    case promptTitle
    case progressReport
    case unknown(rawValue: UInt32)
}

/// action 메모리에서 main thread hop 전에 추출해 둔 sendable payload.
/// action_cb callback 은 libghostty 의 read/write/render thread 중 어디에서든
/// 동기 invoke 되므로, callback 진입 즉시 모든 정보를 본 struct 로 copy 한다.
/// 포인터 직접 보유는 금지: hop 후 libghostty 메모리가 invalid 일 수 있다.
public struct ActionPayload: Sendable, Equatable {
    public let promptTitle: String?
    public let progressPercent: Int?

    public init(promptTitle: String? = nil, progressPercent: Int? = nil) {
        self.promptTitle = promptTitle
        self.progressPercent = progressPercent
    }
}
