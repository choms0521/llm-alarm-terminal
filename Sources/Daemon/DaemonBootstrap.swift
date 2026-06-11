import Foundation

/// Started daemon components, returned by `DaemonBootstrap.start()`. Every member
/// is an actor (or a value), so the handle is `Sendable` and can cross back to
/// the main actor that launched it.
public struct DaemonHandle: Sendable {
    public let server: WSServer
    public let daemon: SessionDaemon
    public let registry: SessionBindRegistry
    public let port: UInt16
    /// P6a: 인증 connect에 쓸 Bearer 토큰. bootstrap이 디바이스 1개를 등록·발급한 결과로,
    /// `WSClient(port:bearerToken:)`에 그대로 넘긴다. (앱 부팅 시에는 Keychain store가
    /// Day 3에서 실 디바이스를 채우며, P6a 부트스트랩은 InMemory 기본 디바이스를 쓴다.)
    public let bearerToken: String
}

/// Boots the in-process daemon: the same construction the dev CLI uses
/// (`SessionBindRegistry` → `SessionDaemon` → `WSServer` → `start()`), extracted
/// so the app launches it at startup (debt (g)) and `DaemonTests` can call it
/// directly — gated on the returned port rather than inspecting a running
/// process with lsof.
///
/// P6a: 모든 WS 연결은 Bearer 인증을 거친다. bootstrap이 DeviceStore를 verifier에 연결하고
/// 인증 게이트와 함께 WSServer를 만든다. 기본 store는 InMemoryDeviceStore이며, 디바이스
/// 1개를 등록해 그 Bearer를 핸들로 노출한다(Keychain 실 store 배선은 Day 3).
public struct DaemonBootstrap {
    private let store: any DeviceStore

    /// 기본 InMemoryDeviceStore로 부트스트랩한다.
    public init() {
        self.store = InMemoryDeviceStore()
    }

    /// store를 주입해 부트스트랩한다(Day 3 Keychain store 배선 지점).
    public init(store: any DeviceStore) {
        self.store = store
    }

    public func start() async throws -> DaemonHandle {
        let registry = SessionBindRegistry()
        let daemon = SessionDaemon()

        // 인증 게이트용 디바이스 1개 등록 + 토큰 발급. bearer는 핸들로 노출해 클라이언트가
        // 인증 connect를 맺게 한다.
        let issued = try DeviceTokenIssuer.issue()
        let device = Device(
            id: UUID(),
            name: "daemon-bootstrap",
            tokenId: issued.tokenId,
            expiresAt: Date().addingTimeInterval(3600)
        )
        try await store.upsert(device, secret: issued.secret)

        let authGate = WSAuthGate()
        let verifier = DeviceTokenVerifier(store: store)
        let server = WSServer(registry: registry, authGate: authGate, verifier: verifier)
        // Inbound WS input must reach the daemon's serial queue in the app-boot
        // path too; without this handler, .input envelopes after a successful
        // session.start are silently ignored.
        await server.setInputHandler { sessionId, item in
            await daemon.sendInput(item, to: sessionId)
        }
        let port = try await server.start()
        return DaemonHandle(server: server, daemon: daemon, registry: registry,
                            port: port, bearerToken: issued.bearer)
    }
}
