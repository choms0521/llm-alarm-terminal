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
    /// bootstrap 디바이스의 고정 id. 매 부팅 같은 항목을 교체(upsert replace)하게 해
    /// Keychain/스토어에 만료된 bootstrap 토큰이 누적되지 않게 한다.
    private static let bootstrapDeviceId = UUID(uuidString: "B0075D0E-0000-4000-8000-DAE0B00757A9")!

    private let store: any DeviceStore
    /// 데몬/UI가 공유하는 단일 페어링 세션. nil이면 페어링 claim 경로가 비활성이다(P6a 부트스트랩
    /// 호환 — 테스트는 페어링 없이 인증 라운드트립만 검증한다). 주입되면 claim 성공 시
    /// DevicePromotionCoordinator를 통한 pending → active 승격이 배선된다(D-3).
    private let pairingSession: PairingSession?
    /// tailnet opt-in 바인딩 진단용 probe(§5.5b, ADR-F). nil이면 부트스트랩이 명시 opt-in일 때
    /// ProcessTailscaleProbe를 기본 사용한다(테스트는 fake probe를 주입해 결정론적으로 검증).
    private let tailscaleProbe: (any TailscaleProbing)?

    /// 기본 InMemoryDeviceStore로 부트스트랩한다(페어링 미배선).
    public init() {
        self.store = InMemoryDeviceStore()
        self.pairingSession = nil
        self.tailscaleProbe = nil
    }

    /// store를 주입해 부트스트랩한다(Day 3 Keychain store 배선 지점). 페어링 세션은 미배선.
    public init(store: any DeviceStore) {
        self.store = store
        self.pairingSession = nil
        self.tailscaleProbe = nil
    }

    /// store + 공유 페어링 세션을 주입해 부트스트랩한다(앱 부팅 경로). claim 승격이 배선된다(D-3).
    /// tailscaleProbe를 주입하면 tailnet opt-in 진단이 그 probe를 쓴다(미주입 시 명시 opt-in일 때만
    /// ProcessTailscaleProbe 기본 사용 — 기본 동작은 loopback 유지로 무변경).
    public init(store: any DeviceStore, pairingSession: PairingSession,
                tailscaleProbe: (any TailscaleProbing)? = nil) {
        self.store = store
        self.pairingSession = pairingSession
        self.tailscaleProbe = tailscaleProbe
    }

    public func start() async throws -> DaemonHandle {
        let registry = SessionBindRegistry()
        let daemon = SessionDaemon()

        // 인증 게이트용 디바이스 1개 등록 + 토큰 발급. bearer는 핸들로 노출해 클라이언트가
        // 인증 connect를 맺게 한다.
        let issued = try DeviceTokenIssuer.issue()
        let device = Device(
            id: Self.bootstrapDeviceId,
            name: "daemon-bootstrap",
            tokenId: issued.tokenId,
            expiresAt: Date().addingTimeInterval(3600)
        )
        try await store.upsert(device, secret: issued.secret)

        let authGate = WSAuthGate()
        let verifier = DeviceTokenVerifier(store: store)
        // 페어링 세션이 주입되면 claim 성공 → DevicePromotionCoordinator.promote 경로를 배선한다.
        // Coordinator는 actor라 onClaimed @Sendable 콜백이 캡처해 await 발화할 수 있다(D-3 §5.2).
        if let pairingSession {
            let coordinator = DevicePromotionCoordinator(store: store)
            await pairingSession.setOnClaimed { deviceId in
                await coordinator.promote(deviceId: deviceId)
            }
        }
        // tailnet opt-in 바인딩(§5.5b, ADR-F). 기본은 loopback 유지(383/414 비파괴) — 명시 opt-in일
        // 때만 진단을 실행해 running이면 tailscaleIP로 바인딩하고, 그 외 분기는 loopback 폴백한다.
        let strategy = await resolveBindStrategy()
        let server = WSServer(registry: registry, authGate: authGate, verifier: verifier,
                              pairingSession: pairingSession, strategy: strategy)
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

    /// 바인딩 전략을 결정한다(§5.5b, ADR-F). 기본은 loopback 유지로 무변경이다 — 진단(외부 CLI
    /// 호출)은 명시 opt-in일 때만 실행해, opt-in이 없으면 부팅이 Tailscale 상태와 무관하게 즉시
    /// loopback으로 진행된다(383/414 비파괴 + Stopped 환경 부팅 지연 회피).
    ///
    /// env CLAUDE_ALARM_BIND_STRATEGY 정책(부록 A):
    ///   - 미설정 또는 "loopback" → loopback(진단 우회 — 기본 비파괴)
    ///   - "tailscale" → 명시 opt-in. 진단 실행 후 running이면 tailscaleIP, 그 외 분기는 loopback 폴백.
    private func resolveBindStrategy() async -> BindStrategy {
        let raw = ProcessInfo.processInfo.environment["CLAUDE_ALARM_BIND_STRATEGY"]?
            .lowercased()
            .trimmingCharacters(in: .whitespaces)
        guard raw == "tailscale" else {
            return .loopback   // 미설정/loopback/그 외 = 기본 비파괴(진단 미실행)
        }
        // 명시 opt-in: 진단 실행. probe 미주입 시 ProcessTailscaleProbe(표준 경로 탐색)를 쓴다.
        let cliPath = ProcessInfo.processInfo.environment["CLAUDE_ALARM_TAILSCALE_CLI_PATH"]
        let probe = tailscaleProbe ?? ProcessTailscaleProbe(cliPath: cliPath)
        let result = await TailscaleDiagnostics(probe: probe).diagnose()
        return result.strategy   // running → tailscaleIP, 그 외 → loopback 폴백(diagnose가 환원)
    }
}
