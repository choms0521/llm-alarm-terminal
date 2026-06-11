import XCTest
import Foundation
import Network

/// P6a Day 4 — 6자리 코드 페어링 e2e(실 loopback 소켓).
///
/// Day 4 종료 조건을 실측한다:
/// - 전 경로: 코드 발급 → pairing.claim → PairingPayload 수신 → 받은 secret으로 새 인증
///   연결 → session.start(/bin/cat) → input "가나다" → output echo 수신
/// - rate-limit: 동일 코드 5회 오claim 후 6회째 거부 + 만료 코드 claim 거부
/// - replay/재페어링: 성공한 코드 재claim PAIRING_CODE_INVALID + 동일 deviceId 재페어링 후
///   옛 secret 인증 실패
/// - claim 비승격: claim 성공한 그 연결로 운영 envelope 송신 → UNAUTHORIZED
final class PairingE2ETests: XCTestCase {
    private let clientActor = EnvelopeActor(deviceId: "pairing-e2e-client")

    /// in-process 데몬(WSServer + PairingSession + store) + 디바이스 1개 발급·등록을 구성한다.
    /// payload에는 발급된 secret을 담아 코드에 묶는다(claim 성공 시 디바이스가 이 secret으로
    /// 인증 connect를 맺는다). ttl/maxClaimAttempts/now는 테스트가 주입한다.
    private struct PairFixture {
        let server: WSServer
        let registry: SessionBindRegistry
        let store: InMemoryDeviceStore
        let pairingSession: PairingSession
        let deviceId: UUID
        let tokenId: String
        let secretBase64url: String
        let port: UInt16
        let code: String
    }

    private func makePairFixture(
        ttl: TimeInterval = 300,
        maxClaimAttempts: Int = 5,
        now: @escaping @Sendable () -> Date = { Date() }
    ) async throws -> PairFixture {
        let registry = SessionBindRegistry()
        let store = InMemoryDeviceStore()
        let verifier = DeviceTokenVerifier(store: store)
        let pairingSession = PairingSession(ttl: ttl, maxClaimAttempts: maxClaimAttempts, now: now)
        let server = WSServer(registry: registry, authGate: WSAuthGate(),
                              verifier: verifier, pairingSession: pairingSession)
        let port = try await server.start()

        let deviceId = UUID()
        let issued = try DeviceTokenIssuer.issue()
        let device = Device(id: deviceId, name: "e2e-device", tokenId: issued.tokenId,
                            expiresAt: Date().addingTimeInterval(3600))
        try await store.upsert(device, secret: issued.secret)

        let payload = PairingPayload(
            pairingId: UUID().uuidString,
            deviceTokenSecret: issued.secretBase64url,
            wsEndpoint: "ws://127.0.0.1:\(port)/",
            pushChannelHint: "mock-e2e",
            expiresAt: now().addingTimeInterval(ttl)
        )
        let code = try await pairingSession.issue(payload: payload)

        return PairFixture(server: server, registry: registry, store: store,
                           pairingSession: pairingSession, deviceId: deviceId,
                           tokenId: issued.tokenId, secretBase64url: issued.secretBase64url,
                           port: port, code: code)
    }

    /// 외부 /bin/cat 세션을 server에 연결한다(인증 라운드트립의 echo source).
    private func attachCatSession(_ fx: PairFixture) throws {
        let handle = try PTYSpawner.spawn(command: "/bin/cat", args: [], cwd: "/tmp",
                                          env: ProcessInfo.processInfo.environment, rows: 24, cols: 80)
        let daemon = SessionDaemon()
        Task { await attachExternalSession(server: fx.server, daemon: daemon, masterFD: handle.masterFD) }
    }

    // MARK: - 종료 조건: 전 경로 e2e

