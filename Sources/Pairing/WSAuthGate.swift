import Foundation
import Security

/// P6a WS 인증 2단 게이트의 carry-over 상태 저장소.
///
/// 게이트 ①(핸드셰이크 `setClientRequestHandler`)이 헤더 Bearer를 구조 분해해
/// 일회성 nonce를 키로 `(tokenId, presentedSecret)`를 등록하고, 게이트 ②(첫
/// envelope)가 echo된 nonce로 그 항목만 원자 소비해 secret 대조로 승격한다.
///
/// 설계 의도(왜 nonce 키 carry-over인가): `setClientRequestHandler`는 connection
/// 객체를 받지 않아 "핸드셰이크에서 본 Bearer"를 `accept`가 발급하는 clientId와
/// 직접 묶을 다리가 없다. 그래서 클라이언트가 연결마다 생성한 일회성 nonce를
/// 매개로, 핸드셰이크에서 등록한 항목을 첫 envelope이 echo한 nonce로 지목·소비하게
/// 한다. 토큰·secret은 핸드셰이크 헤더로만 운반되고 첫 envelope에는 nonce만 echo한다.
///
/// 동시성: `pendingAuth`는 핸드셰이크 큐(게이트 ①, actor 외부 동기 클로저)와 WSServer
/// actor 컨텍스트(게이트 ②, async) 양쪽에서 접근된다. `setClientRequestHandler` 클로저는
/// 동기라 actor await를 쓸 수 없으므로, 상태는 내부 `NSLock`으로 보호하고 actor 메서드와
/// 동기 핸드셰이크 메서드가 그 단일 락 코어를 공유한다. `presentedSecret`은 consume 또는
/// 만료 즉시 폐기(참조 해제)하고 어떤 경로로도 로그하지 않는다.
public actor WSAuthGate {

    /// 게이트 ① 핸드셰이크 클로저(`setClientRequestHandler`)가 부착되는 큐.
    /// `makeListenerParameters` 안에서 `ws.setClientRequestHandler(authGate.queue)`로 쓴다.
    ///
    /// nonisolated: actor 외부의 @Sendable 핸드셰이크 클로저가 동기 컨텍스트에서 읽어야
    /// 하므로 actor 격리에서 제외한다(불변 let이라 race-free).
    public nonisolated let queue: DispatchQueue

    /// 핸드셰이크 큐와 actor 양쪽에서 공유되는 락 보호 저장소. actor 격리만으로는 동기
    /// 핸드셰이크 클로저를 커버하지 못하므로 내부 NSLock으로 상태를 직접 보호한다.
    private nonisolated let store: PendingStore

    public init(queue: DispatchQueue = DispatchQueue(label: "com.choms0521.ClaudeAlarmTerminal.ws-auth-gate")) {
        self.queue = queue
        self.store = PendingStore()
    }

    // MARK: - 게이트 ① (핸드셰이크 큐, 동기 nonisolated)

    /// 게이트 ①: 중복 nonce 확인 후 carry한다. 이미 등록된 nonce면 등록 없이 false를
    /// 반환해 핸드셰이크를 reject하게 한다(클라이언트가 새 nonce로 재시도). 락 안에서
    /// 중복 검사+등록을 원자적으로 수행해 동시 핸드셰이크의 nonce 경쟁을 차단한다.
    ///
    /// nonisolated: 핸드셰이크 큐의 동기 @Sendable 클로저에서 호출되므로 actor 격리에서 제외한다.
    @discardableResult
    public nonisolated func handshakeRegister(nonce: String, tokenId: String, secret: Data) -> Bool {
        store.registerIfAbsent(nonce: nonce, tokenId: tokenId, secret: secret, at: Date())
    }

    /// 게이트 ①: 이미 등록된 nonce인지 확인한다(테스트/진단용 — 등록은 handshakeRegister가 원자 처리).
    public nonisolated func isNonceRegistered(_ nonce: String) -> Bool {
        store.isRegistered(nonce)
    }

    /// 게이트 ①: 구조 검증을 통과한 `(tokenId, presentedSecret)`를 nonce를 키로 등록한다.
    /// 중복 검사 없이 무조건 등록한다. (handshakeRegister가 중복 차단 경로다.)
    public nonisolated func registerPending(nonce: String, tokenId: String, secret: Data, at: Date) {
        store.register(nonce: nonce, tokenId: tokenId, secret: secret, at: at)
    }

    // MARK: - 게이트 ② (actor 컨텍스트, async)

    /// 게이트 ②: echo된 nonce와 일치하는 등록 항목만 원자 소비한다(1회 소비, replay 방지).
    /// `within` 시간창을 넘긴 항목은 삭제하고 nil을 반환한다. 일치 항목이 없어도 nil.
    ///
    /// 소비 또는 만료 시 항목은 즉시 맵에서 제거되어 `presentedSecret` 참조가 해제된다.
    /// 만료 항목 청소 경로(나머지 stale 항목 일괄 제거)도 매 호출마다 수행한다.
    public func consumePending(nonce: String, within: TimeInterval) -> (tokenId: String, secret: Data)? {
        store.consume(nonce: nonce, within: within, now: Date())
    }

    // MARK: - 구조 분해 + nonce 생성 (nonisolated 순수 헬퍼)

    /// 게이트 ①: Bearer 문자열을 `(tokenId, presentedSecret)`로 구조 분해한다.
    /// 형식은 `tokenId.secretBase64url`이며 secret은 base64url 디코드한 raw bytes다.
    /// 구조가 어긋나면(점 구분자 누락, 빈 컴포넌트, base64url 위반 등) nil을 반환해
    /// 핸드셰이크를 reject하게 한다. Keychain 조회·secret 대조는 여기서 하지 않는다(게이트 ②로 지연).
    ///
    /// nonisolated: 핸드셰이크 큐의 동기 클로저에서 호출되므로 actor 격리에서 제외한다(순수 함수).
    public nonisolated func structurallySplit(_ bearer: String?) -> (tokenId: String, secret: Data)? {
        guard let bearer else { return nil }
        // `tokenId.secret` — 정확히 2개 컴포넌트, 둘 다 비어 있으면 안 된다.
        let parts = bearer.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let tokenId = String(parts[0])
        let secretB64 = String(parts[1])
        guard !tokenId.isEmpty, !secretB64.isEmpty else { return nil }
        guard let secret = Base64URL.decode(secretB64) else { return nil }
        return (tokenId: tokenId, secret: secret)
    }

    /// 연결마다 신규 무작위 nonce를 생성한다(SecRandomCopyBytes 16바이트 → base64url).
    /// 클라이언트와 동일한 형식 규약이라 서버 측 형식 검증과 일치한다.
    public nonisolated static func makeNonce() -> String? {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return nil
        }
        return Base64URL.encode(Data(bytes))
    }

    /// nonce 형식 검증: 16바이트 base64url(디코드 시 정확히 16바이트). 형식 위반은 reject 대상.
    public nonisolated static func isValidNonce(_ nonce: String?) -> Bool {
        guard let nonce, !nonce.isEmpty else { return false }
        guard let decoded = Base64URL.decode(nonce) else { return false }
        return decoded.count == 16
    }
}

