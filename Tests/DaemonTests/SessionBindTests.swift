import XCTest
import Foundation
import Network

/// Day 3 acceptance: WS server loopback bind + per-client monotonic seq.
///
/// Pure-logic registry tests run with no sockets so socket flakiness can never
/// mask a logic regression. Integration tests exercise a real loopback WS
/// connection for bind (A4), wire-level monotonic rejection (#3), disconnect
/// cleanup + PTY survival (A4), and 10x start/stop with no EADDRINUSE (#5).
final class SessionBindTests: XCTestCase {
    private let clientActor = EnvelopeActor(deviceId: "test-client")

    private func envelope(_ seq: UInt64, kind: EnvelopeKind = .input, text: String = "x") -> WSEnvelope {
        WSEnvelope(seq: seq, actor: clientActor, kind: kind, text: text)
    }

    // MARK: - Pure registry logic (no sockets)

    func testRegistryBindAndBoundSession() async {
        let registry = SessionBindRegistry()
        let clientId = UUID()
        let sessionId = UUID()
        await registry.register(clientId: clientId)
        await registry.bind(clientId: clientId, sessionId: sessionId)
        let bound = await registry.boundSession(clientId: clientId)
        XCTAssertEqual(bound, sessionId)
    }

    func testRegistryMonotonicAcceptsIncreasing() async throws {
        let registry = SessionBindRegistry()
        let clientId = UUID()
        await registry.register(clientId: clientId)
        try await registry.ingestInbound(clientId: clientId, env: envelope(1))
        try await registry.ingestInbound(clientId: clientId, env: envelope(2))
        try await registry.ingestInbound(clientId: clientId, env: envelope(100))
    }

    func testRegistryRejectsNonMonotonic() async {
        let registry = SessionBindRegistry()
        let clientId = UUID()
        await registry.register(clientId: clientId)
        try? await registry.ingestInbound(clientId: clientId, env: envelope(5))
        do {
            try await registry.ingestInbound(clientId: clientId, env: envelope(3))
            XCTFail("expected nonMonotonicSeq throw")
        } catch {
            XCTAssertEqual(error as? EnvelopeCodecError, .nonMonotonicSeq(prev: 5, got: 3))
        }
    }

    func testRegistryRejectsDuplicate() async {
        let registry = SessionBindRegistry()
        let clientId = UUID()
        await registry.register(clientId: clientId)
        try? await registry.ingestInbound(clientId: clientId, env: envelope(5))
        do {
            try await registry.ingestInbound(clientId: clientId, env: envelope(5))
            XCTFail("expected nonMonotonicSeq throw on duplicate")
        } catch {
            XCTAssertEqual(error as? EnvelopeCodecError, .nonMonotonicSeq(prev: 5, got: 5))
        }
    }

    func testRegistryCleanupRemovesBinding() async {
        let registry = SessionBindRegistry()
        let clientId = UUID()
        let sessionId = UUID()
        await registry.register(clientId: clientId)
        await registry.bind(clientId: clientId, sessionId: sessionId)
        await registry.cleanup(clientId: clientId)
        let bound = await registry.boundSession(clientId: clientId)
        XCTAssertNil(bound)
        let registered = await registry.isRegistered(clientId: clientId)
        XCTAssertFalse(registered)
    }

    // MARK: - Integration (real loopback WS connection)

