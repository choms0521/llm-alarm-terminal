import Foundation

/// Tailscale 사전 진단(§5.5, ADR-F). TailscaleProbing seam 뒤의 실 CLI 호출을 1점으로 모으고,
/// 그 결과를 (a) 한국어 사유(설정 UI 노출용)와 (b) BindStrategy(loopback/tailscaleIP)로 환원한다.
/// 데몬은 어느 분기든 기동한다 — running만 tailnet 노출이고 나머지 3분기는 loopback 폴백 + 사유
/// 노출이라 점진적 저하한다(silent 실패 금지 — Principle 4).
///
/// 실 Process 호출은 ProcessTailscaleProbe(seam 뒤)에 격리돼 있어 단위 테스트는 fake probe로
/// 4분기를 결정론적으로 검증한다(Tailscale 미설치 CI에서도).
public struct TailscaleDiagnostics: Sendable {
    private let probe: any TailscaleProbing

    public init(probe: any TailscaleProbing) {
        self.probe = probe
    }

    /// 진단 1회 실행 결과. UI는 reason을 표시하고, 데몬 부트스트랩은 strategy로 WSServer를 바인딩한다.
    public struct Result: Sendable, Equatable {
        public let state: TailscaleState
        public let reason: String
        public let strategy: BindStrategy

        public init(state: TailscaleState, reason: String, strategy: BindStrategy) {
            self.state = state
            self.reason = reason
            self.strategy = strategy
        }
    }

    /// 외부 Tailscale 상태를 진단하고 4분기를 (state, 한국어 사유, 바인딩 전략)으로 환원한다.
    /// running(ip)만 tailscaleIP 노출, 나머지는 loopback 폴백(사유는 항상 노출).
    public func diagnose() async -> Result {
        let state = await probe.probe()
        return Result(state: state, reason: state.koreanReason, strategy: bindStrategy(from: state))
    }
}
