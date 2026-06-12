import Foundation

/// Tailscale 진단 seam. 실 구현은 `Process`로 `tailscale status --json` / `tailscale ip -4`를
/// 호출하지만, 이 protocol 뒤에 격리해 테스트는 fake conformer로 4분기를 전부 검증한다
/// (Tailscale 미설치 CI에서도 결정론적). 본 파일은 P6b Day 0 골격(시그니처 + 진단 모델)이며,
/// 실 `Process` 구현은 Day 2/3에 추가한다.
public protocol TailscaleProbing: Sendable {
    /// 외부 Tailscale 상태를 진단해 4분기 중 하나로 환원한다.
    func probe() async -> TailscaleState
}

/// Tailscale 진단 결과. running만 tailnet 노출(tailscaleIP 바인딩)이고, 나머지 3분기는
/// loopback 폴백 + 한국어 사유 노출(Principle 4 — silent 실패 금지)이다.
public enum TailscaleState: Sendable, Equatable {
    /// 100.x IPv4 획득 → tailscaleIP 바인딩. 연관값은 Tailscale IPv4 주소.
    case running(ip: String)
    /// CLI 부재(실행 파일 launch 실패) → loopback 폴백 + 한국어 안내.
    case notInstalled
    /// BackendState=NeedsLogin → loopback 폴백 + 한국어 안내.
    case notLoggedIn
    /// BackendState=Stopped 등 → loopback 폴백 + 한국어 안내.
    case offline

    /// 사용자 표시용 한국어 사유. secret·실 IP를 포함하지 않는다(Principle 4).
    public var koreanReason: String {
        switch self {
        case .running:
            return "Tailscale에 연결되어 안전한 원격 접속이 가능합니다."
        case .notInstalled:
            return "Tailscale이 설치되어 있지 않습니다. 로컬 연결만 사용합니다."
        case .notLoggedIn:
            return "Tailscale 로그인이 필요합니다. 로컬 연결만 사용합니다."
        case .offline:
            return "Tailscale이 오프라인 상태입니다. 로컬 연결만 사용합니다."
        }
    }
}

/// 진단 상태를 바인딩 전략으로 환원한다. running(ip)만 tailnet 노출이고, 나머지는 loopback
/// 폴백이다(사유는 `TailscaleState.koreanReason`으로 별도 노출).
public func bindStrategy(from state: TailscaleState) -> BindStrategy {
    if case let .running(ip) = state {
        return .tailscaleIP(ip)
    }
    return .loopback
}
