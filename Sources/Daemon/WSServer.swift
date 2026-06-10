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

    public init(registry: SessionBindRegistry) {
        self.registry = registry
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
    private static func makeListenerParameters() -> NWParameters {
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        return params
    }

    /// Starts listening on a loopback OS-assigned port and returns it once ready.
    @discardableResult
    public func start() async throws -> UInt16 {
        let listener = try NWListener(using: Self.makeListenerParameters())
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
