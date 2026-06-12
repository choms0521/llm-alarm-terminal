import Foundation
import Network

/// listener가 `.ready`에 도달했는데도 포트를 얻지 못한 경우의 명시적 실패.
/// 포트 0을 반환하면 호출자의 후속 접속 실패 원인이 가려지므로 throw로 표면화한다.
public struct ListenerPortUnavailableError: Error {}

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

    /// 6자리 코드 페어링 세션(§5.5). pre-auth pairing.claim 경로가 코드를 제출해 secret을
    /// 교환한다. nil이면 claim을 처리할 수 없어 pairing.claim은 PAIRING_CODE_INVALID로 거부된다
    /// (페어링이 활성화되지 않은 서버 구성).
    private let pairingSession: PairingSession?

    /// 바인딩 전략(P6b Day 2 D-1). 기본 loopback(127.0.0.1)은 P6a 동작 그대로이고,
    /// tailscaleIP(100.x)는 부트스트랩 opt-in으로 tailnet 인터페이스에만 바인딩한다(1차 경계).
    /// makeListenerParameters의 requiredLocalEndpoint host만 분기하고 게이트 ① 핸드셰이크
    /// 클로저는 무변경이다.
    private let strategy: BindStrategy

    /// deviceId → clientId 역인덱스(P6b Day 2 D-2). 게이트 ② 승격 시 verified.deviceId 집합에
    /// clientId를 insert한다. 같은 deviceId가 동시 N연결(같은 Bearer 다중 연결)을 가질 수 있으므로
    /// Set으로 보유한다 — 단일 매핑이면 두 번째 승격이 첫 clientId를 덮어써 revoke 시 첫 연결이
    /// 살아남는다(누출 창 0 위반). disconnectDevice가 집합 전체를 순회 cancel한다.
    private var deviceToClients: [UUID: Set<UUID>] = [:]

    /// disconnectDevice가 실제로 끊은 연결 수의 누적 카운터(testable 단일 출처). disconnectDevice의
    /// no-op 침묵(미연결 디바이스 revoke)을 가시화하고, "같은 Bearer 2연결 모두 끊김 == 2"를 측정한다.
    /// WSServer actor 격리이므로 Coordinator에 중복 카운터를 두지 않는다(§5.4).
    public private(set) var disconnectedCount = 0

    public init(
        registry: SessionBindRegistry,
        authGate: WSAuthGate,
        verifier: DeviceTokenVerifier,
        pairingSession: PairingSession? = nil,
        strategy: BindStrategy = .loopback,
        pendingWindow: TimeInterval = WSServer.defaultPendingWindow()
    ) {
        self.registry = registry
        self.authGate = authGate
        self.verifier = verifier
        self.pairingSession = pairingSession
        self.strategy = strategy
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

    /// Builds WS parameters bound per `strategy` (loopback 127.0.0.1 by default, or a
    /// Tailscale 100.x interface when opted in). 변경점은 host 한 곳뿐이다 — P6a 게이트 ①
    /// 핸드셰이크 클로저는 무변경이라 인증 경로는 바인딩 인터페이스와 무관하게 동일하다.
    ///
    /// 게이트 ①(P6a): 핸드셰이크 클로저를 `authGate.queue`에 부착해 헤더 Bearer + nonce를
    /// 구조 검증하고 carry한다. 클로저는 actor 외부 @Sendable이라 `authGate`만 캡처한다.
    /// Keychain 조회·secret 대조는 여기서 하지 않는다(핸드셰이크 큐 블록 방지 — 게이트 ②로 지연).
    private static func makeListenerParameters(authGate: WSAuthGate, strategy: BindStrategy) -> NWParameters {
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.setClientRequestHandler(authGate.queue) { _, headers in
            // claim 전용 pre-auth 경로(§5.5): 토큰 없는 디바이스가 6자리 코드를 제출하기 위해
            // 여는 연결이다. Bearer/nonce가 없고 X-Pair-Claim 식별 헤더만 있으면 accept하되
            // carry하지 않는다. 게이트 ②가 이 연결의 첫 envelope을 pairing.claim으로만 허용하고
            // 그 외 운영 envelope은 UNAUTHORIZED로 막는다(연결 미승격). claim 식별 헤더로
            // "claim 의도 연결"과 "잘못 구성된 무토큰 연결"을 구분해 후자는 여전히 reject한다.
            if Self.isClaimHandshake(headers) {
                return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
            }
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
        // 핵심 변경(D-1): 고정 "127.0.0.1" → strategy.host. tailscaleIP면 그 인터페이스에만
        // 바인딩되어 tailnet 밖(loopback 포함 다른 인터페이스)에서 도달 불가하다(Day 0 스파이크 실증).
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(strategy.host), port: .any)
        return params
    }

    /// requiredLocalEndpoint의 바인딩 host introspection(테스트 전용). BindStrategy 분기가
    /// 실제 params host로 반영됐는지 actor 외부 관측 없이 검증하기 위한 seam이다.
    public func boundHost() -> String {
        strategy.host
    }

    /// listener가 `.waiting`(주소 획득 실패 등)에 갇혀 `.ready`에 도달하지 못한 경우의 명시적 실패.
    /// tailscaleIP 바인딩 시 utun 인터페이스가 내려가 있으면(BackendState != Running) listener가
    /// `.failed`가 아니라 `.waiting`에 무한 대기한다(Day 0 스파이크 함정). 표면화해 hang을 막는다.
    public struct ListenerWaitingError: Error {
        public let reason: String
    }

    /// Starts listening on a `strategy`-bound OS-assigned port and returns it once ready.
    ///
    /// `.waiting`도 실패로 표면화하고 5초 안전망 timeout을 둔다(Day 0 스파이크 함정 — tailscaleIP
    /// 바인딩이 utun 미가용 시 `.waiting`에 영구 hang). loopback 기본 경로는 즉시 `.ready`라 무영향.
    @discardableResult
    public func start() async throws -> UInt16 {
        let listener = try NWListener(using: Self.makeListenerParameters(authGate: authGate, strategy: strategy))
        self.listener = listener

        let assignedPort: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let resumed = ResumeOnce()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.fire() {
                        if let value = listener.port?.rawValue {
                            continuation.resume(returning: value)
                        } else {
                            // 포트 0을 돌려주면 호출자가 0번 포트로 접속을 시도해
                            // 원인 파악이 어려우므로 명시적으로 실패시킨다.
                            continuation.resume(throwing: ListenerPortUnavailableError())
                        }
                    }
                case .failed(let error):
                    if resumed.fire() { continuation.resume(throwing: error) }
                case .waiting:
                    // 바인딩 주소가 가용하지 않으면 `.failed` 없이 `.waiting`에 갇힌다(Day 0 함정).
                    // 영구 hang 대신 즉시 실패로 표면화한다. raw error 문자열에는 바인딩
                    // host(실 IP)가 포함될 수 있어 reason에는 일반화된 메시지만 담는다.
                    if resumed.fire() {
                        continuation.resume(throwing: ListenerWaitingError(
                            reason: "바인딩 주소가 가용하지 않아 listener가 waiting 상태에 머묾"))
                    }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { connection in
                Task { await self.accept(connection) }
            }
            listener.start(queue: queue)
            // 5초 안전망: `.ready`/`.failed`/`.waiting` 어느 상태 전이도 5초 안에 안 오면 실패 처리.
            self.queue.asyncAfter(deadline: .now() + 5) {
                if resumed.fire() {
                    continuation.resume(throwing: ListenerWaitingError(reason: "listener start timed out"))
                }
            }
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
        deviceToClients.removeAll()
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

    /// 연결이 스스로 끊길 때(transport error/close/peer-FIN)의 정리. 역인덱스에서 해당 clientId만
    /// 제거하고, 그 deviceId의 집합이 비면 키를 삭제한다(빈 Set 잔존 방지). 같은 deviceId의 다른
    /// 연결은 보존된다(D-2). disconnectDevice와 멱등 정합 — cancel이 트리거한 이 콜백이 이미 정리된
    /// clientId를 다시 봐도 nil 할당/no-op이라 무해하다.
    private func handleDisconnect(_ clientId: UUID) async {
        if let verified = authState[clientId] {
            deviceToClients[verified.deviceId]?.remove(clientId)
            if deviceToClients[verified.deviceId]?.isEmpty == true {
                deviceToClients[verified.deviceId] = nil
            }
        }
        connections[clientId] = nil
        outboundSeq[clientId] = nil
        authState[clientId] = nil
        await registry.cleanup(clientId: clientId)
    }

    // MARK: - P6b revoke 즉시 끊기 (D-2 옵션 A)

    /// revoke 시 호출. 그 deviceId에 바인딩된 살아 있는 연결을 전부 능동 종료한다(누출 창 0).
    /// 연결이 없으면(미연결 디바이스 revoke) no-op — store.revoke만으로 충분하다(재연결도 verifier
    /// !revoked가 거부). 집합 전체를 순회 cancel하므로 같은 deviceId의 동시 N연결이 하나도 안 남는다
    /// (단일 매핑 덮어쓰기로 한 연결이 살아남는 회귀 차단). cancel은 비동기 .cancelled 콜백으로
    /// handleDisconnect를 트리거하지만, 즉시성을 위해 여기서도 상태를 정리한다(handleDisconnect는
    /// 멱등이라 이중 정리 무해). 2회 연속 호출해도 첫 호출이 키를 지우므로 둘째는 guard에서 no-op이다.
    public func disconnectDevice(deviceId: UUID) async {
        guard let clientIds = deviceToClients[deviceId] else { return }   // 미연결 = no-op
        for clientId in clientIds {
            guard let connection = connections[clientId] else { continue }
            connection.cancel()   // long-lived 연결이 envelope을 안 보내도 즉시 끊긴다.
            connections[clientId] = nil
            outboundSeq[clientId] = nil
            authState[clientId] = nil
            await registry.cleanup(clientId: clientId)
            disconnectedCount += 1   // 실제 끊은 연결 수 — A5 측정용
        }
        deviceToClients[deviceId] = nil   // 그 deviceId의 전 연결 제거 후 키 삭제
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

        // pairing.claim pre-auth 분기(§5.5) — 게이트 ② '이전'에 처리한다. 미승격 연결의
        // 첫 envelope이 pairing.claim이면 6자리 코드를 PairingSession에 제출해 secret을
        // 교환하고 return한다. claim은 연결을 승격하지 않으므로 authState는 nil로 남고
        // ingestInbound/게이트 ②/bind에 진입하지 않는다(claim 채널과 운영 채널 분리).
        // claim payload에는 nonce echo가 없어 게이트 ②를 트리거하지 못하므로, 이 분기가
        // 없으면 claim은 UNAUTHORIZED로 막혀 영원히 처리 불가다.
        if authState[clientId] == nil, env.kind == .pairingClaim {
            await handlePairingClaim(env, clientId: clientId, connection: connection)
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
            // 역인덱스 채움(D-2): 같은 deviceId 동시 N연결을 모두 보유하도록 Set에 insert(덮어쓰기
            // 아님). revoke 시 disconnectDevice가 이 집합 전체를 순회 cancel해 누출 창을 0으로 만든다.
            deviceToClients[verified.deviceId, default: []].insert(clientId)
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

    // MARK: - P6a pairing.claim (pre-auth)

    /// pairing.claim 처리(§5.5). payload `{"code":"123456"}`의 6자리 코드를 PairingSession에
    /// 제출한다. 성공 시 pairing.response(PairingPayload JSON, secret 포함 — loopback 한정·
    /// 일회성 예외) / 실패 시 PAIRING_CODE_* 에러를 보낸다. 연결을 승격하지 않으며
    /// (authState 미변경) registry/bind에 진입하지 않는다. secret은 응답 본문에만 담기고
    /// 로그·다른 envelope에는 남기지 않는다.
    private func handlePairingClaim(_ env: WSEnvelope, clientId: UUID, connection: NWConnection) async {
        guard let pairingSession else {
            send(makeError(code: DaemonErrorCode.pairingCodeInvalid.rawValue,
                           message: "pairing not available"),
                 to: connection, clientId: clientId)
            return
        }
        guard let code = Self.claimCode(env.payload) else {
            send(makeError(code: DaemonErrorCode.pairingCodeInvalid.rawValue,
                           message: "pairing claim payload missing a valid code"),
                 to: connection, clientId: clientId)
            return
        }
        guard let payload = await pairingSession.claim(code: code) else {
            // PairingSession.claim 실패. lastRejectCode가 사유(INVALID/EXPIRED/RATE_LIMITED).
            let rejectCode = await pairingSession.lastRejectCode
                ?? DaemonErrorCode.pairingCodeInvalid.rawValue
            send(makeError(code: rejectCode, message: "pairing claim rejected"),
                 to: connection, clientId: clientId)
            return
        }
        guard let json = try? PairingCodec.encodeJSON(payload),
              let text = String(data: json, encoding: .utf8) else {
            send(makeError(code: DaemonErrorCode.malformedPayload.rawValue,
                           message: "pairing response could not be encoded"),
                 to: connection, clientId: clientId)
            return
        }
        send(WSEnvelope(seq: 0, actor: EnvelopeActor(deviceId: "daemon-local"),
                        kind: .pairingResponse, text: text),
             to: connection, clientId: clientId)
    }

    /// pairing.claim payload `{"code":"123456"}`에서 6자리 코드를 추출한다. 형식 위반은 nil.
    /// 정확히 6자리 ASCII 숫자만 통과시켜 비정상 payload(긴 문자열 등)를 조기 차단한다.
    private static func claimCode(_ payload: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let code = object["code"] as? String,
              code.count == 6,
              code.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return code
    }

    // MARK: - P6a 인증 게이트 헬퍼

    /// 게이트 ①: claim 전용 pre-auth 핸드셰이크인지 판정한다(§5.5). Bearer/nonce가 없고
    /// `X-Pair-Claim` 식별 헤더만 있는 연결을 claim 의도로 본다. Bearer나 nonce가 하나라도
    /// 있으면 claim 경로가 아니다(인증 경로로 처리). 식별 헤더로 "잘못 구성된 무토큰 연결"과
    /// 구분해 후자는 reject를 유지한다.
    private static func isClaimHandshake(_ headers: [(name: String, value: String)]) -> Bool {
        guard bearer(from: headers) == nil, nonce(from: headers) == nil else { return false }
        guard let value = headers.first(where: {
            $0.name.caseInsensitiveCompare("X-Pair-Claim") == .orderedSame
        })?.value else { return false }
        return value == "1"
    }

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
