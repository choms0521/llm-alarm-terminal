import XCTest
import Foundation
import Network

/// P6b Day 0 — Tailscale 진단 파싱 + 비-loopback 바인딩 스파이크.
///
/// 목적 (D-1 옵션 A 확정의 1차 분기 게이트):
///  1. `tailscale status --json` 출력 파싱이 안정적인지 — 고정 fixture JSON 3종(설치+연결/
///     미로그인/오프라인)을 `TailscaleProbing` fake에 통과시켜 각각 구별되는 `TailscaleState`가
///     나오는지 실증한다.
///  2. `WSServer`류 `NWListener`의 `requiredLocalEndpoint`를 비-loopback IP(Tailscale 100.x
///     또는 환경의 실 인터페이스 IP)로 바꾸면 실제로 그 인터페이스에만 바인딩되어
///     `ws://127.0.0.1:<port>/` 클라이언트가 도달 불가능한지 실증한다.
///
/// 이 실증 결과가 옵션 A(Tailscale IP 직접 바인딩) 확정 여부를 가른다 — 비-loopback 바인딩
/// 서버에 loopback 클라이언트가 `.ready`로 도달하면 옵션 A를 포기하고 옵션 C(`tailscale serve`
/// 프록시)로 폴백한다.
///
/// 스파이크 범위: 기존 `WSServer`를 건드리지 않는다(P6a `WSHandshakeRejectSpikeTests` 선례).
/// 테스트 내부에 스파이크 전용 미니 NWListener를 비-loopback host + 커널 할당 포트로 세우고,
/// 핸드셰이크 클로저는 무조건 accept한다(바인딩 도달성만 측정하므로 인증은 범위 밖).
final class TailscaleBindingSpikeTests: XCTestCase {

    // MARK: - (A) status --json 파싱 — fixture 3종이 구별되는 진단 상태로 환원

    /// 설치+연결(BackendState=Running, ip -4=100.x) fixture → `.running(ip:)`.
    func test_statusParse_running_fixture_yields_running() async {
        let probe = FixtureTailscaleProbe(
            statusJSON: Fixtures.runningStatusJSON,
            ipMinusFourOutput: Fixtures.runningIPOutput
        )
        let state = await probe.probe()
        XCTAssertEqual(state, .running(ip: "100.64.0.1"),
                       "Running 백엔드 + 100.x IP fixture는 .running(ip:)로 환원돼야 한다")
    }

    /// 미로그인(BackendState=NeedsLogin) fixture → `.notLoggedIn`.
    func test_statusParse_needsLogin_fixture_yields_notLoggedIn() async {
        let probe = FixtureTailscaleProbe(
            statusJSON: Fixtures.needsLoginStatusJSON,
            ipMinusFourOutput: nil
        )
        let state = await probe.probe()
        XCTAssertEqual(state, .notLoggedIn,
                       "NeedsLogin 백엔드 fixture는 .notLoggedIn으로 환원돼야 한다")
    }

    /// 오프라인(BackendState=Stopped) fixture → `.offline`.
    func test_statusParse_stopped_fixture_yields_offline() async {
        let probe = FixtureTailscaleProbe(
            statusJSON: Fixtures.stoppedStatusJSON,
            ipMinusFourOutput: nil
        )
        let state = await probe.probe()
        XCTAssertEqual(state, .offline,
                       "Stopped 백엔드 fixture는 .offline으로 환원돼야 한다")
    }

    /// 진단 → 바인딩 전략 환원: running만 tailscaleIP, 나머지는 loopback 폴백.
    func test_bindStrategy_running_yields_tailscaleIP_others_loopback() {
        XCTAssertEqual(bindStrategy(from: .running(ip: "100.64.0.1")), .tailscaleIP("100.64.0.1"))
        XCTAssertEqual(bindStrategy(from: .notInstalled), .loopback)
        XCTAssertEqual(bindStrategy(from: .notLoggedIn), .loopback)
        XCTAssertEqual(bindStrategy(from: .offline), .loopback)
    }

    // MARK: - (B) 비-loopback 바인딩 실측 — loopback 클라이언트 도달 불가

