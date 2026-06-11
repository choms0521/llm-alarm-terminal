import Foundation
import Network

/// In-process WebSocket server bound to loopback only (127.0.0.1, OS-assigned
/// port). Accepts WS clients, binds them to sessions on `session.start`, and
/// rejects out-of-order inbound `seq` with a NON_MONOTONIC_SEQ error envelope.
///
/// Loopback-only is enforced two ways: structurally via
/// `requiredLocalEndpoint = 127.0.0.1:any` (non-loopback exposure is impossible)
/// and empirically by the Day 3 pid-scoped lsof check (A8).
///
/// Per-connection messages are processed strictly in order: the next
/// `receiveMessage` is armed only after the current message is fully handled, so
/// the monotonic seq check never sees a scrambled order.
public actor WSServer {
    private let registry: SessionBindRegistry
    private let queue = DispatchQueue(label: "com.choms0521.ClaudeAlarmTerminal.ws-server")

    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var outboundSeq: [UUID: UInt64] = [:]

    private var inputHandler: (@Sendable (UUID, InputItem) async -> Void)?
    private var sessionStartHandler: (@Sendable (UUID, UUID) async -> Void)?

    // P6a 인증 게이트. 게이트 ①(핸드셰이크)이 carry한 nonce 항목을 게이트 ②(첫 envelope)가
    // 소비해 constant-time secret 대조로 승격한다. 승격 전 connection은 운영 envelope을
    // 처리하지 못한다(ingestInbound/bind 미진입).
    private let authGate: WSAuthGate
    private let verifier: DeviceTokenVerifier
    private let pendingWindow: TimeInterval
    /// 승격된 connection 식별자 집합. nil이면 미인증(게이트 ② 트리거 대상).
    private var authState: [UUID: DeviceTokenVerifier.VerifiedDevice] = [:]

    public init(
        registry: SessionBindRegistry,
        authGate: WSAuthGate,
        verifier: DeviceTokenVerifier,
        pendingWindow: TimeInterval = WSServer.defaultPendingWindow()
    ) {
        self.registry = registry
        self.authGate = authGate
        self.verifier = verifier
        self.pendingWindow = pendingWindow
    }

    /// carry-over 시간창 기본값. env `CLAUDE_ALARM_PAIRING_PENDING_WINDOW_SECONDS`로
    /// 재정의하며(부록 A), 미설정/파싱 실패 시 10초다.
    public static func defaultPendingWindow() -> TimeInterval {
        let raw = ProcessInfo.processInfo.environment["CLAUDE_ALARM_PAIRING_PENDING_WINDOW_SECONDS"]
        if let raw, let value = TimeInterval(raw), value > 0 { return value }
        return 10
    }

    /// The OS-assigned loopback port once the server is listening.
    public private(set) var port: UInt16?

    /// Called for each inbound `input` envelope from a bound client.
    public func setInputHandler(_ handler: @escaping @Sendable (_ sessionId: UUID, _ item: InputItem) async -> Void) {
        inputHandler = handler
    }

    /// Called after a client binds via `session.start`, before its ack is sent,
    /// so the integrator can attach the session's input sink and output tap
    /// before any input arrives.
    public func setSessionStartHandler(_ handler: @escaping @Sendable (_ clientId: UUID, _ sessionId: UUID) async -> Void) {
        sessionStartHandler = handler
    }

    /// Sends an envelope to the client currently bound to a session (seq is
    /// re-stamped per client by `send`). No-op if no client is bound.
    public func sendToSession(_ sessionId: UUID, _ envelope: WSEnvelope) async {
        guard let clientId = await registry.boundClient(forSession: sessionId),
              let connection = connections[clientId] else { return }
        send(envelope, to: connection, clientId: clientId)
    }

    /// Builds loopback-only WS parameters (127.0.0.1, OS-assigned port).
    ///
    /// 게이트 ①(P6a): 핸드셰이크 클로저를 `authGate.queue`에 부착해 헤더 Bearer + nonce를
    /// 구조 검증하고 carry한다. 클로저는 actor 외부 @Sendable이라 `authGate`만 캡처한다.
    /// Keychain 조회·secret 대조는 여기서 하지 않는다(핸드셰이크 큐 블록 방지 — 게이트 ②로 지연).
    private static func makeListenerParameters(authGate: WSAuthGate) -> NWParameters {
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.setClientRequestHandler(authGate.queue) { _, headers in
            // 헤더에서 Bearer(tokenId.secret) + X-Pair-Nonce(연결마다 신규 무작위 nonce) 추출.
            // 구조 검증만(tokenId/secret base64url 형식 + nonce 형식). 중복 nonce는 reject.
            guard let split = authGate.structurallySplit(Self.bearer(from: headers)),
                  let nonce = Self.nonce(from: headers),
                  WSAuthGate.isValidNonce(nonce) else {
                return NWProtocolWebSocket.Response(status: .reject, subprotocol: nil)
            }
            // nonce 중복·등록·carry를 핸드셰이크 큐(actor 외부)에서 동기적으로 처리한다.
            // authGate는 actor지만 이 경로는 큐 직렬 격리에 의존하므로 동기 헬퍼로 위임한다.
            guard authGate.handshakeRegister(nonce: nonce, tokenId: split.tokenId, secret: split.secret) else {
                return NWProtocolWebSocket.Response(status: .reject, subprotocol: nil)   // 중복 nonce
            }
            return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
        }
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        return params
    }

    /// Starts listening on a loopback OS-assigned port and returns it once ready.
    @discardableResult
    public func start() async throws -> UInt16 {
        let listener = try NWListener(using: Self.makeListenerParameters(authGate: authGate))
        self.listener = listener

        let assignedPort: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let resumed = ResumeOnce()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let value = listener.port?.rawValue ?? 0
                    if resumed.fire() { continuation.resume(returning: value) }
                case .failed(let error):
                    if resumed.fire() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { connection in
                Task { await self.accept(connection) }
            }
            listener.start(queue: queue)
        }

        self.port = assignedPort
        return assignedPort
    }

    /// Cancels all connections and the listener, awaiting `.cancelled`.
    public func stop() async {
        // Capture clientIds before teardown so registry state is cleared
        // proactively. The async stateUpdateHandler -> handleDisconnect path is
        // best-effort and may not fire before stop() returns; cleanup() is
        // idempotent, so a later disconnect callback is harmless.
        let clientIds = Array(connections.keys)
        for (_, connection) in connections { connection.cancel() }
        connections.removeAll()
        outboundSeq.removeAll()
        authState.removeAll()
        for clientId in clientIds { await registry.cleanup(clientId: clientId) }

        guard let listener = self.listener else { return }
        await withCheckedContinuation { continuation in
            let resumed = ResumeOnce()
            listener.stateUpdateHandler = { state in
                if case .cancelled = state, resumed.fire() { continuation.resume() }
            }
            listener.cancel()
        }
        self.listener = nil
        self.port = nil
    }

    // MARK: - Connection lifecycle

    private func accept(_ connection: NWConnection) async {
        let clientId = UUID()
        connections[clientId] = connection
        outboundSeq[clientId] = 0

        // Seed the client's seq state before arming receive so the first inbound
        // message can never race ahead of registration.
        await registry.register(clientId: clientId)

        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled:
                Task { await self.handleDisconnect(clientId) }
            default:
                break
            }
        }
        // Each accepted connection gets its own queue so its WS handshake never
        // contends with the listener's queue.
        connection.start(queue: DispatchQueue(label: "com.choms0521.ClaudeAlarmTerminal.ws-conn"))
        receiveNext(on: connection, clientId: clientId)
    }

    private nonisolated func receiveNext(on connection: NWConnection, clientId: UUID) {
        connection.receiveMessage { [weak self] content, context, _, error in
            guard let self else { return }

            // Disconnect signals: transport error, a WS close frame, or the
            // final message on the connection (peer FIN). Cancel + clean up.
            let closed = error != nil
                || (context.map { Self.isClose($0) || $0.isFinal } ?? false)
            if closed {
                connection.cancel()
                Task { await self.handleDisconnect(clientId) }
                return
            }

            Task {
                if let content, !content.isEmpty {
                    await self.handleMessage(content, clientId: clientId, connection: connection)
                }
                // Re-arm only after the current message is fully handled.
                self.receiveNext(on: connection, clientId: clientId)
            }
        }
    }

    private static func isClose(_ context: NWConnection.ContentContext) -> Bool {
        guard let meta = context.protocolMetadata(definition: NWProtocolWebSocket.definition)
            as? NWProtocolWebSocket.Metadata else { return false }
        return meta.opcode == .close
    }

    private func handleDisconnect(_ clientId: UUID) async {
        connections[clientId] = nil
        outboundSeq[clientId] = nil
        authState[clientId] = nil
        await registry.cleanup(clientId: clientId)
    }

    // MARK: - Message handling

    private func handleMessage(_ data: Data, clientId: UUID, connection: NWConnection) async {
        let env: WSEnvelope
        do {
            env = try EnvelopeCodec.decode(data)
        } catch {
            // A frame that fails to decode gets a wire error rather than a silent
            // drop, so a client never waits indefinitely for a response. A bad
            // seq string is reported distinctly from otherwise-malformed JSON.
            let code: DaemonErrorCode
            let message: String
            if case let EnvelopeCodecError.malformedSeq(bad) = error {
                code = .malformedSeq
                message = "seq is not a valid UInt64: \(bad)"
            } else {
                code = .malformedPayload
                message = "envelope could not be decoded"
            }
            send(makeError(code: code.rawValue, message: message),
                 to: connection, clientId: clientId)
            return
        }

        // 게이트 ② (P6a) — ingestInbound(seq 전진) 이전에 인증한다. 미인증 clientId의 첫
        // envelope이 echo한 nonce가 트리거다. 토큰·secret은 envelope에 없고(헤더로만 운반)
        // env.actor.deviceId도 신뢰 입력이 아니다. 미통과 시 UNAUTHORIZED + cancel하고
        // ingestInbound/bind에 진입하지 않는다 — 미인증 연결이 registry seq나 세션 바인딩을
        // 오염시키지 못하게 한다(C2 순서 보증).
        if authState[clientId] == nil {
            guard let echoedNonce = Self.echoedNonce(env.payload),
                  let claimed = await authGate.consumePending(nonce: echoedNonce, within: pendingWindow),
                  let verified = await verifier.verify(tokenId: claimed.tokenId,
                                                       presentedSecret: claimed.secret) else {
                // 에러 프레임 전송 완료 후 cancel — 클라이언트가 UNAUTHORIZED를 받을 기회를 준다.
                sendThenCancel(makeError(code: DaemonErrorCode.unauthorized.rawValue,
                                         message: "unauthenticated connection"),
                               to: connection, clientId: clientId)
                return
            }
            // 승격: 이후 같은 clientId의 envelope은 재검증 없이 통과한다(carry-over 1회로 충분).
            authState[clientId] = verified
        }

        do {
            try await registry.ingestInbound(clientId: clientId, env: env)
        } catch {
            send(makeError(code: DaemonErrorCode.nonMonotonicSeq.rawValue,
                           message: "seq \(env.seq) not monotonic"),
                 to: connection, clientId: clientId)
            return
        }

        switch env.kind {
        case .sessionStart:
            if let sessionId = Self.parseSessionId(env.payload) {
                await registry.bind(clientId: clientId, sessionId: sessionId)
                // Attach sink + output tap before acking, so input that follows
                // the ack can never race ahead of the wiring.
                await sessionStartHandler?(clientId, sessionId)
                let payload = #"{"clientId":"\#(clientId.uuidString)","sessionId":"\#(sessionId.uuidString)"}"#
                send(makeAck(ackSeq: env.seq, text: payload), to: connection, clientId: clientId)
            } else {
                // Malformed session.start payload — reply rather than hang silently.
                send(makeError(code: DaemonErrorCode.malformedPayload.rawValue,
                               message: "session.start payload missing a valid sessionId"),
                     to: connection, clientId: clientId)
            }
        case .input:
            if let sessionId = await registry.boundSession(clientId: clientId) {
                await inputHandler?(sessionId, InputItem(bytes: [UInt8](env.payload)))
            }
        case .pause, .resume:
            // v0.9 reserved: no behavior, ack only.
            send(makeAck(ackSeq: env.seq, text: "{}"), to: connection, clientId: clientId)
        default:
            break
        }
    }

    // MARK: - Send

    private func send(_ envelope: WSEnvelope, to connection: NWConnection, clientId: UUID) {
        let next = (outboundSeq[clientId] ?? 0) + 1
        outboundSeq[clientId] = next
        let stamped = WSEnvelope(
            seq: next,
            ackSeq: envelope.ackSeq,
            actor: envelope.actor,
            kind: envelope.kind,
            code: envelope.code,
            payload: envelope.payload
        )
        guard let data = try? EnvelopeCodec.encode(stamped) else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "send", metadata: [meta])
        connection.send(content: data, contentContext: context, isComplete: true,
                        completion: .contentProcessed { _ in })
    }

    /// 게이트 ②: 에러 프레임을 보낸 뒤 그 프레임이 실제로 전송된 다음에 연결을 닫는다.
    /// 즉시 `connection.cancel()`을 호출하면 미완료 send 프레임이 폐기되어 클라이언트가
    /// UNAUTHORIZED를 받기 전에 close될 수 있다 — completion 콜백에서 cancel을 트리거한다.
    private func sendThenCancel(_ envelope: WSEnvelope, to connection: NWConnection, clientId: UUID) {
        let next = (outboundSeq[clientId] ?? 0) + 1
        outboundSeq[clientId] = next
        let stamped = WSEnvelope(
            seq: next,
            ackSeq: envelope.ackSeq,
            actor: envelope.actor,
            kind: envelope.kind,
            code: envelope.code,
            payload: envelope.payload
        )
        guard let data = try? EnvelopeCodec.encode(stamped) else {
            connection.cancel()
            return
        }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "send", metadata: [meta])
        connection.send(content: data, contentContext: context, isComplete: true,
                        completion: .contentProcessed { _ in
                            // 전송 완료(또는 실패) 후 닫는다 — 에러 프레임이 클라이언트에 도달할 기회를 준다.
                            connection.cancel()
                        })
    }

    private func makeAck(ackSeq: UInt64, text: String) -> WSEnvelope {
        WSEnvelope(seq: 0, ackSeq: ackSeq, actor: EnvelopeActor(deviceId: "daemon-local"),
                   kind: .ack, text: text)
    }

    private func makeError(code: String, message: String) -> WSEnvelope {
        let payload = #"{"message":"\#(message)"}"#
        return WSEnvelope(seq: 0, actor: EnvelopeActor(deviceId: "daemon-local"),
                          kind: .error, code: code, text: payload)
    }

    private static func parseSessionId(_ payload: Data) -> UUID? {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let raw = object["sessionId"] as? String else { return nil }
        return UUID(uuidString: raw)
    }

    // MARK: - P6a 인증 게이트 헬퍼

    /// 게이트 ② 트리거: 첫 envelope payload JSON의 `"nonce"` 필드를 추출한다. session.start
    /// payload `{"sessionId":"...","nonce":"..."}`에 합류되며, parseSessionId는 여분 키에
    /// 관대하다(sessionId만 읽음). nonce가 없으면(다른 kind가 먼저 도착 등) nil → UNAUTHORIZED.
    private static func echoedNonce(_ payload: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let nonce = object["nonce"] as? String, !nonce.isEmpty else { return nil }
        return nonce
    }

    /// 게이트 ① 헤더 추출: `Authorization: Bearer <tokenId>.<secret>`에서 토큰 문자열만 떼낸다.
    /// 대소문자 무시 헤더 매칭 + `Bearer ` 접두사 제거. 부재·접두사 누락 시 nil.
    private static func bearer(from headers: [(name: String, value: String)]) -> String? {
        guard let value = headers.first(where: {
            $0.name.caseInsensitiveCompare("Authorization") == .orderedSame
        })?.value else { return nil }
        let prefix = "Bearer "
        guard value.hasPrefix(prefix) else { return nil }
        let token = String(value.dropFirst(prefix.count))
        return token.isEmpty ? nil : token
    }

    /// 게이트 ① 헤더 추출: `X-Pair-Nonce` 헤더값(클라이언트가 연결마다 생성한 일회성 nonce).
    private static func nonce(from headers: [(name: String, value: String)]) -> String? {
        guard let value = headers.first(where: {
            $0.name.caseInsensitiveCompare("X-Pair-Nonce") == .orderedSame
        })?.value, !value.isEmpty else { return nil }
        return value
    }
}

/// One-shot guard so a continuation is resumed exactly once from a state handler
/// that may fire multiple times. Network callbacks for a given object are
/// delivered serially on one queue, so a plain flag is sufficient.
private final class ResumeOnce: @unchecked Sendable {
    private var done = false
    func fire() -> Bool {
        if done { return false }
        done = true
        return true
    }
}
