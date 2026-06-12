import XCTest
import Foundation
import Network

/// P6b Day 4 — 토큰 lifecycle 무효화 e2e (만료/revoked WS 거부 + revoked push 제외).
///
/// Day 1~2가 코어 메서드(verifier 거부, disconnectDevice, sendIfNotRevoked)를 단위/통합으로
/// 검증했고, 본 스위트는 그 경로를 in-process 데몬 위에서 e2e로 한 번 통과시킨다 —
/// `DaemonDevCLI --lifecycle`이 stdout으로 내보내는 3 신호(REVOKE_DISCONNECTED/EXPIRED_REJECTED/
/// PUSH_REJECTED_REVOKED)에 대응하는 검증 경로다. 모바일 없이 시뮬레이션 디바이스로 전 경로를 측정한다.
///
/// 측정 대상(계획서 Day 4 종료 조건):
/// - revoked WS 거부: revoke 후 살아 있던 연결 .cancelled + 재connect UNAUTHORIZED
/// - 만료 WS 거부: expiresAt 과거 디바이스 Bearer connect → 게이트 ② UNAUTHORIZED + close
/// - revoked push 제외: revoked 디바이스 target이 발신 필터에서 제외(transport 미호출, excludedCount +1)
final class LifecycleE2ETests: XCTestCase {
    private let clientActor = EnvelopeActor(deviceId: "lifecycle-e2e-client")

    // MARK: - fixture

    /// 디바이스 1개(주어진 expiresAt)를 등록한 인증 서버 + (bearer, deviceId).
    private func makeServerWithDevice(
        expiresAt: Date,
        registry: SessionBindRegistry
    ) async throws -> (server: WSServer, store: InMemoryDeviceStore, bearer: String, deviceId: UUID) {
        let store = InMemoryDeviceStore()
        let issued = try DeviceTokenIssuer.issue()
        let deviceId = UUID()
        let device = Device(id: deviceId, name: "lifecycle-dev", tokenId: issued.tokenId,
                            expiresAt: expiresAt)
        try await store.upsert(device, secret: issued.secret)
        let server = WSServer(registry: registry, authGate: WSAuthGate(),
                              verifier: DeviceTokenVerifier(store: store))
        return (server, store, issued.bearer, deviceId)
    }

    // MARK: - 종료 조건: revoked WS 거부 (cancelled + 재connect UNAUTHORIZED 2건)

