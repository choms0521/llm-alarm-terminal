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
        let client = BootstrapWSClient(port: handle.port)
        try await client.connect()
        // The server processes a connection's messages in order (receive re-arms
        // after handling), so the bind is complete before the input arrives.
        client.send(WSEnvelope(seq: 1, actor: actor, kind: .sessionStart,
                               text: #"{"sessionId":"\#(sessionId.uuidString)"}"#))
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
}

// MARK: - Helpers

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
private final class BootstrapWSClient {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "bootstrap-ws-test-client")

    init(port: UInt16) {
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        // WS clients must use a URL endpoint so the upgrade request is generated.
        let url = URL(string: "ws://127.0.0.1:\(port)/")!
        connection = NWConnection(to: .url(url), using: params)
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
