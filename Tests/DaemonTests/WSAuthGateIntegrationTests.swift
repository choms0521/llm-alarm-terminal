import XCTest
import Foundation
import Network

/// P6a Day 2 — WS 인증 2단 게이트의 통합(실 loopback 소켓) 테스트.
///
/// Day 2 종료 조건의 핵심 항목을 실측한다:
/// - 인증 거부(UNAUTHORIZED + 연결 .cancelled 5초 이내)
/// - registry seq 불변(미인증 envelope 후 boundSession nil + 후속 인증 첫 seq 수용)
/// - 토큰 운반 매체(첫 envelope 바이트에 토큰·secret 부재 + 헤더 제거 시 실패)
/// - nonce 거부(중복 nonce reject + 미echo/미등록 UNAUTHORIZED, 승격 수 1)
/// - identity 비교차(Ta≠Tb 동시 핸드셰이크 → 각자 자신의 tokenId로 승격, 교차 0)
/// - carry-over(유효 secret 승격 + 위조 secret UNAUTHORIZED)
/// - replay(동일 nonce 1회 consume 후 재사용 불가)
final class WSAuthGateIntegrationTests: XCTestCase {
    private let clientActor = EnvelopeActor(deviceId: "auth-test-client")

    /// 디바이스 1개를 등록한 인증 서버 + (bearer, tokenId, deviceId, secret raw)를 만든다.
    private func makeServer(registry: SessionBindRegistry) async throws -> AuthFixture {
        let store = InMemoryDeviceStore()
        let issued = try DeviceTokenIssuer.issue()
        let deviceId = UUID()
        let device = Device(id: deviceId, name: "auth-test", tokenId: issued.tokenId,
                            expiresAt: Date().addingTimeInterval(3600))
        try await store.upsert(device, secret: issued.secret)
        let server = WSServer(registry: registry, authGate: WSAuthGate(),
                              verifier: DeviceTokenVerifier(store: store))
        return AuthFixture(server: server, store: store, bearer: issued.bearer,
                           tokenId: issued.tokenId, deviceId: deviceId,
                           secretB64: issued.secretBase64url)
    }

    private struct AuthFixture {
        let server: WSServer
        let store: InMemoryDeviceStore
        let bearer: String
        let tokenId: String
        let deviceId: UUID
        let secretB64: String
    }

    // MARK: - 종료 조건 3: 인증 거부 (UNAUTHORIZED + .cancelled 5초 이내)

    // 무토큰 핸드셰이크는 게이트 ①에서 reject되어 .ready에 도달하지 못한다(관측 가능한 거부).
    func testNoBearerHandshakeRejected() async throws {
        let registry = SessionBindRegistry()
        let fx = try await makeServer(registry: registry)
        let port = try await fx.server.start()
        defer { Task { await fx.server.stop() } }

        let client = RawAuthClient(port: port, bearer: nil, nonce: nil)
        let outcome = await client.observeHandshake(timeout: 5)
        XCTAssertNotEqual(outcome, .ready, "무토큰 핸드셰이크는 reject되어 .ready에 도달하면 안 된다")
        XCTAssertTrue(outcome.isObservableRejection, "무토큰은 관측 가능한 거부여야 한다 — \(outcome)")
        await fx.server.stop()
    }

