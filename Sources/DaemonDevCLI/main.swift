import Foundation
import Network

// Dev CLI for the in-process daemon.
//
// Modes:
//   --roundtrip   : spawn an external `cat` session, connect a loopback WS client,
//                   session.start -> send "가나다" -> print the echoed output.
//   --flood       : force a ring-buffer overflow and print the single
//                   BUFFER_OVERFLOW_DROPPED that reaches the client over the wire.
//   --serve-probe : start the WS server on loopback, print "LISTENING <port> <pid>",
//                   block (used by the pid-scoped lsof check, A8).
//   --connect <p> : connectivity probe against a running --serve-probe.

let arguments = CommandLine.arguments

func emit(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

/// Thread-safe collector for envelope payloads received off the WS queue.
final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func append(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    func joined() -> String { lock.lock(); defer { lock.unlock() }; return items.joined() }
    func contains(_ needle: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return items.contains { $0.contains(needle) }
    }
}

func poll(timeout: TimeInterval, _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return true
}

let cliActor = EnvelopeActor(deviceId: "daemon-dev-cli")

func runRoundtrip() async -> Int32 {
    let handle: PTYHandle
    do {
        handle = try PTYSpawner.spawn(command: "/bin/cat", args: [], cwd: "/tmp",
                                      env: ProcessInfo.processInfo.environment, rows: 24, cols: 80)
    } catch {
        FileHandle.standardError.write(Data("spawn cat failed: \(error)\n".utf8))
        return 2
    }

    let sessionId = UUID()
    let registry = SessionBindRegistry()
    let daemon = SessionDaemon()
    let server = WSServer(registry: registry)
    await attachExternalSession(server: server, daemon: daemon, masterFD: handle.masterFD)

    let port: UInt16
    do { port = try await server.start() } catch {
        FileHandle.standardError.write(Data("server start failed: \(error)\n".utf8)); return 3
    }

    let received = Collector()
    let acked = Collector()
    let client = WSClient(port: port)
    do { try await client.connect() } catch {
        FileHandle.standardError.write(Data("client connect failed: \(error)\n".utf8)); return 4
    }
    client.receiveLoop { env in
        if env.kind == .output, let text = env.payloadText { received.append(text) }
        if env.kind == .ack { acked.append("ack") }
    }

    client.send(WSEnvelope(seq: 1, actor: cliActor, kind: .sessionStart,
                           text: #"{"sessionId":"\#(sessionId.uuidString)"}"#))
    guard await poll(timeout: 5, { acked.contains("ack") }) else {
        FileHandle.standardError.write(Data("no ack for session.start\n".utf8)); return 5
    }
    client.send(WSEnvelope(seq: 2, actor: cliActor, kind: .input, text: "가나다\n"))

    let ok = await poll(timeout: 5, { received.contains("가나다") })
    emit(received.joined())
    return ok ? 0 : 6
}

func runFlood() async -> Int32 {
    let capacity = Int(ProcessInfo.processInfo.environment["CHAT_TERMINAL_RING_CAPACITY"] ?? "") ?? 500
    let registry = SessionBindRegistry()
    let server = WSServer(registry: registry)
    let sessionActor = cliActor

    // On bind, deterministically overflow a ring buffer (drain not running) and
    // forward the single drop-mark over the wire. Overflow correctness itself is
    // proven by SessionRingBufferTests; this only demonstrates one mark on the wire.
    await server.setSessionStartHandler { _, sessionId in
        let ring = SessionRingBuffer(sessionId: sessionId, capacity: capacity)
        for i in 0..<(capacity + 100) {
            let env = WSEnvelope(seq: UInt64(i), actor: sessionActor, kind: .output, text: "burst-\(i)")
            if let dropMark = ring.enqueue(env) {
                await server.sendToSession(sessionId, dropMark)
            }
        }
    }

    let port: UInt16
    do { port = try await server.start() } catch {
        FileHandle.standardError.write(Data("server start failed: \(error)\n".utf8)); return 3
    }

    let drops = Collector()
    let client = WSClient(port: port)
    do { try await client.connect() } catch {
        FileHandle.standardError.write(Data("client connect failed: \(error)\n".utf8)); return 4
    }
    client.receiveLoop { env in
        if env.kind == .error, env.code == "BUFFER_OVERFLOW_DROPPED" { drops.append("x") }
    }
    client.send(WSEnvelope(seq: 1, actor: cliActor, kind: .sessionStart,
                           text: #"{"sessionId":"\#(UUID().uuidString)"}"#))

    let ok = await poll(timeout: 5, { drops.contains("x") })
    if ok { emit("BUFFER_OVERFLOW_DROPPED") }
    return ok ? 0 : 6
}

if arguments.contains("--roundtrip") {
    Task { exit(await runRoundtrip()) }
    RunLoop.main.run()
} else if arguments.contains("--flood") {
    Task { exit(await runFlood()) }
    RunLoop.main.run()
} else if let idx = arguments.firstIndex(of: "--connect"),
          idx + 1 < arguments.count, let port = UInt16(arguments[idx + 1]) {
    let client = WSClient(port: port)
    Task {
        do {
            try await client.connect(onState: { emit("STATE \($0)") })
            emit("CONNECTED")
            client.receiveLoop { env in emit("RECV kind=\(env.kind.rawValue) code=\(env.code ?? "-")") }
            let sessionId = UUID()
            client.send(WSEnvelope(seq: 1, actor: cliActor, kind: .sessionStart,
                                   text: #"{"sessionId":"\#(sessionId.uuidString)"}"#))
        } catch {
            emit("CONNECT_FAILED \(error)")
            exit(2)
        }
    }
    RunLoop.main.run()
} else if arguments.contains("--serve-probe") {
    let registry = SessionBindRegistry()
    let server = WSServer(registry: registry)
    Task {
        do {
            let port = try await server.start()
            let pid = ProcessInfo.processInfo.processIdentifier
            emit("LISTENING \(port) \(pid)")
        } catch {
            FileHandle.standardError.write(Data("serve-probe failed: \(error)\n".utf8))
            exit(1)
        }
    }
    RunLoop.main.run()
} else {
    FileHandle.standardError.write(
        Data("usage: daemon-dev-cli [--roundtrip|--flood|--serve-probe|--connect <port>]\n".utf8)
    )
    exit(0)
}