/// `pendingAuth` 락 보호 코어. 핸드셰이크 큐(동기)와 actor(async) 양쪽이 같은 인스턴스를
/// 공유하므로 NSLock으로 모든 접근을 직렬화한다. secret은 consume/만료 즉시 제거된다.
private final class PendingStore: @unchecked Sendable {
    private struct PendingEntry {
        let tokenId: String
        let secret: Data
        let registeredAt: Date
    }

    private let lock = NSLock()
    private var pendingAuth: [String: PendingEntry] = [:]

    /// 중복 검사+등록을 원자적으로 수행한다. 이미 있으면 등록하지 않고 false.
    func registerIfAbsent(nonce: String, tokenId: String, secret: Data, at: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if pendingAuth[nonce] != nil { return false }
        pendingAuth[nonce] = PendingEntry(tokenId: tokenId, secret: secret, registeredAt: at)
        return true
    }

    /// 중복 검사 없이 등록한다(handshakeRegister가 표준 경로, 이건 보조).
    func register(nonce: String, tokenId: String, secret: Data, at: Date) {
        lock.lock(); defer { lock.unlock() }
        pendingAuth[nonce] = PendingEntry(tokenId: tokenId, secret: secret, registeredAt: at)
    }

    func isRegistered(_ nonce: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return pendingAuth[nonce] != nil
    }

    /// nonce 일치 항목을 1회 소비한다. 시간창 초과 항목은 삭제·미소비. 매 호출 stale 청소.
    func consume(nonce: String, within: TimeInterval, now: Date) -> (tokenId: String, secret: Data)? {
        lock.lock(); defer { lock.unlock() }
        // stale 항목 일괄 제거(만료 secret 참조 폐기).
        for (key, entry) in pendingAuth where now.timeIntervalSince(entry.registeredAt) > within {
            pendingAuth.removeValue(forKey: key)
        }
        // 1회 소비: 꺼내면서 제거. 같은 nonce 재사용 시 항목 없음 → nil(replay 방지).
        guard let entry = pendingAuth.removeValue(forKey: nonce) else { return nil }
        guard now.timeIntervalSince(entry.registeredAt) <= within else { return nil }
        return (tokenId: entry.tokenId, secret: entry.secret)
    }
}