    func testFullPairingThenAuthenticatedRoundtrip() async throws {
        let fx = try await makePairFixture()
        defer { Task { await fx.server.stop() } }
        try attachCatSession(fx)

        // (1) 시뮬레이션 디바이스가 pre-auth claim 연결로 코드 제출 → payload 수신.
        let claimClient = PairingClaimClient(port: fx.port)
        let outcome = await claimClient.claim(code: fx.code)
        guard case let .success(received) = outcome else {
            return XCTFail("claim이 성공해야 한다 — \(outcome)")
        }
        XCTAssertEqual(received.deviceTokenSecret, fx.secretBase64url,
                       "claim payload는 발급된 secret을 담아야 한다")

        // (2) 받은 secret으로 새 인증 연결 → session.start → "가나다" echo.
        let bearer = "\(fx.tokenId).\(received.deviceTokenSecret)"
        let client = WSClient(port: fx.port, bearerToken: bearer)
        try await client.connect()
        let received2 = E2EStore()
        client.receiveLoop { env in
            if env.kind == .output, let text = env.payloadText { received2.append(text) }
            if env.kind == .ack { received2.appendAck() }
        }
        let sessionId = UUID()
        client.send(WSEnvelope(seq: 1, actor: clientActor, kind: .sessionStart,
                               text: client.firstSessionStartPayload(sessionId: sessionId)))
        let acked = await poll(timeout: 5) { received2.sawAck() }
        XCTAssertTrue(acked, "인증 연결의 session.start는 ack을 받아야 한다")

        client.send(WSEnvelope(seq: 2, actor: clientActor, kind: .input, text: "가나다\n"))
        let echoed = await poll(timeout: 5) { received2.joined().contains("가나다") }
        XCTAssertTrue(echoed, "페어링 후 인증 라운드트립에서 \"가나다\" echo를 받아야 한다")
        client.close()
        await fx.server.stop()
    }

    // MARK: - 종료 조건: rate-limit + 만료

    func testRateLimitAndExpiredClaimRejected() async throws {
        // 5회 오claim 후 코드 폐기 → 6회째 거부. PairingSession 단위로 측정(소켓 왕복 불요).
        let fx = try await makePairFixture(maxClaimAttempts: 5)
        defer { Task { await fx.server.stop() } }

        // 1~4회 오claim: 코드 살아 있음.
        for _ in 0..<4 {
            let r = await fx.pairingSession.claim(code: "000000")
            XCTAssertNil(r, "오claim은 nil이어야 한다")
        }
        let after4 = await fx.pairingSession.lastRejectCode
        XCTAssertEqual(after4, PairingSession.RejectCode.invalid.rawValue,
                       "4회 오claim 후 사유는 INVALID여야 한다")

        // 5회째 오claim: 한도 도달 → 코드 폐기 + RATE_LIMITED.
        let fifth = await fx.pairingSession.claim(code: "000000")
        XCTAssertNil(fifth)
        let after5 = await fx.pairingSession.lastRejectCode
        XCTAssertEqual(after5, PairingSession.RejectCode.rateLimited.rawValue,
                       "5회째 오claim은 RATE_LIMITED여야 한다")

        // 6회째 claim: 활성 코드 없음 → INVALID. 정답 코드를 줘도 이미 폐기됐다.
        let sixth = await fx.pairingSession.claim(code: fx.code)
        XCTAssertNil(sixth, "폐기된 코드는 정답이어도 claim 불가")
        let after6 = await fx.pairingSession.lastRejectCode
        XCTAssertEqual(after6, PairingSession.RejectCode.invalid.rawValue,
                       "6회째는 활성 코드 부재로 INVALID")

        // 만료 코드 거부: now를 ttl 이후로 주입한 별도 fixture.
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let clock = ClockBox(now: t0)
        let expFx = try await makePairFixture(ttl: 300, now: { clock.value })
        defer { Task { await expFx.server.stop() } }
        clock.value = t0.addingTimeInterval(301)   // 만료 1초 후
        let expired = await expFx.pairingSession.claim(code: expFx.code)
        XCTAssertNil(expired, "만료 코드 claim은 거부돼야 한다")
        let expCode = await expFx.pairingSession.lastRejectCode
        XCTAssertEqual(expCode, PairingSession.RejectCode.expired.rawValue,
                       "만료 코드 사유는 EXPIRED여야 한다")
        await expFx.server.stop()
    }

    // MARK: - 종료 조건: replay + 재페어링