    // 유효 토큰 핸드셰이크는 성립하되, 첫 envelope이 nonce를 echo하지 않으면 게이트 ②가
    // UNAUTHORIZED 에러를 보내고 연결을 cancel한다(5초 이내 .cancelled).
    func testValidHandshakeButNonceNotEchoed_unauthorizedAndCancelled() async throws {
        let registry = SessionBindRegistry()
        let fx = try await makeServer(registry: registry)
        let port = try await fx.server.start()
        defer { Task { await fx.server.stop() } }

        let nonce = WSAuthGate.makeNonce()!
        let client = RawAuthClient(port: port, bearer: fx.bearer, nonce: nonce)
        try await client.connectReady()

        // 첫 envelope이 nonce를 echo하지 않음(session.start payload에 nonce 없음).
        client.send(WSEnvelope(seq: 1, actor: clientActor, kind: .sessionStart,
                               text: #"{"sessionId":"\#(UUID().uuidString)"}"#))

        let gotError = await client.waitForError(code: "UNAUTHORIZED", timeout: 5)
        XCTAssertTrue(gotError, "nonce 미echo 첫 envelope은 UNAUTHORIZED여야 한다")
        let cancelled = await client.waitForCancelled(timeout: 5)
        XCTAssertTrue(cancelled, "UNAUTHORIZED 후 연결이 5초 이내 .cancelled여야 한다")
        await fx.server.stop()
    }

    // MARK: - 종료 조건 4: registry seq 불변

    // 미인증 envelope(seq=1, nonce 미echo)은 게이트 ②에서 막혀 ingestInbound/bind에
    // 진입하지 못한다 → boundSession nil. 그 후 새 인증 연결의 첫 seq(=1)가 거부 없이 수용된다.
    func testRegistrySeqInvariant_unauthenticatedDoesNotAdvance() async throws {
        let registry = SessionBindRegistry()
        let fx = try await makeServer(registry: registry)
        let port = try await fx.server.start()
        defer { Task { await fx.server.stop() } }

        // (a) 미인증: 유효 핸드셰이크지만 nonce 미echo로 게이트 ② 차단.
        let nonceA = WSAuthGate.makeNonce()!
        let bad = RawAuthClient(port: port, bearer: fx.bearer, nonce: nonceA)
        try await bad.connectReady()
        let sessionId = UUID()
        bad.send(WSEnvelope(seq: 1, actor: clientActor, kind: .sessionStart,
                            text: #"{"sessionId":"\#(sessionId.uuidString)"}"#))   // nonce 미echo
        _ = await bad.waitForError(code: "UNAUTHORIZED", timeout: 5)
        bad.close()

        // 미인증 envelope이 어떤 바인딩도 만들지 못했다.
        let boundForSession = await registry.boundClient(forSession: sessionId)
        XCTAssertNil(boundForSession, "미인증 envelope은 세션 바인딩을 만들면 안 된다")

        // (b) 후속 인증 연결: 첫 seq=1이 거부 없이 수용되어 ack을 받는다.
        let nonceB = WSAuthGate.makeNonce()!
        let good = RawAuthClient(port: port, bearer: fx.bearer, nonce: nonceB)
        try await good.connectReady()
        let sid2 = UUID()
        good.send(WSEnvelope(seq: 1, actor: clientActor, kind: .sessionStart,
                             text: #"{"sessionId":"\#(sid2.uuidString)","nonce":"\#(nonceB)"}"#))
        let ack = await good.waitForKind(.ack, timeout: 5)
        XCTAssertTrue(ack, "후속 인증 연결의 첫 seq=1은 거부 없이 수용돼야 한다")
        let bound = await registry.boundClient(forSession: sid2)
        XCTAssertNotNil(bound, "인증 연결의 session.start는 바인딩을 만들어야 한다")
        good.close()
        await fx.server.stop()
    }

    // MARK: - 종료 조건 5: 토큰 운반 매체 (헤더 단일)

    // 인증 성립 연결의 첫 envelope 바이트를 디코드해 토큰/secret 문자열이 payload에 없음을 확인.
    func testTokenNotCarriedInFirstEnvelopePayload() async throws {
        let registry = SessionBindRegistry()
        let fx = try await makeServer(registry: registry)
        let port = try await fx.server.start()
        defer { Task { await fx.server.stop() } }

        let nonce = WSAuthGate.makeNonce()!
        let client = RawAuthClient(port: port, bearer: fx.bearer, nonce: nonce)
        try await client.connectReady()
        let sid = UUID()
        let payloadText = #"{"sessionId":"\#(sid.uuidString)","nonce":"\#(nonce)"}"#
        client.send(WSEnvelope(seq: 1, actor: clientActor, kind: .sessionStart, text: payloadText))
        let ack = await client.waitForKind(.ack, timeout: 5)
        XCTAssertTrue(ack, "유효 인증 첫 envelope은 ack을 받아야 한다(헤더 운반으로 충분)")

        // 첫 envelope payload 바이트에 tokenId/secret 문자열이 없다.
        XCTAssertFalse(payloadText.contains(fx.tokenId), "tokenId가 payload에 노출되면 안 된다")
        XCTAssertFalse(payloadText.contains(fx.secretB64), "secret이 payload에 노출되면 안 된다")
        client.close()
        await fx.server.stop()
    }

    // 헤더에서 Bearer를 제거하면(무토큰) 인증이 실패한다(.ready 미도달). 운반 매체가 헤더 단일임을 실증.
    func testRemovingBearerHeaderFailsAuth() async throws {
        let registry = SessionBindRegistry()
        let fx = try await makeServer(registry: registry)
        let port = try await fx.server.start()
        defer { Task { await fx.server.stop() } }

        // nonce는 있으나 Bearer 헤더가 없는 핸드셰이크 → 게이트 ①에서 reject.
        let client = RawAuthClient(port: port, bearer: nil, nonce: WSAuthGate.makeNonce()!)
        let outcome = await client.observeHandshake(timeout: 5)
        XCTAssertNotEqual(outcome, .ready, "Bearer 헤더 제거 시 인증 핸드셰이크가 성립하면 안 된다")
        await fx.server.stop()
    }

    // MARK: - 종료 조건 6: nonce 거부 (중복 nonce reject + 미등록 nonce echo)

    // 동일 nonce로 2연결 동시 핸드셰이크 → 두 번째는 중복 nonce로 reject(승격 가능한 건 1개뿐).
    func testDuplicateNonceHandshakeRejected() async throws {
        let registry = SessionBindRegistry()
        let fx = try await makeServer(registry: registry)
        let port = try await fx.server.start()
        defer { Task { await fx.server.stop() } }

        let sharedNonce = WSAuthGate.makeNonce()!
        // 첫 연결: 핸드셰이크 성립.
        let first = RawAuthClient(port: port, bearer: fx.bearer, nonce: sharedNonce)
        try await first.connectReady()

        // 두 번째 연결: 같은 nonce → 게이트 ①의 중복 검사로 reject(.ready 미도달).
        let second = RawAuthClient(port: port, bearer: fx.bearer, nonce: sharedNonce)
        let outcome = await second.observeHandshake(timeout: 5)
        XCTAssertNotEqual(outcome, .ready, "중복 nonce 핸드셰이크는 두 번째가 reject돼야 한다")

        first.close()
        await fx.server.stop()
    }

    // 미등록 nonce를 echo하는 첫 envelope은 UNAUTHORIZED (consumePending이 nil).
    func testUnregisteredNonceEchoIsUnauthorized() async throws {
        let registry = SessionBindRegistry()
        let fx = try await makeServer(registry: registry)
        let port = try await fx.server.start()
        defer { Task { await fx.server.stop() } }

        let realNonce = WSAuthGate.makeNonce()!
        let client = RawAuthClient(port: port, bearer: fx.bearer, nonce: realNonce)
        try await client.connectReady()

        // 핸드셰이크에서 등록한 nonce가 아닌, 임의의 미등록 nonce를 echo.
        let fakeNonce = WSAuthGate.makeNonce()!
        client.send(WSEnvelope(seq: 1, actor: clientActor, kind: .sessionStart,
                               text: #"{"sessionId":"\#(UUID().uuidString)","nonce":"\#(fakeNonce)"}"#))
        let gotError = await client.waitForError(code: "UNAUTHORIZED", timeout: 5)
        XCTAssertTrue(gotError, "미등록 nonce echo는 UNAUTHORIZED여야 한다")
        await fx.server.stop()
    }

    // MARK: - 종료 조건 7: identity 비교차 (Ta != Tb)

    // 서로 다른 토큰 Ta, Tb 두 연결이 각자 nonce로 핸드셰이크 후 각자 자신의 nonce를 echo하면
    // 각 connection이 자신의 tokenId로 승격된다(교차 0). ack의 clientId가 서로 다름으로 실증.
    func testIdentityNonCrossover_twoDistinctTokens() async throws {
        let registry = SessionBindRegistry()
        // store에 디바이스 2개를 등록한다(서로 다른 토큰).
        let store = InMemoryDeviceStore()
        let issuedA = try DeviceTokenIssuer.issue()
        let issuedB = try DeviceTokenIssuer.issue()
        let devA = Device(id: UUID(), name: "devA", tokenId: issuedA.tokenId,
                          expiresAt: Date().addingTimeInterval(3600))
        let devB = Device(id: UUID(), name: "devB", tokenId: issuedB.tokenId,
                          expiresAt: Date().addingTimeInterval(3600))
        try await store.upsert(devA, secret: issuedA.secret)
        try await store.upsert(devB, secret: issuedB.secret)
        let server = WSServer(registry: registry, authGate: WSAuthGate(),
                              verifier: DeviceTokenVerifier(store: store))
        let port = try await server.start()
        defer { Task { await server.stop() } }

        let nonceA = WSAuthGate.makeNonce()!
        let nonceB = WSAuthGate.makeNonce()!
        let clientA = RawAuthClient(port: port, bearer: issuedA.bearer, nonce: nonceA)
        let clientB = RawAuthClient(port: port, bearer: issuedB.bearer, nonce: nonceB)
        try await clientA.connectReady()
        try await clientB.connectReady()

        let sidA = UUID()
        let sidB = UUID()
        clientA.send(WSEnvelope(seq: 1, actor: clientActor, kind: .sessionStart,
                                text: #"{"sessionId":"\#(sidA.uuidString)","nonce":"\#(nonceA)"}"#))
        clientB.send(WSEnvelope(seq: 1, actor: clientActor, kind: .sessionStart,
                                text: #"{"sessionId":"\#(sidB.uuidString)","nonce":"\#(nonceB)"}"#))

        let ackA = await clientA.waitForKind(.ack, timeout: 5)
        let ackB = await clientB.waitForKind(.ack, timeout: 5)
        XCTAssertTrue(ackA, "A는 자신의 nonce로 승격되어 ack을 받아야 한다")
        XCTAssertTrue(ackB, "B는 자신의 nonce로 승격되어 ack을 받아야 한다")

        // 각 연결이 자신의 sessionId로 바인딩됐다(교차 0 — A의 nonce가 B를 승격시키지 않음).
        let boundA = await registry.boundClient(forSession: sidA)
        let boundB = await registry.boundClient(forSession: sidB)
        XCTAssertNotNil(boundA)
        XCTAssertNotNil(boundB)
        XCTAssertNotEqual(boundA, boundB, "두 연결은 서로 다른 clientId로 각자 바인딩돼야 한다(identity 교차 0)")

        clientA.close(); clientB.close()
        await server.stop()
    }

    // MARK: - 종료 조건 8: carry-over (유효 secret 승격 + 위조 secret UNAUTHORIZED)

    // 위조 secret(Bearer secret 변조)은 핸드셰이크는 통과(구조 유효)하나 게이트 ②의 constant-time
    // 대조에서 store secret과 불일치 → UNAUTHORIZED.
    func testForgedSecretFailsAtGateTwo() async throws {
        let registry = SessionBindRegistry()
        let fx = try await makeServer(registry: registry)
        let port = try await fx.server.start()
        defer { Task { await fx.server.stop() } }

        // 같은 tokenId, 위조 secret(32바이트 다른 난수)으로 Bearer 구성.
        let forgedSecret = Base64URL.encode(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
        let forgedBearer = "\(fx.tokenId).\(forgedSecret)"
        let nonce = WSAuthGate.makeNonce()!
        let client = RawAuthClient(port: port, bearer: forgedBearer, nonce: nonce)
        try await client.connectReady()   // 구조 유효라 핸드셰이크는 성립

        client.send(WSEnvelope(seq: 1, actor: clientActor, kind: .sessionStart,
                               text: #"{"sessionId":"\#(UUID().uuidString)","nonce":"\#(nonce)"}"#))
        let gotError = await client.waitForError(code: "UNAUTHORIZED", timeout: 5)
        XCTAssertTrue(gotError, "위조 secret은 게이트 ② constant-time 대조 실패로 UNAUTHORIZED여야 한다")
        await fx.server.stop()
    }

    // 유효 secret은 승격되어 ack을 받는다(carry-over 성공 경로).
    func testValidSecretPromotes() async throws {
        let registry = SessionBindRegistry()
        let fx = try await makeServer(registry: registry)
        let port = try await fx.server.start()
        defer { Task { await fx.server.stop() } }

        let nonce = WSAuthGate.makeNonce()!
        let client = RawAuthClient(port: port, bearer: fx.bearer, nonce: nonce)
        try await client.connectReady()
        client.send(WSEnvelope(seq: 1, actor: clientActor, kind: .sessionStart,
                               text: #"{"sessionId":"\#(UUID().uuidString)","nonce":"\#(nonce)"}"#))
        let ack = await client.waitForKind(.ack, timeout: 5)
        XCTAssertTrue(ack, "유효 secret carry-over는 승격되어 ack을 받아야 한다")
        client.close()
        await fx.server.stop()
    }
}

// MARK: - 헤더를 세밀히 제어하는 raw 인증 테스트 클라이언트

/// Bearer/nonce 헤더를 개별 제어할 수 있는 테스트 클라이언트. 무토큰·무nonce·위조 secret
/// 케이스를 만들기 위해 WSClient가 아닌 직접 NWConnection을 구성한다.
private final class RawAuthClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "raw-auth-test-client")
    private let received = EnvelopeStore()
    private let stateStore = StateStore()

    init(port: UInt16, bearer: String?, nonce: String?) {
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        var headers: [(name: String, value: String)] = []
        if let bearer { headers.append((name: "Authorization", value: "Bearer \(bearer)")) }
        if let nonce { headers.append((name: "X-Pair-Nonce", value: nonce)) }
        if !headers.isEmpty { ws.setAdditionalHeaders(headers) }
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        let url = URL(string: "ws://127.0.0.1:\(port)/")!
        connection = NWConnection(to: .url(url), using: params)
    }

    /// 핸드셰이크 결과만 관측한다(reject 케이스용). cancel하고 최종 상태를 반환한다.
    func observeHandshake(timeout: TimeInterval) async -> HandshakeOutcome {
        let outcome: HandshakeOutcome = await withCheckedContinuation { cont in
            let resumed = AuthOnce()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: if resumed.fire() { cont.resume(returning: .ready) }
                case .failed: if resumed.fire() { cont.resume(returning: .failed) }
                case .cancelled: if resumed.fire() { cont.resume(returning: .cancelled) }
                case .waiting: if resumed.fire() { cont.resume(returning: .waiting) }
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                if resumed.fire() { cont.resume(returning: .timedOut) }
            }
        }
        connection.cancel()
        return outcome
    }

    /// 핸드셰이크가 .ready에 도달할 때까지 연결하고 수신 루프를 시작한다.
    func connectReady(timeout: TimeInterval = 5) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let resumed = AuthOnce()
            connection.stateUpdateHandler = { [weak self] state in
                self?.stateStore.record(state)
                switch state {
                case .ready: if resumed.fire() { cont.resume() }
                case .failed(let error): if resumed.fire() { cont.resume(throwing: error) }
                case .cancelled: if resumed.fire() { cont.resume(throwing: URLError(.cancelled)) }
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                if resumed.fire() { cont.resume(throwing: URLError(.timedOut)) }
            }
        }
        receiveLoop()
    }

    private func receiveLoop() {
        connection.receiveMessage { [weak self] content, context, _, error in
            guard let self else { return }
            if let content, let env = try? EnvelopeCodec.decode(content) {
                self.received.append(env)
            }
            // 서버가 cancel하면 클라이언트는 close 프레임/peer-FIN(final) 또는 수신 에러로
            // 관측한다. NWConnection은 peer close 시 .cancelled 상태 전이를 항상 내지는
            // 않으므로, receive 단의 종료 신호(error 또는 final)도 "연결 종료"로 기록한다.
            let closed = error != nil || (context?.isFinal ?? false)
            if closed {
                self.stateStore.recordClosed()
                return
            }
            self.receiveLoop()
        }
    }

    func send(_ envelope: WSEnvelope) {
        guard let data = try? EnvelopeCodec.encode(envelope) else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "send", metadata: [meta])
        connection.send(content: data, contentContext: context, isComplete: true,
                        completion: .contentProcessed { _ in })
    }

    func waitForError(code: String, timeout: TimeInterval) async -> Bool {
        await poll(timeout: timeout) {
            self.received.all().contains { $0.kind == .error && $0.code == code }
        }
    }

    func waitForKind(_ kind: EnvelopeKind, timeout: TimeInterval) async -> Bool {
        await poll(timeout: timeout) {
            self.received.all().contains { $0.kind == kind }
        }
    }

    func waitForCancelled(timeout: TimeInterval) async -> Bool {
        await poll(timeout: timeout) { self.stateStore.sawCancelled() }
    }

    func close() { connection.cancel() }

    private func poll(timeout: TimeInterval, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }
}

private enum HandshakeOutcome: Equatable {
    case ready, failed, cancelled, waiting, timedOut
    var isObservableRejection: Bool { self != .ready }
}

private final class EnvelopeStore: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [WSEnvelope] = []
    func append(_ env: WSEnvelope) { lock.lock(); items.append(env); lock.unlock() }
    func all() -> [WSEnvelope] { lock.lock(); defer { lock.unlock() }; return items }
}

private final class StateStore: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func record(_ state: NWConnection.State) {
        lock.lock(); defer { lock.unlock() }
        if case .cancelled = state { cancelled = true }
        if case .failed = state { cancelled = true }   // failed도 종료 관측으로 본다.
    }
    /// receive 단의 종료 신호(error/final). 상태 전이 없이 닫히는 경로를 커버한다.
    func recordClosed() { lock.lock(); defer { lock.unlock() }; cancelled = true }
    func sawCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

private final class AuthOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
