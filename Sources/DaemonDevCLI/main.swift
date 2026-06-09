import Foundation
import Network

// Dev CLI for the in-process daemon.
//
// Modes:
//   --serve-probe : start the WS server on loopback (127.0.0.1:0), print
//                   "LISTENING <port> <pid>" to stdout, then block. Used by the
//                   Day 3 pid-scoped lsof check (A8) to confirm loopback-only.
//   (P4 Day 6 adds --roundtrip / --flood end-to-end demos.)

let arguments = CommandLine.arguments

func emit(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

if let idx = arguments.firstIndex(of: "--connect"),
   idx + 1 < arguments.count, let port = UInt16(arguments[idx + 1]) {
    let client = WSClient(port: port)
    Task {
        do {
            try await client.connect(onState: { emit("STATE \($0)") })
            emit("CONNECTED")
            client.receiveLoop { env in emit("RECV kind=\(env.kind.rawValue) code=\(env.code ?? "-")") }
            let sessionId = UUID()
            client.send(WSEnvelope(seq: 1, actor: EnvelopeActor(deviceId: "connect-probe"),
                                   kind: .sessionStart, text: #"{"sessionId":"\#(sessionId.uuidString)"}"#))
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
    // Keep the process alive so the harness can lsof its listening socket.
    RunLoop.main.run()
} else {
    FileHandle.standardError.write(
        Data("DaemonDevCLI: --roundtrip / --flood land in P4 Day 6. args=\(arguments.count)\n".utf8)
    )
    exit(0)
}