    /// 비-loopback IP(Tailscale 100.x 또는 환경의 실 인터페이스 IP)에 바인딩한 미니 서버에
    /// `ws://127.0.0.1:<port>/` 클라이언트가 5초 내 `.ready`에 도달하지 못함(비-.ready)을 측정한다.
    /// 어떤 비-loopback 인터페이스도 없는 CI 환경에서는 `XCTSkip`으로 분기한다.
    func test_nonLoopbackBind_isUnreachableFromLoopbackClient() async throws {
        guard let bindHost = Self.resolveNonLoopbackBindHost() else {
            throw XCTSkip("비-loopback 인터페이스 IP를 찾지 못함(Tailscale 오프라인 + en0/en1 부재). " +
                          "바인딩 실측은 walkthrough로 분리하고 진단 파싱 테스트만 유효하다.")
        }

        let server = try await SpikeBindServer.start(bindHost: bindHost)
        defer { server.stop() }

        // 핵심 측정: 비-loopback에 바인딩된 서버에 loopback URL로 접속 시도.
        let outcome = await SpikeBindClient(host: "127.0.0.1", port: server.port).observe()

        XCTAssertNotEqual(outcome, .ready,
                          "비-loopback 바인딩 서버에 loopback 클라이언트가 .ready에 도달하면 안 된다 " +
                          "(옵션 A 무효 — 이 경우 옵션 C 폴백). 관측값: \(outcome)")
        XCTAssertTrue(outcome.isNonReady,
                      "loopback 클라이언트는 .failed/.cancelled/.waiting/타임아웃으로 관측돼야 한다 — 관측값: \(outcome)")
    }

    /// 대조군: 비-loopback에 바인딩한 같은 서버에 그 비-loopback IP로 접속하면 `.ready`에 도달함을
    /// 확인해, 위 음성 결과가 "서버가 안 떠서"가 아니라 "인터페이스 격리 때문"임을 분간한다.
    func test_nonLoopbackBind_isReachableFromSameInterface() async throws {
        guard let bindHost = Self.resolveNonLoopbackBindHost() else {
            throw XCTSkip("비-loopback 인터페이스 IP를 찾지 못함 — 대조군 생략(진단 파싱 테스트만 유효).")
        }
        if bindHost.hasPrefix("100.") {
            // 자기 자신의 tailscale IP self-dial은 utun hairpin EADDRINUSE로 실패한다(실측 —
            // LAN 인터페이스가 전무한 환경에서만 이 분기에 도달). 대조군만 생략한다.
            throw XCTSkip("tailscale 100.x self-dial은 대조군 측정에 대표성이 없어 생략.")
        }

        let server = try await SpikeBindServer.start(bindHost: bindHost)
        defer { server.stop() }

        let outcome = await SpikeBindClient(host: bindHost, port: server.port).observe()

        XCTAssertEqual(outcome, .ready,
                       "같은 비-loopback 인터페이스로 접속하면 .ready에 도달해야 한다(서버 정상 기동 대조군). 관측값: \(outcome)")
    }

    // MARK: - 비-loopback host 결정

    /// 실측에 쓸 비-loopback 바인딩 host를 결정한다. `en0`/`en1`(LAN IPv4)을 우선하고,
    /// 없으면 Tailscale **Running일 때만** 100.x를, 그것도 없으면 nil(→ XCTSkip)을 반환한다.
    ///
    /// LAN 우선인 이유(실측): 자기 자신의 Tailscale 100.x로의 self-dial은 utun 경유
    /// hairpin이 `EADDRINUSE`로 반복 실패해 대조군(.ready) 측정에 대표성이 없다 — 실 운용은
    /// 다른 기기가 tailnet 너머에서 접속하는 형태라 self-dial 경로 자체가 없다. 인터페이스
    /// 격리 메커니즘(`requiredLocalEndpoint`)은 어느 비-loopback 인터페이스든 동일하다.
    ///
    /// Running 게이트가 필수인 이유(실측): Tailscale이 Stopped여도 `ip -4`는 저장된 100.x를
    /// 반환하는데, utun 인터페이스가 내려가 있으면 그 주소 바인딩이 `.failed`가 아니라
    /// `.waiting`에 머물러 테스트가 무한 대기한다.
    static func resolveNonLoopbackBindHost() -> String? {
        for iface in ["en0", "en1"] {
            if let ip = ipv4(forInterface: iface), ip != "127.0.0.1" {
                return ip
            }
        }
        if let ts = firstRunningTailscaleIPv4(), ts.hasPrefix("100.") {
            return ts
        }
        return nil
    }