    func testServerBindsOnSessionStart() async throws {
        let registry = SessionBindRegistry()
        let server = WSServer(registry: registry)
        let port = try await server.start()
        defer { Task { await server.stop() } }

        let client = WSTestClient(port: port)
        try await client.connect()
        let sessionId = UUID()
        client.send(WSEnvelope(seq: 1, actor: clientActor, kind: .sessionStart,
                               text: #"{"sessionId":"\#(sessionId.uuidString)"}"#))

        let received = await client.collectEnvelopes(for: 1.5)
        let ack = received.first(where: { $0.kind == .ack })
        let ackClientId = ack.flatMap { Self.parseClientId($0.payload) }
        let boundClientId = try XCTUnwrap(ackClientId, "server should ack session.start with clientId")

        let bound = await registry.boundSession(clientId: boundClientId)
        XCTAssertEqual(bound, sessionId)
        client.close()
        await server.stop()
    }

    func testWireMonotonicRejection() async throws {
        let registry = SessionBindRegistry()
        let server = WSServer(registry: registry)
        let port = try await server.start()

        let client = WSTestClient(port: port)
        try await client.connect()
        client.send(envelope(5))   // accepted (5 > 0), no reply
        client.send(envelope(3))   // rejected (3 < 5) -> exactly one error

        let received = await client.collectEnvelopes(for: 2.0)
        let errors = received.filter { $0.kind == .error && $0.code == "NON_MONOTONIC_SEQ" }
        XCTAssertEqual(errors.count, 1, "expected exactly one NON_MONOTONIC_SEQ error")
        client.close()
        await server.stop()
    }

    func testDisconnectCleanupAndSessionSurvives() async throws {
        let manager = SessionManager(maxSessionsOverride: 5)
        let workspace = Workspace(
            id: UUID(),
            name: "p4d3",
            cwd: "/tmp",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            kind: .normal,
            envSnapshot: SessionSpawnEnv.captureUserEnv()
        )
        let session = try await manager.create(
            workspace: workspace, paneId: UUID(), kind: .shell, rows: 24, cols: 80
        )
        XCTAssertNotNil(session.ptyHandle)
        defer { Task { try? await manager.terminate(id: session.id) } }

        let registry = SessionBindRegistry()
        let server = WSServer(registry: registry)
        let port = try await server.start()

        let client = WSTestClient(port: port)
        try await client.connect()
        client.send(WSEnvelope(seq: 1, actor: clientActor, kind: .sessionStart,
                               text: #"{"sessionId":"\#(session.id.uuidString)"}"#))
        let received = await client.collectEnvelopes(for: 1.5)
        let clientId = try XCTUnwrap(received.first(where: { $0.kind == .ack })
            .flatMap { Self.parseClientId($0.payload) })
        let bound = await registry.boundSession(clientId: clientId)
        XCTAssertEqual(bound, session.id)

        // Force close the client; binding must clear within 5s, PTY must survive.
        client.close()
        var cleaned = false
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if await registry.boundSession(clientId: clientId) == nil { cleaned = true; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(cleaned, "binding should be cleaned within 5s of disconnect")

        let survivor = await manager.get(id: session.id)
        XCTAssertNotNil(survivor, "PTY/session must survive a client disconnect")

        await server.stop()
    }

    func testTenStartStopNoEADDRINUSE() async throws {
        let registry = SessionBindRegistry()
        for _ in 0..<10 {
            let server = WSServer(registry: registry)
            let port = try await server.start()
            XCTAssertGreaterThan(port, 0)
            await server.stop()
        }
    }

    // stop() must clear registry bindings for every client deterministically by
    // the time it returns, not rely on async disconnect callbacks (Copilot PR #1).
    func testStopClearsRegistryStateDeterministically() async throws {
        let registry = SessionBindRegistry()
        let server = WSServer(registry: registry)
        let port = try await server.start()

        let client = WSTestClient(port: port)
        try await client.connect()
        let sessionId = UUID()
        client.send(WSEnvelope(seq: 1, actor: clientActor, kind: .sessionStart,
                               text: #"{"sessionId":"\#(sessionId.uuidString)"}"#))
        let received = await client.collectEnvelopes(for: 1.5)
        let clientId = try XCTUnwrap(received.first(where: { $0.kind == .ack })
            .flatMap { Self.parseClientId($0.payload) })
        let boundBefore = await registry.boundSession(clientId: clientId)
        XCTAssertEqual(boundBefore, sessionId)

        await server.stop()

        let bound = await registry.boundSession(clientId: clientId)
        XCTAssertNil(bound, "stop() should clear bindings for all clients before returning")
        let registered = await registry.isRegistered(clientId: clientId)
        XCTAssertFalse(registered, "stop() should clear registration for all clients before returning")

        client.close()
    }

    // An undecodable frame must surface a wire error rather than a silent drop,
    // so a client never waits indefinitely (Copilot PR #1 review).
    func testMalformedFrameSurfacesError() async throws {
        let registry = SessionBindRegistry()
        let server = WSServer(registry: registry)
        let port = try await server.start()

        let client = WSTestClient(port: port)
        try await client.connect()
        client.sendRaw(Data(#"{"garbage":true}"#.utf8))   // no seq key -> MALFORMED_PAYLOAD
        client.sendRaw(Data(#"{"seq":"abc"}"#.utf8))       // non-numeric seq -> MALFORMED_SEQ

        let received = await client.collectEnvelopes(for: 2.0)
        let errorCodes = Set(received.filter { $0.kind == .error }.compactMap { $0.code })
        XCTAssertTrue(errorCodes.contains("MALFORMED_PAYLOAD"),
                      "undecodable frame should surface MALFORMED_PAYLOAD; got \(errorCodes)")
        XCTAssertTrue(errorCodes.contains("MALFORMED_SEQ"),
                      "non-numeric seq should surface MALFORMED_SEQ; got \(errorCodes)")
        client.close()
        await server.stop()
    }

    // MARK: - Helpers

    private static func parseClientId(_ payload: Data) -> UUID? {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let raw = object["clientId"] as? String else { return nil }
        return UUID(uuidString: raw)
    }
}

// MARK: - WS test client

/// Minimal loopback WebSocket client for the Day 3 integration tests.
private final class WSTestClient {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "ws-test-client")

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
            let resumed = TestResumeOnce()
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

    /// Sends arbitrary (possibly undecodable) bytes as a text frame, for
    /// exercising the server's malformed-frame handling.
    func sendRaw(_ data: Data) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "send", metadata: [meta])
        connection.send(content: data, contentContext: context, isComplete: true,
                        completion: .contentProcessed { _ in })
    }

    /// Collects every envelope that arrives within `duration` seconds.
    func collectEnvelopes(for duration: TimeInterval) async -> [WSEnvelope] {
        let box = EnvelopeBox()
        func loop() {
            connection.receiveMessage { content, _, _, error in
                if let content, let env = try? EnvelopeCodec.decode(content) {
                    box.append(env)
                }
                if error == nil { loop() }
            }
        }
        loop()
        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        return box.all()
    }

    func close() {
        connection.cancel()
    }
}

private final class TestResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

private final class EnvelopeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [WSEnvelope] = []
    func append(_ env: WSEnvelope) { lock.lock(); items.append(env); lock.unlock() }
    func all() -> [WSEnvelope] { lock.lock(); defer { lock.unlock() }; return items }
}
