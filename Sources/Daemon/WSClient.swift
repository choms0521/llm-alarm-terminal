import Foundation
import Network

/// Minimal loopback WebSocket client used by the dev CLI (Day 6 round-trip demo)
/// and the Day 3 connectivity probe. Encodes/decodes WS envelopes as text frames.
public final class WSClient {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.choms0521.ClaudeAlarmTerminal.ws-client")

    public init(host: String = "127.0.0.1", port: UInt16) {
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        // A WS client must use a URL endpoint (ws://host:port/) so the framework
        // can generate the HTTP Upgrade request; a bare host/port endpoint leaves
        // the upgrade unsent and the handshake stalls in .preparing.
        let url = URL(string: "ws://\(host):\(port)/")!
        connection = NWConnection(to: .url(url), using: params)
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