    /// BackendState가 Running인 경우에만 `tailscale ip -4`의 첫 100.x 줄을 반환한다.
    /// CLI 부재·미로그인·오프라인(Stopped)이면 nil — 죽은 utun 주소로 바인딩하지 않는다.
    static func firstRunningTailscaleIPv4() -> String? {
        for path in ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale",
                     "/Applications/Tailscale.app/Contents/MacOS/Tailscale"] {
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            guard let statusOut = runProcess([path, "status", "--json"]),
                  let object = try? JSONSerialization.jsonObject(
                      with: Data(statusOut.utf8)) as? [String: Any],
                  (object["BackendState"] as? String) == "Running" else { continue }
            guard let out = runProcess([path, "ip", "-4"]) else { continue }
            for line in out.split(whereSeparator: { $0 == "\n" }) {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("100."), t.split(separator: ".").count == 4 { return t }
            }
        }
        return nil
    }

    /// `ipconfig getifaddr <iface>`로 인터페이스 IPv4를 얻는다. 부재 시 nil.
    static func ipv4(forInterface iface: String) -> String? {
        guard let out = runProcess(["/usr/sbin/ipconfig", "getifaddr", iface]) else { return nil }
        let t = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return (t.split(separator: ".").count == 4) ? t : nil
    }

    /// 외부 프로세스를 실행하고 stdout 문자열을 반환한다. launch 실패·timeout·비정상 종료 시 nil.
    /// ProcessTailscaleProbe.run(5초 timeout + 강제 종료)을 재사용해 tailscaled 무응답
    /// 환경에서도 테스트가 무기한 블록되지 않는다.
    static func runProcess(_ args: [String]) -> String? {
        guard let first = args.first else { return nil }
        return (try? ProcessTailscaleProbe.run(executable: first, args: Array(args.dropFirst()))) ?? nil
    }
}

// MARK: - fixture 기반 fake probe (실 파싱 로직 격리)

/// `TailscaleProbing` fake. 고정 fixture(status JSON + `ip -4` 출력)를 주입받아, 실 구현이
/// 거칠 파싱 로직(BackendState 판정 + 100.x 추출)을 그대로 적용해 4분기로 환원한다. 실 CLI
/// 호출만 빠지고 파싱 경로는 동일하므로, fixture가 환경 의존 없이 결정론적으로 파싱을 검증한다.
private struct FixtureTailscaleProbe: TailscaleProbing {
    let statusJSON: Data
    let ipMinusFourOutput: String?

    func probe() async -> TailscaleState {
        let backend = Self.backendState(statusJSON)
        switch backend {
        case "NeedsLogin": return .notLoggedIn
        case "Running": break
        default: return .offline   // Stopped/NoState 등은 오프라인으로 묶는다(§5.5a)
        }
        guard let ipOut = ipMinusFourOutput,
              let ip = Self.firstTailscaleIP(ipOut) else {
            return .offline   // Running인데 IP 획득 실패 시 보수적 폴백
        }
        return .running(ip: ip)
    }

    /// status JSON에서 top-level `BackendState` 문자열을 추출한다(실 `tailscale status --json`
    /// 형상과 동일 — top-level 키). 누락·파싱 실패 시 빈 문자열로 환원해 .offline로 떨어진다.
    static func backendState(_ json: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let state = object["BackendState"] as? String else { return "" }
        return state
    }

    /// `tailscale ip -4` 출력의 첫 100.x IPv4 줄을 추출한다. 비-100.x 또는 오류 메시지 줄은 건너뛴다.
    static func firstTailscaleIP(_ output: String) -> String? {
        for line in output.split(whereSeparator: { $0 == "\n" }) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("100."), t.split(separator: ".").count == 4 { return t }
        }
        return nil
    }
}

// MARK: - 고정 fixture JSON 3종

