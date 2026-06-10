import Foundation

/// Started daemon components, returned by `DaemonBootstrap.start()`. Every member
/// is an actor (or a value), so the handle is `Sendable` and can cross back to
/// the main actor that launched it.
public struct DaemonHandle: Sendable {
    public let server: WSServer
    public let daemon: SessionDaemon
    public let registry: SessionBindRegistry
    public let port: UInt16
}

/// Boots the in-process daemon: the same construction the dev CLI uses
/// (`SessionBindRegistry` → `SessionDaemon` → `WSServer` → `start()`), extracted
/// so the app launches it at startup (debt (g)) and `DaemonTests` can call it
/// directly — gated on the returned port rather than inspecting a running
/// process with lsof.
public struct DaemonBootstrap {
    public init() {}

    public func start() async throws -> DaemonHandle {
        let registry = SessionBindRegistry()
        let daemon = SessionDaemon()
        let server = WSServer(registry: registry)
        let port = try await server.start()
        return DaemonHandle(server: server, daemon: daemon, registry: registry, port: port)
    }
}
