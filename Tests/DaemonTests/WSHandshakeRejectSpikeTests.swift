import XCTest
import Foundation
import Network

/// P6a Day 0 — 핸드셰이크 reject 스파이크.
///
/// 목적: `NWProtocolWebSocket.Options.setClientRequestHandler`가 핸드셰이크
/// 단계에서 Bearer 헤더를 검사해 `Response(status: .reject)`를 반환할 때,
/// 클라이언트가 이를 "관측 가능한 형태"(연결 실패/즉시 close)로 받는지 실증한다.
/// 이 실증 결과가 D-1 옵션 A(2단 게이트) 확정 여부의 1차 분기다 —
/// reject가 클라이언트에 무력하게 보이면(accept처럼 .ready 도달) 게이트 ①을
/// 포기하고 옵션 B(게이트 ② 단독)로 폴백한다.
///
/// 이 테스트는 P5.5의 `SurfaceRegistryInvariantTests`가 GUI 의존 가정을
/// 단위 수준에서 실증한 스파이크 게이트 선례를 따른다 — 미검증 SDK 가정을
/// 본 구현 전에 격리된 미니 서버로 먼저 측정한다.
///
/// 스파이크 범위: 기존 `WSServer`를 건드리지 않는다. 테스트 내부에 스파이크 전용
/// 미니 NWListener를 127.0.0.1 + 커널 할당 포트로 세우고, 핸드셰이크 클로저에서
/// `Authorization: Bearer` 헤더의 존재와 형식(`tokenId.secret` 구조)만 검사한다.
/// Keychain 조회·secret 대조는 스파이크 범위 밖이다(Day 2).
final class WSHandshakeRejectSpikeTests: XCTestCase {

    /// (1) 유효 형식 Bearer를 첨부한 클라이언트는 핸드셰이크를 통과해 `.ready`에 도달한다.
    func test_validBearer_reaches_ready() async throws {
        let server = try await SpikeServer.start()
        defer { server.stop() }

        let outcome = await SpikeClient(port: server.port,
                                        bearer: "tok_abc123.c2VjcmV0LXZhbHVl").observe()

        XCTAssertEqual(outcome, .ready,
                       "유효 형식 Bearer 클라이언트는 핸드셰이크 accept로 .ready에 도달해야 한다")
    }

    /// (2) 무토큰 클라이언트(Authorization 헤더 없음)는 핸드셰이크 reject로 인해
    /// 5초 이내에 `.failed` 또는 `.cancelled`로 관측된다(.ready 미도달). 핵심 측정.
    func test_noBearer_is_rejected_observably() async throws {
        let server = try await SpikeServer.start()
        defer { server.stop() }

        let outcome = await SpikeClient(port: server.port, bearer: nil).observe()

        XCTAssertNotEqual(outcome, .ready,
                          "무토큰 클라이언트는 reject되어 .ready에 도달하면 안 된다(관측 가능한 거부)")
        XCTAssertTrue(outcome.isObservableRejection,
                      "무토큰 클라이언트는 .failed 또는 .cancelled(또는 .ready 미도달 timeout)로 관측돼야 한다 — 관측값: \(outcome)")
    }

    /// (3) 위조(형식 위반) Bearer를 첨부한 클라이언트도 동일하게 거부 관측된다.
    /// `tokenId.secret` 구조가 아닌 토큰은 게이트 ①의 구조 검증에서 reject된다.
    func test_malformedBearer_is_rejected_observably() async throws {
        let server = try await SpikeServer.start()
        defer { server.stop() }

        let outcome = await SpikeClient(port: server.port,
                                        bearer: "garbage-without-dot-separator").observe()

        XCTAssertNotEqual(outcome, .ready,
                          "형식 위반 Bearer 클라이언트는 reject되어 .ready에 도달하면 안 된다")
        XCTAssertTrue(outcome.isObservableRejection,
                      "위조 Bearer 클라이언트는 .failed/.cancelled로 관측돼야 한다 — 관측값: \(outcome)")
    }
}

// MARK: - 관측 결과 모델

/// 클라이언트 connect의 최종 관측 상태. 스파이크의 측정 대상이다.
private enum SpikeOutcome: Equatable {
    case ready
    case failed(String)
    case cancelled
    case waiting(String)
    case timedOut

    /// reject가 "관측 가능"한지의 판정: .ready가 아닌 모든 종료(전송 실패/취소/대기 교착/timeout).
    var isObservableRejection: Bool {
        switch self {
        case .ready: return false
        case .failed, .cancelled, .waiting, .timedOut: return true
        }
    }
}

// MARK: - 스파이크 전용 미니 서버

