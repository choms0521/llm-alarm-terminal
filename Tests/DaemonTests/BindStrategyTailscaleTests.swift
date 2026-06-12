import XCTest
import Foundation
import Network

/// P6b Day 2 — BindStrategy 배선(D-1) + Tailscale 진단 + push 발신 제외 검증.
///
/// 측정 대상(계획서 Day 2 종료 조건):
/// - init 기본값 인자 비파괴: strategy 인자 없는 기존 호출부가 컴파일됨(이 파일이 컴파일되면 입증)
/// - BindStrategy 테스트: loopback 기본 라운드트립 + tailscaleIP fake 전략 boundHost introspection
/// - Tailscale 진단 fake 4분기: 각 한국어 사유 + BindStrategy(running=tailscaleIP, 그 외=loopback)
/// - ProcessTailscaleProbe 파싱 4분기 + (실 CLI smoke — 이 머신은 Stopped라 .offline 분기)
/// - push 발신 제외: revoked 디바이스 target은 transport 미호출 + excludedCount +1
final class BindStrategyTailscaleTests: XCTestCase {
    private let clientActor = EnvelopeActor(deviceId: "bind-test-client")

    // MARK: - BindStrategy: loopback 기본 라운드트립 (기존 비파괴)

    func testLoopbackStrategyRoundTrip() async throws {
        let store = InMemoryDeviceStore()
        let issued = try DeviceTokenIssuer.issue()
        let device = Device(id: UUID(), name: "loopback", tokenId: issued.tokenId,
                            expiresAt: Date().addingTimeInterval(3600))
        try await store.upsert(device, secret: issued.secret)
        // strategy 인자 없이 생성(기본 loopback) — 기존 호출부 무변경 비파괴.
        let server = WSServer(registry: SessionBindRegistry(), authGate: WSAuthGate(),
                              verifier: DeviceTokenVerifier(store: store))
        let port = try await server.start()
        defer { Task { await server.stop() } }

        let host = await server.boundHost()
        XCTAssertEqual(host, "127.0.0.1", "기본 전략은 loopback 127.0.0.1에 바인딩")

        // 127.0.0.1로 인증 라운드트립이 성립한다.
        let nonce = WSAuthGate.makeNonce()!
        let client = BindTestClient(port: port, bearer: issued.bearer, nonce: nonce)
        try await client.connectReady()
        client.send(WSEnvelope(seq: 1, actor: clientActor, kind: .sessionStart,
                               text: #"{"sessionId":"\#(UUID().uuidString)","nonce":"\#(nonce)"}"#))
        let gotAck = await client.waitForKind(.ack, timeout: 5)
        XCTAssertTrue(gotAck, "loopback 라운드트립이 ack을 받아야 한다")
        client.close()
        await server.stop()
    }

    // MARK: - BindStrategy: tailscaleIP fake 전략 boundHost introspection

    func testTailscaleIPStrategyReflectsHost() async throws {
        // 실제 100.x 바인딩은 utun이 없으면 .waiting hang이므로(Day 0 함정), 여기서는 host 분기만
        // introspection으로 검증한다(서버 start 없이 boundHost로 strategy.host 반영 확인).
        let store = InMemoryDeviceStore()
        let server = WSServer(registry: SessionBindRegistry(), authGate: WSAuthGate(),
                              verifier: DeviceTokenVerifier(store: store),
                              strategy: .tailscaleIP("100.64.0.1"))
        let host = await server.boundHost()
        XCTAssertEqual(host, "100.64.0.1", "tailscaleIP 전략은 requiredLocalEndpoint host를 그 값으로 설정한다")
    }

    func testBindStrategyHostMapping() {
        XCTAssertEqual(BindStrategy.loopback.host, "127.0.0.1", "loopback은 127.0.0.1")
        XCTAssertEqual(BindStrategy.tailscaleIP("100.64.0.5").host, "100.64.0.5", "tailscaleIP는 연관값 IP")
    }

    // MARK: - Tailscale 진단 fake 4분기 (한국어 사유 + BindStrategy 폴백)

    func testTailscaleDiagnosticsFourBranches() async throws {
        // running(100.x) → tailscaleIP + 연결 안내.
        let runningResult = await TailscaleDiagnostics(probe: FakeProbe(state: .running(ip: "100.64.0.9"))).diagnose()
        XCTAssertEqual(runningResult.strategy, .tailscaleIP("100.64.0.9"), "running은 tailscaleIP 바인딩")
        XCTAssertEqual(runningResult.reason, "Tailscale에 연결되어 안전한 원격 접속이 가능합니다.")

        // notInstalled → loopback 폴백 + 미설치 안내.
        let notInstalled = await TailscaleDiagnostics(probe: FakeProbe(state: .notInstalled)).diagnose()
        XCTAssertEqual(notInstalled.strategy, .loopback, "notInstalled는 loopback 폴백")
        XCTAssertEqual(notInstalled.reason, "Tailscale이 설치되어 있지 않습니다. 로컬 연결만 사용합니다.")

        // notLoggedIn → loopback 폴백 + 로그인 필요 안내.
        let notLoggedIn = await TailscaleDiagnostics(probe: FakeProbe(state: .notLoggedIn)).diagnose()
        XCTAssertEqual(notLoggedIn.strategy, .loopback, "notLoggedIn은 loopback 폴백")
        XCTAssertEqual(notLoggedIn.reason, "Tailscale 로그인이 필요합니다. 로컬 연결만 사용합니다.")

        // offline → loopback 폴백 + 오프라인 안내.
        let offline = await TailscaleDiagnostics(probe: FakeProbe(state: .offline)).diagnose()
        XCTAssertEqual(offline.strategy, .loopback, "offline은 loopback 폴백")
        XCTAssertEqual(offline.reason, "Tailscale이 오프라인 상태입니다. 로컬 연결만 사용합니다.")
    }

    // MARK: - ProcessTailscaleProbe 파싱 4분기 (status/ip 출력 fixture)

    func testProbeBackendStateParsing() {
        XCTAssertEqual(ProcessTailscaleProbe.backendState(#"{"BackendState":"Running"}"#), "Running")
        XCTAssertEqual(ProcessTailscaleProbe.backendState(#"{"BackendState":"NeedsLogin"}"#), "NeedsLogin")
        XCTAssertEqual(ProcessTailscaleProbe.backendState(#"{"BackendState":"Stopped"}"#), "Stopped")
        XCTAssertEqual(ProcessTailscaleProbe.backendState("not json at all"), "",
                       "파싱 실패는 빈 문자열(호출부 default가 .offline으로 환원)")
        XCTAssertEqual(ProcessTailscaleProbe.backendState(#"{"OtherKey":"x"}"#), "",
                       "BackendState 부재는 빈 문자열")
    }

    func testProbeFirstTailscaleIPParsing() {
        XCTAssertEqual(ProcessTailscaleProbe.firstTailscaleIP("100.64.0.1\n"), "100.64.0.1",
                       "정상 100.x 1줄 추출")
        XCTAssertEqual(ProcessTailscaleProbe.firstTailscaleIP("\n  100.100.50.20  \nfe80::1\n"),
                       "100.100.50.20", "공백/빈 줄 무시 + 첫 100.x 추출")
        XCTAssertNil(ProcessTailscaleProbe.firstTailscaleIP("192.168.0.1\n"),
                     "100.x가 아닌 주소는 nil(비-Tailscale 인터페이스)")
        XCTAssertNil(ProcessTailscaleProbe.firstTailscaleIP(""), "빈 출력은 nil")
        XCTAssertNil(ProcessTailscaleProbe.firstTailscaleIP("100.64.0\n"),
                     "점 3개(옥텟 4)가 아닌 출력은 nil")
    }

    // MARK: - ProcessTailscaleProbe 실 CLI smoke (이 머신: Stopped → .offline 또는 .notInstalled)

    func testProbeRealCLISmokeReducesToNonRunning() async throws {
        // 이 머신의 Tailscale은 Stopped 상태(또는 미설치 CI)이므로 .running이 아니어야 한다.
        // Running 실측은 불가하니, "비-Running 분기로 안전 환원 + listener hang 미발생"만 검증한다.
        let probe = ProcessTailscaleProbe()
        let state = await probe.probe()
        switch state {
        case .running:
            // CI/머신에 따라 Running일 수도 있으나 본 머신 규약상 Stopped. Running이면 100.x 형식만 확인.
            if case let .running(ip) = state {
                XCTAssertTrue(ip.hasPrefix("100."), "running이면 IP는 100.x 형식이어야 한다")
            }
        case .notInstalled, .notLoggedIn, .offline:
            // 기대 경로: 비-Running은 loopback 폴백으로 환원(데몬은 어느 분기든 기동).
            XCTAssertEqual(bindStrategy(from: state), .loopback, "비-running 상태는 loopback 폴백")
        }
    }

    // MARK: - push 발신 제외 (revoked target transport 미호출 + excludedCount +1)

    func testSendIfNotRevokedExcludesRevokedDevice() async throws {
        let transport = MockPushTransport()
        let sink = InMemoryPushRevocationSink()
        // skipWhenAttached=false로 두어 WS-attached skip 분기를 비활성화하고 발신 경로를 직진시킨다.
        let sender = PushSender(transport: transport,
                                attachment: AlwaysDetachedAttachment(),
                                config: PushPolicyConfig(skipWhenAttached: false),
                                revocationSink: sink)
        let revokedDevice = UUID()
        let liveDevice = UUID()
        await sink.markRevoked(deviceId: revokedDevice)

        let sid = UUID()
        let env = PushEnvelope(sessionId: sid, messageId: UUID(), preview: "테스트 메시지",
                               chatRoomId: sid.uuidString,
                               timestamp: Date(timeIntervalSince1970: 1_700_000_000), fetchHint: nil)

        // revoked 디바이스 → transport 미호출 + excludedCount +1.
        await sender.sendIfNotRevoked(env, target: .fcm, deviceId: revokedDevice)
        let sentAfterRevoked = await transport.sentCount
        let excludedAfterRevoked = await sender.excludedCount
        XCTAssertEqual(sentAfterRevoked, 0, "revoked 디바이스는 transport에 넘기지 않는다")
        XCTAssertEqual(excludedAfterRevoked, 1, "revoked 발신은 excludedCount +1")

        // 미revoked 디바이스 → 정상 transport 호출(excludedCount 불변).
        await sender.sendIfNotRevoked(env, target: .fcm, deviceId: liveDevice)
        let sentAfterLive = await transport.sentCount
        let excludedAfterLive = await sender.excludedCount
        XCTAssertEqual(sentAfterLive, 1, "미revoked 디바이스는 정상 발신")
        XCTAssertEqual(excludedAfterLive, 1, "미revoked 발신은 제외 카운터 불변")
    }
}

// MARK: - fakes

/// 고정 TailscaleState를 반환하는 fake probe(4분기 결정론 검증용).
private struct FakeProbe: TailscaleProbing {
    let state: TailscaleState
    func probe() async -> TailscaleState { state }
}

/// 항상 미부착으로 답하는 attachment(WS-attached skip 분기를 비활성화해 발신 경로를 직진시킨다).
private struct AlwaysDetachedAttachment: AttachmentQuerying {
    func isAttached(_ sessionId: UUID) async -> Bool { false }
}

// MARK: - 헤더 제어 테스트 클라이언트 (BindStrategy 라운드트립용)

private final class BindTestClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "bind-test-client")
    private let received = BindReceivedStore()

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
            let once = BindOnce()
            connection.stateUpdateHandler = { st in
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
        connection.receiveMessage { [weak self] content, _, _, error in
            guard let self else { return }
            if let content, let env = try? EnvelopeCodec.decode(content) {
                self.received.append(env)
            }
            if error != nil { return }
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
        let deadline = Date().addingTimeInterval(timeout)
        while !received.all().contains(where: { $0.kind == kind }) {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    func close() { connection.cancel() }
}

private final class BindReceivedStore: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [WSEnvelope] = []
    func append(_ env: WSEnvelope) { lock.lock(); items.append(env); lock.unlock() }
    func all() -> [WSEnvelope] { lock.lock(); defer { lock.unlock() }; return items }
}

private final class BindOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
