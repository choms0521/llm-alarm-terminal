import XCTest
import Foundation
import Network

/// Day 3 acceptance: (g) the daemon bootstrap returns a live loopback port,
/// proving the app's startup path can launch the in-process daemon.
final class DaemonBootstrapTests: XCTestCase {

    func testStartReturnsLivePort() async throws {
        let handle = try await DaemonBootstrap().start()
        XCTAssertGreaterThan(handle.port, 0)
        // Await shutdown explicitly so listener cleanup cannot outlive the test.
        await handle.server.stop()
    }

    // Bootstrap must wire the WS input handler: a bound client's .input envelope
    // has to reach the daemon's serial queue (Copilot PR #2 review).
    func testBootstrapForwardsWSInputToDaemon() async throws {
        let handle = try await DaemonBootstrap().start()
        let sessionId = UUID()
        let sink = RecordingSink()
        await handle.daemon.attachInput(sessionId: sessionId, sink: sink)

        let actor = EnvelopeActor(deviceId: "bootstrap-test-client")
        let client = BootstrapWSClient(port: handle.port, bearerToken: handle.bearerToken)
        try await client.connect()
        // The server processes a connection's messages in order (receive re-arms
        // after handling), so the bind is complete before the input arrives.
        // 첫 envelope은 핸드셰이크 nonce를 echo해 게이트 ②를 통과한다.
        client.send(WSEnvelope(seq: 1, actor: actor, kind: .sessionStart,
                               text: client.firstSessionStartPayload(sessionId: sessionId)))
        client.send(WSEnvelope(seq: 2, actor: actor, kind: .input, text: "A"))

        let deadline = Date().addingTimeInterval(5)
        while sink.all().isEmpty && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(sink.all(), [0x41],
                       "bootstrap should forward WS input into the daemon queue")

        client.close()
        await handle.server.stop()
    }

    // MARK: - P6b Day 4: tailnet opt-in 바인딩(§5.5b, ADR-F)

    /// 기본(env 미설정)은 loopback 유지 — 진단 probe가 호출되지 않는다(부팅이 Tailscale 상태와
    /// 무관하게 즉시 loopback으로 진행, 383/414 비파괴). probe 호출 여부로 진단 미실행을 측정한다.
    func testBootstrapDefaultsToLoopbackWithoutOptIn() async throws {
        unsetenv("CLAUDE_ALARM_BIND_STRATEGY")
        let probe = SpyTailscaleProbe(state: .running(ip: "127.0.0.1"))
        let bootstrap = DaemonBootstrap(store: InMemoryDeviceStore(),
                                        pairingSession: PairingSession(),
                                        tailscaleProbe: probe)
        let handle = try await bootstrap.start()
        defer { Task { await handle.server.stop() } }
        let host = await handle.server.boundHost()
        XCTAssertEqual(host, "127.0.0.1", "opt-in 없으면 loopback 바인딩(기본 비파괴)")
        let probed = await probe.probeCount()
        XCTAssertEqual(probed, 0, "opt-in 없으면 진단 probe가 호출되지 않아야 한다(진단 미실행)")
        await handle.server.stop()
    }

    /// 명시 opt-in(CLAUDE_ALARM_BIND_STRATEGY=tailscale) + running 진단 → tailscaleIP 바인딩.
    /// fake가 running(ip:127.0.0.1)을 반환하므로 실 listener는 loopback에 성공적으로 뜨고
    /// (이 머신엔 실 100.x가 없으므로 127.0.0.1로 대체), 진단 probe가 호출됨을 측정한다.
    func testBootstrapOptInRunningUsesProbeForTailscaleBinding() async throws {
        setenv("CLAUDE_ALARM_BIND_STRATEGY", "tailscale", 1)
        defer { unsetenv("CLAUDE_ALARM_BIND_STRATEGY") }
        let probe = SpyTailscaleProbe(state: .running(ip: "127.0.0.1"))
        let bootstrap = DaemonBootstrap(store: InMemoryDeviceStore(),
                                        pairingSession: PairingSession(),
                                        tailscaleProbe: probe)
        let handle = try await bootstrap.start()
        defer { Task { await handle.server.stop() } }
        let probed = await probe.probeCount()
        XCTAssertEqual(probed, 1, "명시 opt-in 시 진단 probe가 1회 호출돼야 한다")
        let host = await handle.server.boundHost()
        XCTAssertEqual(host, "127.0.0.1",
                       "running(ip) 진단 결과가 tailscaleIP 바인딩 host로 반영돼야 한다")
        await handle.server.stop()
    }

