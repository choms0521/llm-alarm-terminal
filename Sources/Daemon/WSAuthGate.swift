import Foundation

/// P6a WS 인증 2단 게이트의 carry-over 상태 저장소(골격).
///
/// 이 타입은 Day 0 스파이크 단계의 골격이다. 시그니처만 확정하고 본 구현은
/// Day 2(WS 인증 게이트 배선)에서 채운다. 게이트 ①(핸드셰이크
/// `setClientRequestHandler`)이 헤더 Bearer를 구조 분해해 일회성 nonce를 키로
/// `(tokenId, presentedSecret)`를 등록하고, 게이트 ②(첫 envelope)가 echo된
/// nonce로 그 항목만 원자 소비해 secret 대조로 승격한다.
///
/// 설계 의도(왜 nonce 키 carry-over인가): `setClientRequestHandler`는 connection
/// 객체를 받지 않아 "핸드셰이크에서 본 Bearer"를 `accept`가 발급하는 clientId와
/// 직접 묶을 다리가 없다. 그래서 클라이언트가 연결마다 생성한 일회성 nonce를
/// 매개로, 핸드셰이크에서 등록한 항목을 첫 envelope이 echo한 nonce로 지목·소비하게
/// 한다. 토큰·secret은 핸드셰이크 헤더로만 운반되고 첫 envelope에는 nonce만 echo한다.
///
/// 위치 메모: Day 0는 `Sources/Daemon/`에 둔다(DaemonTests가 컴파일하는 경로).
/// Day 1에 `Sources/Pairing/`이 신설되면 Day 2에서 이동 여부를 결정한다.
public final class WSAuthGate: @unchecked Sendable {

    /// 게이트 ① 핸드셰이크 클로저(`setClientRequestHandler`)가 부착되는 큐.
    /// `makeListenerParameters` 안에서 `ws.setClientRequestHandler(authGate.queue)`로 쓴다.
    public let queue: DispatchQueue

    public init(queue: DispatchQueue = DispatchQueue(label: "com.choms0521.ClaudeAlarmTerminal.ws-auth-gate")) {
        self.queue = queue
    }

    /// 게이트 ①: 구조 검증을 통과한 `(tokenId, presentedSecret)`를 nonce를 키로
    /// 등록한다(coarse 차단 + 격리점 선확보). secret 대조는 핸드셰이크 큐를 블록하므로
    /// 여기서 하지 않고 carry만 한다.
    ///
    /// Day 2 구현 예정: nonce -> (tokenId, secret, 등록시각) 매핑 저장.
    public func registerPending(nonce: String, tokenId: String, secret: Data, at: Date) {
        // Day 2에서 구현한다. Day 0 골격은 시그니처만 확정한다.
    }

    /// 게이트 ②: echo된 nonce와 일치하는 등록 항목만 원자 소비한다(1회 소비, replay 방지).
    /// `within` 시간창을 넘긴 항목은 삭제하고 nil을 반환한다. 일치 항목이 없어도 nil.
    ///
    /// Day 2 구현 예정: nonce 매칭 + 시간창 검사 + 원자 점유·제거.
    public func consumePending(nonce: String, within: TimeInterval) -> (tokenId: String, secret: Data)? {
        // Day 2에서 구현한다. Day 0 골격은 시그니처만 확정한다.
        return nil
    }

    /// 게이트 ①: 이미 등록된 nonce인지 확인한다. 중복 nonce 핸드셰이크는 reject 대상이다
    /// (클라이언트가 새 nonce로 재시도). nonce 충돌 확률은 2^128분의 1 수준이다.
    ///
    /// Day 2 구현 예정: 등록 맵 조회.
    public func isNonceRegistered(_ nonce: String) -> Bool {
        // Day 2에서 구현한다. Day 0 골격은 시그니처만 확정한다.
        return false
    }

    /// 게이트 ①: Bearer 문자열을 `(tokenId, presentedSecret)`로 구조 분해한다.
    /// 형식은 `tokenId.secretBase64url`이며 secret은 base64url 디코드한 raw bytes다.
    /// 구조가 어긋나면(점 구분자 누락, base64url 위반 등) nil을 반환해 핸드셰이크를
    /// reject하게 한다. Keychain 조회·secret 대조는 여기서 하지 않는다(게이트 ②로 지연).
    ///
    /// Day 2 구현 예정: 구분자 분리 + tokenId 형식 검증 + secret base64url 디코드.
    public func structurallySplit(_ bearer: String?) -> (tokenId: String, secret: Data)? {
        // Day 2에서 구현한다. Day 0 골격은 시그니처만 확정한다.
        return nil
    }
}
