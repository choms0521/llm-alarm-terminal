import Foundation

/// Wires a single `.external` session's I/O between a `WSServer` and a
/// `SessionDaemon` (loopback demo / acceptance scope, one session):
/// WS input -> daemon queue -> master fd, and master fd output -> accumulator ->
/// WS client. Output is sent via `WSServer.sendToSession`, which re-stamps the
/// per-client outbound seq, so the client always sees monotonic seq.
///
/// Note: output forwarding hops each envelope through a `Task` to reach the
/// server actor, so output FIFO is best-effort here. P4 only sends a single
/// round-trip message; a serial output forwarder is deferred to P5.
public func attachExternalSession(
    server: WSServer,
    daemon: SessionDaemon,
    masterFD: Int32,
    onOutputClosed: @escaping @Sendable () -> Void = {}
) async {
    await server.setInputHandler { sessionId, item in
        await daemon.sendInput(item, to: sessionId)
    }
    await server.setSessionStartHandler { _, sessionId in
        await daemon.attachInput(sessionId: sessionId, sink: ExternalSink(masterFD: masterFD))
        await daemon.attachExternalOutput(
            sessionId: sessionId,
            masterFD: masterFD,
            emit: { env in Task { await server.sendToSession(sessionId, env) } },
            onClosed: onOutputClosed
        )
    }
}