/// 기존 WSServer를 건드리지 않는 스파이크 전용 loopback WS 서버.
/// 핸드셰이크 클로저에서 Bearer 헤더의 존재 + `tokenId.secret` 구조만 검사하고,
/// 통과 시 accept, 위반 시 reject를 반환한다.
/// listener가 `.ready`인데 포트를 얻지 못한 경우의 명시적 실패. 포트 0으로 클라이언트를
/// 만들면 이후 실패가 포트 바인딩 문제인지 분간하기 어려워 throw로 표면화한다.
private struct SpikePortUnavailableError: Error {}

private final class SpikeServer: @unchecked Sendable {
    private let listener: NWListener
    let port: UInt16

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    static func start() async throws -> SpikeServer {
        let gateQueue = DispatchQueue(label: "spike-ws-auth-gate")

        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        // 게이트 ① 실증: 핸드셰이크에서 Authorization: Bearer 헤더의 구조만 검사.
        ws.setClientRequestHandler(gateQueue) { _, headers in
            guard SpikeServer.structurallyValidBearer(in: headers) else {
                return NWProtocolWebSocket.Response(status: .reject, subprotocol: nil)
            }
            return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
        }
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)

        let listener = try NWListener(using: params)
        let listenerQueue = DispatchQueue(label: "spike-ws-listener")

        let assignedPort: UInt16 = try await withCheckedThrowingContinuation { cont in
            let resumed = SpikeOnce()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.fire() {
                        if let port = listener.port?.rawValue {
                            cont.resume(returning: port)
                        } else {
                            cont.resume(throwing: SpikePortUnavailableError())
                        }
                    }
                case .failed(let error):
                    if resumed.fire() { cont.resume(throwing: error) }
                default:
                    break
                }
            }
            // 서버가 accept한 연결은 즉시 받아 .ready 도달을 살려둔다(스파이크는 핸드셰이크
            // 결과만 측정하므로 메시지 처리는 하지 않는다). 핸드러를 비우면 일부 환경에서
            // 연결이 즉시 정리되어 클라이언트 .ready 관측이 흔들릴 수 있어 명시적으로 start한다.
            listener.newConnectionHandler = { connection in
                connection.start(queue: DispatchQueue(label: "spike-ws-conn"))
            }
            listener.start(queue: listenerQueue)
        }

        return SpikeServer(listener: listener, port: assignedPort)
    }

    func stop() {
        listener.cancel()
    }

    /// Authorization 헤더에서 Bearer를 추출해 `tokenId.secret` 구조만 본다.
    /// 헤더 부재·접두사 누락·구분자(.) 누락·빈 컴포넌트는 모두 구조 위반으로 reject 대상.
    static func structurallyValidBearer(in headers: [(name: String, value: String)]) -> Bool {
        guard let value = headers.first(where: {
            $0.name.caseInsensitiveCompare("Authorization") == .orderedSame
        })?.value else { return false }

        let prefix = "Bearer "
        guard value.hasPrefix(prefix) else { return false }
        let token = String(value.dropFirst(prefix.count))

        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return false }
        return true
    }
}

// MARK: - 스파이크 전용 클라이언트

/// 반드시 ws:// URL 엔드포인트로 NWConnection을 생성한다 — host:port 엔드포인트로
/// 만들면 HTTP Upgrade 요청이 전송되지 않아 핸드셰이크가 .preparing에서 교착한다
/// (macOS 26 실측, project memory `reference_nwwebsocket_client_url`).
private final class SpikeClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "spike-ws-test-client")

    init(port: UInt16, bearer: String?) {
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        // 클라이언트 측 헤더 첨부: WS 핸드셰이크 additionalHeaders로 Authorization: Bearer 운반.
        // bearer가 nil이면 헤더를 첨부하지 않아 "무토큰" 케이스를 만든다.
        if let bearer {
            ws.setAdditionalHeaders([(name: "Authorization", value: "Bearer \(bearer)")])
        }
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)

        let url = URL(string: "ws://127.0.0.1:\(port)/")!
        connection = NWConnection(to: .url(url), using: params)
    }

    /// connect를 시도하고 최종 관측 상태를 반환한다. 고정 sleep이 아니라 상태 전이
    /// 콜백(.ready/.failed/.cancelled/.waiting)을 기다리되, 5초 내 어떤 전이도
    /// 확정되지 않으면 .timedOut으로 마감한다(reject가 .preparing 교착으로만 나타나는
    /// 환경에서도 "관측 가능한 거부"로 판정).
    func observe(timeout: TimeInterval = 5) async -> SpikeOutcome {
        let outcome: SpikeOutcome = await withCheckedContinuation { cont in
            let resumed = SpikeOnce()
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

/// Network 콜백이 같은 객체에 대해 직렬 전달되지만, timeout asyncAfter와 경쟁하므로
/// 락으로 단 한 번만 continuation을 resume한다.
private final class SpikeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