    /// 명시 opt-in이어도 진단이 offline이면 loopback 폴백(running 아닌 분기는 노출 안 함).
    func testBootstrapOptInOfflineFallsBackToLoopback() async throws {
        setenv("CLAUDE_ALARM_BIND_STRATEGY", "tailscale", 1)
        defer { unsetenv("CLAUDE_ALARM_BIND_STRATEGY") }
        let probe = SpyTailscaleProbe(state: .offline)
        let bootstrap = DaemonBootstrap(store: InMemoryDeviceStore(),
                                        pairingSession: PairingSession(),
                                        tailscaleProbe: probe)
        let handle = try await bootstrap.start()
        defer { Task { await handle.server.stop() } }
        let probed = await probe.probeCount()
        XCTAssertEqual(probed, 1, "opt-in 시 진단은 실행된다(offline 판정)")
        let host = await handle.server.boundHost()
        XCTAssertEqual(host, "127.0.0.1", "offline 진단은 loopback 폴백(tailnet 미노출)")
        await handle.server.stop()
    }
}

// MARK: - Helpers

/// 진단 호출 여부를 기록하는 fake TailscaleProbing. opt-in 게이트(진단 미실행 vs 실행)를
/// 결정론적으로 측정한다 — 고정 state를 반환하고 probe() 호출 횟수를 actor로 격리해 노출한다.
private actor SpyTailscaleProbe: TailscaleProbing {
    private let state: TailscaleState
    private var calls = 0

    init(state: TailscaleState) { self.state = state }

    func probe() async -> TailscaleState {
        calls += 1
        return state
    }

    func probeCount() -> Int { calls }
}

private final class RecordingSink: InputSink, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []
    func write(_ item: InputItem) async {
        lock.lock(); bytes.append(contentsOf: item.bytes); lock.unlock()
    }
    func all() -> [UInt8] {
        lock.lock(); defer { lock.unlock() }; return bytes
    }
}

/// Minimal loopback WS client (send-only) for the bootstrap input test.
/// P6a: Bearer 토큰 + 연결마다 신규 nonce를 핸드셰이크 헤더로 첨부하고, 첫 envelope이
/// 그 nonce를 echo한다(게이트 ② 통과).
private final class BootstrapWSClient {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "bootstrap-ws-test-client")
    private let nonce: String

    init(port: UInt16, bearerToken: String) {
        let nonce = WSAuthGate.makeNonce() ?? UUID().uuidString
        self.nonce = nonce
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.setAdditionalHeaders([
            (name: "Authorization", value: "Bearer \(bearerToken)"),
            (name: "X-Pair-Nonce", value: nonce)
        ])
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        // WS clients must use a URL endpoint so the upgrade request is generated.
        let url = URL(string: "ws://127.0.0.1:\(port)/")!
        connection = NWConnection(to: .url(url), using: params)
    }

    /// 첫 envelope에 쓸 session.start payload(이 연결의 nonce echo 포함).
    func firstSessionStartPayload(sessionId: UUID) -> String {
        #"{"sessionId":"\#(sessionId.uuidString)","nonce":"\#(nonce)"}"#
    }

    func connect(timeout: TimeInterval = 3) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let resumed = BootstrapResumeOnce()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.fire() { cont.resume() }
                case .failed(let error):
                    if resumed.fire() { cont.resume(throwing: error) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                if resumed.fire() { cont.resume(throwing: URLError(.timedOut)) }
            }
        }
    }

    func send(_ envelope: WSEnvelope) {
        guard let data = try? EnvelopeCodec.encode(envelope) else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "send", metadata: [meta])
        connection.send(content: data, contentContext: context, isComplete: true,
                        completion: .contentProcessed { _ in })
    }

    func close() {
        connection.cancel()
    }
}

private final class BootstrapResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