    func testReplayRejectedAndRepairingInvalidatesOldSecret() async throws {
        let fx = try await makePairFixture()
        defer { Task { await fx.server.stop() } }

        // (a) replay: 성공한 코드를 재claim하면 1회 소비됐으므로 INVALID.
        let first = await fx.pairingSession.claim(code: fx.code)
        XCTAssertNotNil(first, "최초 claim은 성공해야 한다")
        let replay = await fx.pairingSession.claim(code: fx.code)
        XCTAssertNil(replay, "성공한 코드 재claim은 INVALID(1회 소비)여야 한다")
        let replayCode = await fx.pairingSession.lastRejectCode
        XCTAssertEqual(replayCode, PairingSession.RejectCode.invalid.rawValue,
                       "재claim 사유는 INVALID여야 한다")

        // (b) 재페어링: 동일 deviceId를 새 tokenId/secret으로 upsert하면 옛 secret이 폐기되어
        //     옛 tokenId로는 검증 실패.
        let verifier = DeviceTokenVerifier(store: fx.store)
        let oldSecret = Base64URL.decode(fx.secretBase64url)!
        let stillValid = await verifier.verify(tokenId: fx.tokenId, presentedSecret: oldSecret)
        XCTAssertNotNil(stillValid, "재페어링 전에는 옛 secret이 유효해야 한다")

        let reissued = try DeviceTokenIssuer.issue()
        let rePaired = Device(id: fx.deviceId, name: "e2e-device", tokenId: reissued.tokenId,
                              expiresAt: Date().addingTimeInterval(3600))
        try await fx.store.upsert(rePaired, secret: reissued.secret)

        let oldAfterRepair = await verifier.verify(tokenId: fx.tokenId, presentedSecret: oldSecret)
        XCTAssertNil(oldAfterRepair, "재페어링 후 옛 secret 인증은 실패해야 한다")
        let newValid = await verifier.verify(tokenId: reissued.tokenId, presentedSecret: reissued.secret)
        XCTAssertNotNil(newValid, "재페어링 후 새 secret 인증은 성공해야 한다")
        await fx.server.stop()
    }

    // MARK: - 종료 조건: claim 비승격

    func testClaimDoesNotPromoteConnection() async throws {
        let fx = try await makePairFixture()
        defer { Task { await fx.server.stop() } }

        // claim 전용 연결을 직접 구성해 claim 성공 후 같은 연결로 운영 envelope을 보낸다.
        let client = RawClaimClient(port: fx.port)
        try await client.connectReady()

        // (1) claim 제출 → pairing.response 수신.
        client.send(WSEnvelope(seq: 1, actor: clientActor, kind: .pairingClaim,
                               text: #"{"code":"\#(fx.code)"}"#))
        let gotResponse = await client.waitForKind(.pairingResponse, timeout: 5)
        XCTAssertTrue(gotResponse, "claim 성공 시 pairing.response를 받아야 한다")

        // (2) 같은 연결로 운영 envelope(session.start) 송신 → 연결 미승격이라 UNAUTHORIZED.
        client.send(WSEnvelope(seq: 2, actor: clientActor, kind: .sessionStart,
                               text: #"{"sessionId":"\#(UUID().uuidString)"}"#))
        let unauthorized = await client.waitForError(code: "UNAUTHORIZED", timeout: 5)
        XCTAssertTrue(unauthorized, "claim 연결로 운영 envelope을 보내면 UNAUTHORIZED여야 한다(미승격)")
        client.close()
        await fx.server.stop()
    }

    // MARK: - 헬퍼

    private func poll(timeout: TimeInterval, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }
}

/// output/ack 수집기.
private final class E2EStore: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    private var ack = false
    func append(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    func appendAck() { lock.lock(); ack = true; lock.unlock() }
    func joined() -> String { lock.lock(); defer { lock.unlock() }; return items.joined() }
    func sawAck() -> Bool { lock.lock(); defer { lock.unlock() }; return ack }
}

/// claim 전용 연결을 직접 제어하는 테스트 클라이언트(claim 후 같은 연결로 추가 송신 가능).
/// PairingClaimClient는 응답 1개 후 연결을 닫으므로, 비승격 검증에는 raw 클라이언트가 필요하다.
private final class RawClaimClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "raw-claim-test-client")
    private let received = E2EEnvelopeStore()

    init(port: UInt16) {
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.setAdditionalHeaders([(name: "X-Pair-Claim", value: "1")])
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        let url = URL(string: "ws://127.0.0.1:\(port)/")!
        connection = NWConnection(to: .url(url), using: params)
    }

    func connectReady(timeout: TimeInterval = 5) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let resumed = E2EOnce()
            connection.stateUpdateHandler = { state in
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
        connection.receiveMessage { [weak self] content, _, _, error in
            guard let self else { return }
            if let content, let env = try? EnvelopeCodec.decode(content) {
                self.received.append(env)
            }
            if error == nil { self.receiveLoop() }
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

private final class E2EEnvelopeStore: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [WSEnvelope] = []
    func append(_ env: WSEnvelope) { lock.lock(); items.append(env); lock.unlock() }
    func all() -> [WSEnvelope] { lock.lock(); defer { lock.unlock() }; return items }
}

private final class E2EOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