    /// 인증 연결 수립 → revoke → 살아 있던 연결 .cancelled + 같은 Bearer 재connect는 게이트 ②
    /// UNAUTHORIZED. CLI --lifecycle "REVOKE_DISCONNECTED" 신호의 e2e 대응 경로다.
    func testRevokedConnectionCancelledAndReconnectUnauthorized() async throws {
        let registry = SessionBindRegistry()
        let (server, store, bearer, deviceId) =
            try await makeServerWithDevice(expiresAt: Date().addingTimeInterval(3600), registry: registry)
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let pushSink = InMemoryPushRevocationSink()
        let coordinator = DeviceRevocationCoordinator(store: store, server: server, pushRevocation: pushSink)

        // 1) 인증 연결 수립 + session.start 바인딩.
        let nonce1 = WSAuthGate.makeNonce()!
        let live = LifecycleE2EClient(port: port, bearer: bearer, nonce: nonce1)
        try await live.connectReady()
        live.send(WSEnvelope(seq: 1, actor: clientActor, kind: .sessionStart,
                             text: #"{"sessionId":"\#(UUID().uuidString)","nonce":"\#(nonce1)"}"#))
        let liveAck = await live.waitForKind(.ack, timeout: 5)
        XCTAssertTrue(liveAck, "인증 연결이 session.start ack을 받아야 한다")

        // 2) revoke → 살아 있던 연결 5초 내 끊김(누출 창 0).
        try await coordinator.revoke(deviceId: deviceId)
        let cancelled = await live.waitForCancelled(timeout: 5)
        XCTAssertTrue(cancelled, "revoke 시 살아 있던 연결이 5초 내 끊겨야 한다")
        live.close()

        // 3) 같은 Bearer 재connect → 게이트 ② UNAUTHORIZED(verifier !revoked 거부).
        let nonce2 = WSAuthGate.makeNonce()!
        let again = LifecycleE2EClient(port: port, bearer: bearer, nonce: nonce2)
        try await again.connectReady()
        again.send(WSEnvelope(seq: 1, actor: clientActor, kind: .sessionStart,
                              text: #"{"sessionId":"\#(UUID().uuidString)","nonce":"\#(nonce2)"}"#))
        let unauthorized = await again.waitForError(code: "UNAUTHORIZED", timeout: 5)
        XCTAssertTrue(unauthorized, "revoked 디바이스 재연결은 게이트 ② UNAUTHORIZED여야 한다")
        again.close()
        await server.stop()
    }

    // MARK: - 종료 조건: 만료 WS 거부 (expiresAt 과거 → UNAUTHORIZED + close)

    /// expiresAt이 과거인 디바이스 Bearer로 connect → 게이트 ②에서 verifier가 만료 거부(UNAUTHORIZED).
    /// CLI --lifecycle "EXPIRED_REJECTED" 신호의 e2e 대응 경로다. 핸드셰이크 게이트 ①(구조 검증)은
    /// 통과하나 게이트 ②(verify expiresAt>now)에서 막힌다.
    func testExpiredDeviceRejectedAtGateTwo() async throws {
        let registry = SessionBindRegistry()
        let (server, _, bearer, _) =
            try await makeServerWithDevice(expiresAt: Date().addingTimeInterval(-3600), registry: registry)
        let port = try await server.start()
        defer { Task { await server.stop() } }

        let nonce = WSAuthGate.makeNonce()!
        let client = LifecycleE2EClient(port: port, bearer: bearer, nonce: nonce)
        try await client.connectReady()
        client.send(WSEnvelope(seq: 1, actor: clientActor, kind: .sessionStart,
                               text: #"{"sessionId":"\#(UUID().uuidString)","nonce":"\#(nonce)"}"#))
        let unauthorized = await client.waitForError(code: "UNAUTHORIZED", timeout: 5)
        XCTAssertTrue(unauthorized, "만료(expiresAt 과거) 디바이스는 게이트 ② UNAUTHORIZED여야 한다")
        let cancelled = await client.waitForCancelled(timeout: 5)
        XCTAssertTrue(cancelled, "UNAUTHORIZED 후 5초 내 연결이 끊겨야 한다(만료 디바이스는 승격 불가)")
        client.close()
        await server.stop()
    }

    // MARK: - 종료 조건: revoked push 제외 (transport 미호출 + excludedCount +1)

    /// Coordinator.revoke ③단계가 markRevoked로 통지한 뒤, PushSender.sendIfNotRevoked가 그 디바이스를
    /// 발신 대상에서 제외한다(transport 미호출). CLI --lifecycle "PUSH_REJECTED_REVOKED" 신호의 e2e
    /// 대응 경로다. 발신 호출자 자체는 D-7로 dead이나, "revoked는 발신 제외" 필터 규약을 e2e로 측정한다.
    func testRevokedDevicePushExcludedFromSend() async throws {
        let registry = SessionBindRegistry()
        let (server, store, _, deviceId) =
            try await makeServerWithDevice(expiresAt: Date().addingTimeInterval(3600), registry: registry)
        defer { Task { await server.stop() } }

        // revoke 전: push 발신은 transport에 도달한다(필터 통과).
        let pushSink = InMemoryPushRevocationSink()
        let transport = MockPushTransport()
        let sender = PushSender(
            transport: transport,
            attachment: AlwaysDetachedAttachment(),
            config: PushPolicyConfig(skipWhenAttached: true),
            revocationSink: pushSink
        )
        await sender.sendIfNotRevoked(makeEnvelope(), target: .fcm, deviceId: deviceId)
        let sentBefore = await transport.sentCount
        XCTAssertEqual(sentBefore, 1, "revoke 전에는 push가 transport에 도달해야 한다")
        let excludedBefore = await sender.excludedCount
        XCTAssertEqual(excludedBefore, 0, "revoke 전에는 제외 카운터가 0이어야 한다")

        // Coordinator.revoke → ③ markRevoked가 push 발신 제외 대상으로 표시한다.
        let coordinator = DeviceRevocationCoordinator(store: store, server: server, pushRevocation: pushSink)
        try await coordinator.revoke(deviceId: deviceId)

        // revoke 후: 같은 디바이스 push 발신은 필터에서 제외된다(transport 미호출, excludedCount +1).
        await sender.sendIfNotRevoked(makeEnvelope(), target: .fcm, deviceId: deviceId)
        let sentAfter = await transport.sentCount
        XCTAssertEqual(sentAfter, 1, "revoke 후 push는 transport에 도달하지 않아야 한다(미호출 — 발신 제외)")
        let excludedAfter = await sender.excludedCount
        XCTAssertEqual(excludedAfter, 1, "revoked 디바이스 발신은 excludedCount가 +1되어야 한다")
        await server.stop()
    }

    // MARK: - 종료 조건: 만료/revoke(WS+push) 전 경로 한 번에 측정 (CLI 3 신호 e2e 대응)

    /// 한 데몬 인스턴스 위에서 revoke WS 거부 + 만료 WS 거부 + revoked push 제외를 순차로 통과시켜,
    /// `DaemonDevCLI --lifecycle`이 내보내는 3 신호 전 경로가 in-process로 성립함을 측정한다.
    func testFullLifecycleInvalidationThreeSignals() async throws {
        let registry = SessionBindRegistry()
        let store = InMemoryDeviceStore()

        // 디바이스 A: 유효(revoke 대상). 디바이스 B: 만료(expiresAt 과거).
        let issuedA = try DeviceTokenIssuer.issue()
        let deviceIdA = UUID()
        try await store.upsert(
            Device(id: deviceIdA, name: "dev-A", tokenId: issuedA.tokenId,
                   expiresAt: Date().addingTimeInterval(3600)),
            secret: issuedA.secret)
        let issuedB = try DeviceTokenIssuer.issue()
        let deviceIdB = UUID()
        try await store.upsert(
            Device(id: deviceIdB, name: "dev-B", tokenId: issuedB.tokenId,
                   expiresAt: Date().addingTimeInterval(-3600)),
            secret: issuedB.secret)

        let server = WSServer(registry: registry, authGate: WSAuthGate(),
                              verifier: DeviceTokenVerifier(store: store))
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let pushSink = InMemoryPushRevocationSink()
        let coordinator = DeviceRevocationCoordinator(store: store, server: server, pushRevocation: pushSink)

        var signals: [String] = []

        // 신호 ① REVOKE_DISCONNECTED: A 인증 연결 → revoke → 끊김.
        let nonceA = WSAuthGate.makeNonce()!
        let liveA = LifecycleE2EClient(port: port, bearer: issuedA.bearer, nonce: nonceA)
        try await liveA.connectReady()
        liveA.send(WSEnvelope(seq: 1, actor: clientActor, kind: .sessionStart,
                              text: #"{"sessionId":"\#(UUID().uuidString)","nonce":"\#(nonceA)"}"#))
        let ackA = await liveA.waitForKind(.ack, timeout: 5)
        XCTAssertTrue(ackA, "A 인증 연결 ack")
        try await coordinator.revoke(deviceId: deviceIdA)
        let cancelledA = await liveA.waitForCancelled(timeout: 5)
        XCTAssertTrue(cancelledA, "revoke 시 A 연결 끊김")
        liveA.close()
        signals.append("REVOKE_DISCONNECTED")

        // 신호 ② EXPIRED_REJECTED: B(만료) connect → 게이트 ② UNAUTHORIZED.
        let nonceB = WSAuthGate.makeNonce()!
        let expiredB = LifecycleE2EClient(port: port, bearer: issuedB.bearer, nonce: nonceB)
        try await expiredB.connectReady()
        expiredB.send(WSEnvelope(seq: 1, actor: clientActor, kind: .sessionStart,
                                 text: #"{"sessionId":"\#(UUID().uuidString)","nonce":"\#(nonceB)"}"#))
        let unauthorizedB = await expiredB.waitForError(code: "UNAUTHORIZED", timeout: 5)
        XCTAssertTrue(unauthorizedB, "만료 디바이스 B는 게이트 ② UNAUTHORIZED")
        expiredB.close()
        signals.append("EXPIRED_REJECTED")

        // 신호 ③ PUSH_REJECTED_REVOKED: revoked A로의 push 발신은 필터에서 제외.
        let transport = MockPushTransport()
        let sender = PushSender(
            transport: transport,
            attachment: AlwaysDetachedAttachment(),
            config: PushPolicyConfig(skipWhenAttached: true),
            revocationSink: pushSink
        )
        await sender.sendIfNotRevoked(makeEnvelope(), target: .fcm, deviceId: deviceIdA)
        let sentA = await transport.sentCount
        XCTAssertEqual(sentA, 0, "revoked A push는 transport 미호출")
        let excludedA = await sender.excludedCount
        XCTAssertEqual(excludedA, 1, "revoked A push는 excludedCount +1")
        signals.append("PUSH_REJECTED_REVOKED")

        // 3 신호 전 경로 성립.
        XCTAssertEqual(signals,
                       ["REVOKE_DISCONNECTED", "EXPIRED_REJECTED", "PUSH_REJECTED_REVOKED"],
                       "만료/revoke(WS+push) 전 경로 3 신호가 모두 측정돼야 한다")
        await server.stop()
    }

    // MARK: - helpers

    private func makeEnvelope() -> PushEnvelope {
        let sid = UUID()
        return PushEnvelope(
            sessionId: sid,
            messageId: UUID(),
            preview: "lifecycle e2e",
            chatRoomId: sid.uuidString,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            fetchHint: nil
        )
    }
}

// MARK: - 항상 detached인 attachment (push 발신 필터를 attached-skip이 가로채지 않게)

/// push가 WS-attached skip 정책에 막히지 않도록 항상 detached를 반환한다. 본 스위트는 "revoked 발신
/// 제외"만 측정하므로 attachment skip은 의도적으로 비활성화한다(deviceId 필터 경로만 격리).
private struct AlwaysDetachedAttachment: AttachmentQuerying {
    func isAttached(_ sessionId: UUID) async -> Bool { false }
}

// MARK: - lifecycle e2e 클라이언트 (Bearer/nonce 헤더 제어 + 끊김/수신 관측)

/// RevocationDisconnectTests의 RevocationTestClient와 동형이나, 본 스위트 내 격리를 위해 별도로 둔다
/// (private 헬퍼는 파일 스코프라 타 스위트와 충돌하지 않는다). Bearer/nonce 헤더를 제어하고
/// 끊김(.cancelled/.failed/peer-FIN)과 수신 envelope을 관측한다.
private final class LifecycleE2EClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "lifecycle-e2e-client")
    private let received = LifecycleReceivedStore()
    private let state = LifecycleStateStore()

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

    func connectReady(timeout: TimeInterval = 5) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = LifecycleOnce()
            connection.stateUpdateHandler = { [weak self] st in
                self?.state.record(st)
                switch st {
                case .ready: if once.fire() { cont.resume() }
                case .failed(let e): if once.fire() { cont.resume(throwing: e) }
                case .cancelled: if once.fire() { cont.resume(throwing: URLError(.cancelled)) }
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                if once.fire() { cont.resume(throwing: URLError(.timedOut)) }
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
            let closed = error != nil || (context?.isFinal ?? false)
            if closed { self.state.recordClosed(); return }
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

    func waitForKind(_ kind: EnvelopeKind, timeout: TimeInterval) async -> Bool {
        await poll(timeout: timeout) { self.received.all().contains { $0.kind == kind } }
    }

    func waitForError(code: String, timeout: TimeInterval) async -> Bool {
        await poll(timeout: timeout) {
            self.received.all().contains { $0.kind == .error && $0.code == code }
        }
    }

    func waitForCancelled(timeout: TimeInterval) async -> Bool {
        await poll(timeout: timeout) { self.state.sawClosed() }
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

private final class LifecycleReceivedStore: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [WSEnvelope] = []
    func append(_ env: WSEnvelope) { lock.lock(); items.append(env); lock.unlock() }
    func all() -> [WSEnvelope] { lock.lock(); defer { lock.unlock() }; return items }
}

private final class LifecycleStateStore: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    func record(_ st: NWConnection.State) {
        lock.lock(); defer { lock.unlock() }
        if case .cancelled = st { closed = true }
        if case .failed = st { closed = true }
    }
    func recordClosed() { lock.lock(); defer { lock.unlock() }; closed = true }
    func sawClosed() -> Bool { lock.lock(); defer { lock.unlock() }; return closed }
}

private final class LifecycleOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
