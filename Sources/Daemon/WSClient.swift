import Foundation
import Network

/// Minimal loopback WebSocket client used by the dev CLI (Day 6 round-trip demo)
/// and the Day 3 connectivity probe. Encodes/decodes WS envelopes as text frames.
///
/// P6a 인증: 모든 WS 연결은 Bearer 토큰을 첨부해야 한다. 핸드셰이크 `additionalHeaders`로
/// `Authorization: Bearer <tokenId>.<secret>` + `X-Pair-Nonce`(연결마다 신규 무작위 nonce)를
/// 운반하고, 첫 송신 envelope payload에 그 nonce만 echo한다(토큰·secret은 첫 envelope에 싣지
/// 않는 단일 매체 규약). `firstEnvelope(_:)` 헬퍼가 nonce를 payload에 합류한다.
public final class WSClient {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.choms0521.ClaudeAlarmTerminal.ws-client")
    /// 이 연결의 일회성 nonce. 첫 envelope이 echo해 핸드셰이크 carry-over 항목을 지목한다.
    private let nonce: String

    /// Bearer 토큰을 첨부해 인증 WS 연결을 만든다. nonce는 연결마다 새로 생성한다.
    public init(host: String = "127.0.0.1", port: UInt16, bearerToken: String) {
        let nonce = WSAuthGate.makeNonce() ?? UUID().uuidString
        self.nonce = nonce

        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        // 인증 자료는 핸드셰이크 헤더 단일 매체로만 운반한다(첫 envelope에는 nonce echo만).
        ws.setAdditionalHeaders([
            (name: "Authorization", value: "Bearer \(bearerToken)"),
            (name: "X-Pair-Nonce", value: nonce)
        ])
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        // A WS client must use a URL endpoint (ws://host:port/) so the framework
        // can generate the HTTP Upgrade request; a bare host/port endpoint leaves
        // the upgrade unsent and the handshake stalls in .preparing.
        let url = URL(string: "ws://\(host):\(port)/")!
        connection = NWConnection(to: .url(url), using: params)
    }

    /// 이 연결의 nonce. 테스트가 첫 envelope의 echo를 검증할 때 참조한다.
    public var pairNonce: String { nonce }

    /// 첫 송신 envelope에 쓸 session.start payload를 만든다. 이 연결의 nonce를 합류한다.
    /// 서버 parseSessionId는 여분 키(nonce)에 관대하고, echoedNonce가 nonce 필드를 읽는다.
    public func firstSessionStartPayload(sessionId: UUID) -> String {
        #"{"sessionId":"\#(sessionId.uuidString)","nonce":"\#(nonce)"}"#
    }

    /// Connects and resolves once the WS handshake is ready. `onState`, when set,
    /// reports every transition (used by the connectivity probe for diagnostics).
    public func connect(timeout: TimeInterval = 5, onState: ((String) -> Void)? = nil) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let resumed = OnceFlag()
            connection.stateUpdateHandler = { state in
                onState?(String(describing: state))
                switch state {
                case .ready:
                    if resumed.fire() { cont.resume() }
                case .failed(let error), .waiting(let error):
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

    public func send(_ envelope: WSEnvelope) {
        guard let data = try? EnvelopeCodec.encode(envelope) else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "send", metadata: [meta])
        connection.send(content: data, contentContext: context, isComplete: true,
                        completion: .contentProcessed { _ in })
    }

    /// Continuously receives envelopes until the connection closes.
    public func receiveLoop(_ onEnvelope: @escaping (WSEnvelope) -> Void) {
        connection.receiveMessage { [weak self] content, _, _, error in
            if let content, let env = try? EnvelopeCodec.decode(content) {
                onEnvelope(env)
            }
            if error == nil { self?.receiveLoop(onEnvelope) }
        }
    }

    public func close() {
        connection.cancel()
    }
}

/// One-shot guard for resuming a continuation exactly once from serial callbacks.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