private enum Fixtures {
    /// 설치+연결. BackendState=Running, 별도 `ip -4`가 100.x를 준다.
    static let runningStatusJSON: Data = #"""
    {
      "BackendState": "Running",
      "TailscaleIPs": ["100.64.0.1", "fd7a:115c:a1e0::1"],
      "Self": { "Online": true }
    }
    """#.data(using: .utf8)!

    /// `tailscale ip -4`의 정상 출력(100.x 1줄).
    static let runningIPOutput = "100.64.0.1\n"

    /// 미로그인. BackendState=NeedsLogin.
    static let needsLoginStatusJSON: Data = #"""
    {
      "BackendState": "NeedsLogin",
      "AuthURL": "https://login.tailscale.com/a/REDACTED",
      "Self": { "Online": false }
    }
    """#.data(using: .utf8)!

    /// 오프라인. BackendState=Stopped(이 머신 실측과 동일 분기).
    static let stoppedStatusJSON: Data = #"""
    {
      "BackendState": "Stopped",
      "Self": { "Online": false }
    }
    """#.data(using: .utf8)!
}

// MARK: - 관측 결과 모델

private enum SpikeBindOutcome: Equatable {
    case ready
    case failed(String)
    case cancelled
    case waiting(String)
    case timedOut

    /// `.ready`가 아닌 모든 종료(전송 실패/취소/대기 교착/timeout) — 비-loopback 격리의 측정 기준.
    var isNonReady: Bool {
        switch self {
        case .ready: return false
        case .failed, .cancelled, .waiting, .timedOut: return true
        }
    }
}

// MARK: - 스파이크 전용 미니 서버 (비-loopback 바인딩)

private struct SpikeBindPortUnavailableError: Error {}

/// 기존 WSServer를 건드리지 않는 스파이크 전용 WS 서버. 주어진 host에만 바인딩하고
/// (`requiredLocalEndpoint`) 핸드셰이크는 무조건 accept한다 — 바인딩 도달성만 측정한다.
private final class SpikeBindServer: @unchecked Sendable {
    private let listener: NWListener
    let port: UInt16

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    static func start(bindHost: String) async throws -> SpikeBindServer {
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        // 인증은 범위 밖 — 핸드셰이크는 무조건 accept(도달성만 측정).
        ws.setClientRequestHandler(DispatchQueue(label: "spike-bind-gate")) { _, _ in
            NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
        }
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        // 핵심: 주어진 비-loopback host에만 바인딩한다. 이 인터페이스 밖(loopback 포함)에서는
        // 도달 불가능해야 한다(옵션 A의 1차 경계 가정).
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(bindHost), port: .any)

        let listener = try NWListener(using: params)
        let listenerQueue = DispatchQueue(label: "spike-bind-listener")

        let assignedPort: UInt16 = try await withCheckedThrowingContinuation { cont in
            let resumed = SpikeBindOnce()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.fire() {
                        if let port = listener.port?.rawValue {
                            cont.resume(returning: port)
                        } else {
                            cont.resume(throwing: SpikeBindPortUnavailableError())
                        }
                    }
                case .failed(let error):
                    if resumed.fire() { cont.resume(throwing: error) }
                case .waiting(let error):
                    // 내려간 인터페이스 주소 바인딩은 .failed가 아니라 .waiting에 머문다 —
                    // 무한 대기 대신 즉시 실패로 표면화한다.
                    if resumed.fire() { cont.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { connection in
                connection.start(queue: DispatchQueue(label: "spike-bind-conn"))
            }
            listener.start(queue: listenerQueue)
            // 안전망: 5초 내 .ready/.failed/.waiting 어느 것도 안 오면 바인딩 불가로 판정한다.
            listenerQueue.asyncAfter(deadline: .now() + 5) {
                if resumed.fire() { cont.resume(throwing: SpikeBindPortUnavailableError()) }
            }
        }

        return SpikeBindServer(listener: listener, port: assignedPort)
    }

    func stop() {
        listener.cancel()
    }
}

// MARK: - 스파이크 전용 클라이언트

/// 반드시 ws:// URL 엔드포인트로 NWConnection을 생성한다 — host:port 엔드포인트로 만들면
/// HTTP Upgrade 요청이 전송되지 않아 핸드셰이크가 .preparing에서 교착한다
/// (macOS 26 실측, project memory `reference_nwwebsocket_client_url`).
private final class SpikeBindClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "spike-bind-test-client")

    init(host: String, port: UInt16) {
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        let url = URL(string: "ws://\(host):\(port)/")!
        connection = NWConnection(to: .url(url), using: params)
    }

    func observe(timeout: TimeInterval = 5) async -> SpikeBindOutcome {
        let outcome: SpikeBindOutcome = await withCheckedContinuation { cont in
            let resumed = SpikeBindOnce()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.fire() { cont.resume(returning: .ready) }
                case .failed(let error):
                    if resumed.fire() { cont.resume(returning: .failed(String(describing: error))) }
                case .cancelled:
                    if resumed.fire() { cont.resume(returning: .cancelled) }
                case .waiting(let error):
                    if resumed.fire() { cont.resume(returning: .waiting(String(describing: error))) }
                default:
                    break
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
}

// MARK: - 일회성 resume 가드

private final class SpikeBindOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
