import XCTest
import Foundation

/// P4 §8 end-to-end acceptance. A0/A3–A10 are owned by the per-component test
/// classes; this class covers the integrated paths that only exist once the WS
/// server, daemon, queue and PTY are wired together:
/// - A1: WS client -> session.start -> input -> echoed output (real external session).
/// - A2: forced ring-buffer overflow -> exactly one BUFFER_OVERFLOW_DROPPED on the wire.
final class AcceptanceTests: XCTestCase {
    private let clientActor = EnvelopeActor(deviceId: "acceptance-client")
    private let daemonActor = EnvelopeActor(deviceId: "daemon-local")

    // A1: end-to-end round trip through WS + daemon + a real `cat` PTY session.
    func testEndToEndExternalRoundtrip() async throws {
        let handle = try PTYSpawner.spawn(command: "/bin/cat", args: [], cwd: "/tmp",
                                          env: ProcessInfo.processInfo.environment, rows: 24, cols: 80)
        let sessionId = UUID()
        let registry = SessionBindRegistry()
        let daemon = SessionDaemon()
        let server = WSServer(registry: registry)
        let readerClosed = expectation(description: "output reader saw EOF")
        await attachExternalSession(server: server, daemon: daemon, masterFD: handle.masterFD,
                                    onOutputClosed: { readerClosed.fulfill() })

        let port = try await server.start()
        let client = WSClient(port: port)
        let received = StringBox()
        let acked = FlagBox()
        try await client.connect()
        client.receiveLoop { env in
            if env.kind == .output, let text = env.payloadText { received.append(text) }
            if env.kind == .ack { acked.set() }
        }

        client.send(WSEnvelope(seq: 1, actor: clientActor, kind: .sessionStart,
                               text: #"{"sessionId":"\#(sessionId.uuidString)"}"#))
        let didAck = await pollUntil(timeout: 5) { acked.isSet() }
        XCTAssertTrue(didAck, "session.start should be acked")
        client.send(WSEnvelope(seq: 2, actor: clientActor, kind: .input, text: "가나다\n"))
        let sawEcho = await pollUntil(timeout: 5) { received.value().contains("가나다") }
        XCTAssertTrue(sawEcho, "echoed output should contain 가나다")

        // EOF-first safe teardown: kill the child, wait for the reader's EOF,
        // then stop and close (never close an fd a DispatchIO read still holds).
        kill(handle.childPID, SIGKILL)
        await fulfillment(of: [readerClosed], timeout: 5)
        await daemon.detach(sessionId: sessionId)
        await server.stop()
        client.close()
        _ = handle.closeMaster()
    }

    // A2: a forced overflow surfaces exactly one BUFFER_OVERFLOW_DROPPED to the client.
    func testFloodEmitsExactlyOneDropMark() async throws {
        let registry = SessionBindRegistry()
        let server = WSServer(registry: registry)
        let actor = daemonActor
        await server.setSessionStartHandler { _, sessionId in
            let ring = SessionRingBuffer(sessionId: sessionId, capacity: 10)
            for i in 0..<110 {
                let env = WSEnvelope(seq: UInt64(i), actor: actor, kind: .output, text: "burst-\(i)")
                if let mark = ring.enqueue(env) {
                    await server.sendToSession(sessionId, mark)
                }
            }
        }

        let port = try await server.start()
        let client = WSClient(port: port)
        let drops = CountBox()
        try await client.connect()
        client.receiveLoop { env in
            if env.kind == .error, env.code == "BUFFER_OVERFLOW_DROPPED" { drops.increment() }
        }
        client.send(WSEnvelope(seq: 1, actor: clientActor, kind: .sessionStart,
                               text: #"{"sessionId":"\#(UUID().uuidString)"}"#))

        let sawDrop = await pollUntil(timeout: 5) { drops.value() >= 1 }
        XCTAssertTrue(sawDrop, "drop mark should reach the client")
        try await Task.sleep(nanoseconds: 200_000_000) // settle: confirm no second mark
        XCTAssertEqual(drops.value(), 1)
        await server.stop()
        client.close()
    }

    // MARK: - Helpers

    private func pollUntil(timeout: TimeInterval, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
    }
}

private final class StringBox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    func append(_ s: String) { lock.lock(); buffer += s; lock.unlock() }
    func value() -> String { lock.lock(); defer { lock.unlock() }; return buffer }
}

private final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    func isSet() -> Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

private final class CountBox: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    func value() -> Int { lock.lock(); defer { lock.unlock() }; return count }
}
