import Foundation

/// WS endpoint 바인딩 전략. 기본은 loopback(P6a 동작 그대로, 383 green·A8 lsof 비파괴)이고,
/// tailnet 노출은 부트스트랩 opt-in으로 Tailscale 100.x 주소에 바인딩한다(1차 경계).
///
/// 본 enum은 P6b Day 0 골격이다 — `WSServer.makeListenerParameters`의 `requiredLocalEndpoint`
/// host를 분기하는 데 쓰이며, 실제 WSServer 배선은 Day 2다. host만 분기하고 P6a 게이트 ①
/// (핸드셰이크 클로저)은 무변경이다.
public enum BindStrategy: Sendable, Equatable {
    /// 127.0.0.1 (P6a 동작 그대로).
    case loopback
    /// 100.x.y.z — tailnet 한정 노출(1차 경계). 연관값은 Tailscale IPv4 주소.
    case tailscaleIP(String)

    /// `requiredLocalEndpoint`에 넣을 바인딩 호스트 문자열.
    public var host: String {
        switch self {
        case .loopback:
            return "127.0.0.1"
        case .tailscaleIP(let ip):
            return ip
        }
    }
}
