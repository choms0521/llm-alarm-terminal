import Foundation
import Network

// Dev CLI for the in-process daemon.
//
// Modes:
//   --roundtrip    : spawn an external `cat` session, connect an authenticated
//                    loopback WS client, session.start -> send "가나다" -> print echo.
//   --flood        : force a ring-buffer overflow and print the single
//                    BUFFER_OVERFLOW_DROPPED that reaches the client over the wire.
//   --serve-probe  : start the WS server on loopback, print "LISTENING <port> <pid>",
//                    block (used by the pid-scoped lsof check, A8).
//   --connect <p>  : connectivity probe against a running --serve-probe (needs a token).
//   --connect-auth : issue a valid token, connect authenticated, session.start ->
//                    receive ack -> exit 0 (P6a auth round-trip proof).
//   --pair         : start an in-process daemon (WSServer + PairingSession + store),
//                    issue a 6-digit code (printed to stdout), have a simulated device
//                    claim it over loopback WS, register the device, then run the
//                    authenticated round-trip with the received secret. Prints
//                    "PAIRED <deviceId>" and exits 0. No secret is printed.
//   --lifecycle    : P6b Day 4 토큰 lifecycle 무효화 e2e. 데몬 1개 위에서 (a) 디바이스 A 인증
//                    연결 → revoke → 끊김 + 재connect UNAUTHORIZED, (b) 만료 디바이스 B Bearer
//                    connect → 게이트 ② UNAUTHORIZED, (c) revoked A push 발신 제외(transport
//                    미호출)를 순차 측정한다. stdout에 "REVOKE_DISCONNECTED"/"EXPIRED_REJECTED"/
//                    "PUSH_REJECTED_REVOKED" 3 신호를 내보내고 exit 0. secret 평문은 출력하지 않는다.
//
// P6a: 모든 운영 WS 연결은 Bearer 토큰을 첨부해야 한다. 각 모드는 시작 시 InMemoryDeviceStore에
// 디바이스 1개를 등록하고 토큰을 발급해 그 Bearer로 연결한다. pairing.claim 연결만 pre-auth다.

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

/// 인증된 데몬 구성. InMemoryDeviceStore에 디바이스 1개를 등록·토큰 발급하고, 그 store를
/// verifier에 연결해 WSServer를 인증 게이트와 함께 생성한다. CLI 클라이언트는 발급된
/// Bearer로 연결한다.
struct AuthedDaemon {
    let registry: SessionBindRegistry
    let server: WSServer
    let store: InMemoryDeviceStore
    let bearer: String
}

/// 디바이스 1개 등록 + 토큰 발급 + 인증 WSServer 구성을 한곳에 모은다.
func makeAuthedDaemon(registry: SessionBindRegistry) async throws -> AuthedDaemon {
    let store = InMemoryDeviceStore()
    let issued = try DeviceTokenIssuer.issue()
    let device = Device(
        id: UUID(),
        name: "daemon-dev-cli",
        tokenId: issued.tokenId,
        expiresAt: Date().addingTimeInterval(3600)
    )
    try await store.upsert(device, secret: issued.secret)

    let authGate = WSAuthGate()
    let verifier = DeviceTokenVerifier(store: store)
    let server = WSServer(registry: registry, authGate: authGate, verifier: verifier)
    return AuthedDaemon(registry: registry, server: server, store: store, bearer: issued.bearer)
}

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
    let authed: AuthedDaemon
    do { authed = try await makeAuthedDaemon(registry: registry) } catch {
        FileHandle.standardError.write(Data("token issue failed: \(error)\n".utf8)); return 7
    }
    let server = authed.server
    await attachExternalSession(server: server, daemon: daemon, masterFD: handle.masterFD)

    let port: UInt16
    do { port = try await server.start() } catch {
        FileHandle.standardError.write(Data("server start failed: \(error)\n".utf8)); return 3
    }

    let received = Collector()
    let acked = Collector()
    let client = WSClient(port: port, bearerToken: authed.bearer)
    do { try await client.connect() } catch {
        FileHandle.standardError.write(Data("client connect failed: \(error)\n".utf8)); return 4
    }
    client.receiveLoop { env in
        if env.kind == .output, let text = env.payloadText { received.append(text) }
        if env.kind == .ack { acked.append("ack") }
    }

    client.send(WSEnvelope(seq: 1, actor: cliActor, kind: .sessionStart,
                           text: client.firstSessionStartPayload(sessionId: sessionId)))
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
    let authed: AuthedDaemon
    do { authed = try await makeAuthedDaemon(registry: registry) } catch {
        FileHandle.standardError.write(Data("token issue failed: \(error)\n".utf8)); return 7
    }
    let server = authed.server
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
    let client = WSClient(port: port, bearerToken: authed.bearer)
    do { try await client.connect() } catch {
        FileHandle.standardError.write(Data("client connect failed: \(error)\n".utf8)); return 4
    }
    client.receiveLoop { env in
        if env.kind == .error, env.code == "BUFFER_OVERFLOW_DROPPED" { drops.append("x") }
    }
    client.send(WSEnvelope(seq: 1, actor: cliActor, kind: .sessionStart,
                           text: client.firstSessionStartPayload(sessionId: UUID())))

    let ok = await poll(timeout: 5, { drops.contains("x") })
    if ok { emit("BUFFER_OVERFLOW_DROPPED") }
    return ok ? 0 : 6
}

/// P6a: 유효 토큰으로 인증 connect → session.start → ack 수신 → exit 0.
func runConnectAuth() async -> Int32 {
    let registry = SessionBindRegistry()
    let authed: AuthedDaemon
    do { authed = try await makeAuthedDaemon(registry: registry) } catch {
        FileHandle.standardError.write(Data("token issue failed: \(error)\n".utf8)); return 7
    }
    let server = authed.server

    let port: UInt16
    do { port = try await server.start() } catch {
        FileHandle.standardError.write(Data("server start failed: \(error)\n".utf8)); return 3
    }

    let acked = Collector()
    let client = WSClient(port: port, bearerToken: authed.bearer)
    do { try await client.connect() } catch {
        FileHandle.standardError.write(Data("client connect failed: \(error)\n".utf8)); return 4
    }
    client.receiveLoop { env in
        if env.kind == .ack { acked.append("ack") }
    }

    let sessionId = UUID()
    client.send(WSEnvelope(seq: 1, actor: cliActor, kind: .sessionStart,
                           text: client.firstSessionStartPayload(sessionId: sessionId)))

    let ok = await poll(timeout: 5, { acked.contains("ack") })
    if ok { emit("AUTH_ACK") }
    await server.stop()
    return ok ? 0 : 5
}

/// P6a: in-process 데몬 기동 → 6자리 코드 발급(stdout) → 시뮬레이션 디바이스가 pairing.claim으로
/// 코드 제출 → PairingPayload(secret) 수신 → DeviceStore 등록 확인 → 받은 secret으로 인증
/// 라운드트립(session.start + "가나다" echo) → "PAIRED <deviceId>" 출력 + exit 0.
/// secret 평문은 어디에도 출력하지 않는다(코드·deviceId만).
func runPair() async -> Int32 {
    let registry = SessionBindRegistry()
    let store = InMemoryDeviceStore()
    let authGate = WSAuthGate()
    let verifier = DeviceTokenVerifier(store: store)
    let lifecycle = DeviceLifecyclePolicy()
    let pairingSession = PairingSession()

    // P6b Day 1: claim 성공 → pending → active 승격(DevicePromotionCoordinator)을 배선한다.
    // PairingModel을 경유하지 않는 드라이버이므로 onClaimed 바인딩을 issueNewCode와 동형으로
    // 인라인 재현한다(데몬 레이어 단일 경로 — §5.2).
    let promotionCoordinator = DevicePromotionCoordinator(store: store, lifecycle: lifecycle)
    await pairingSession.setOnClaimed { deviceId in
        await promotionCoordinator.promote(deviceId: deviceId)
    }

    // 디바이스 1개를 미리 발급·등록하고, 그 secret을 담은 payload를 코드에 묶는다. claim이
    // 성공하면 디바이스가 이 secret으로 인증 connect를 맺는다(store에는 이미 등록돼 있다).
    let deviceId = UUID()
    let issued: DeviceTokenIssuer.IssuedToken
    do { issued = try DeviceTokenIssuer.issue() } catch {
        FileHandle.standardError.write(Data("token issue failed: \(error)\n".utf8)); return 7
    }

    let server = WSServer(registry: registry, authGate: authGate, verifier: verifier,
                          pairingSession: pairingSession)
    let port: UInt16
    do { port = try await server.start() } catch {
        FileHandle.standardError.write(Data("server start failed: \(error)\n".utf8)); return 3
    }

    // 부채 해소(D-3): pending(코드 ttl=5분 수명)로 upsert한다. 30일 active 수명은 claim 성공 시
    // onClaimed → promote만이 부여한다. pending upsert가 빠지면 promote가 미존재 no-op이 되어
    // 30일 갱신이 일어나지 않으므로(위양성 함정), issueNewCode와 동형으로 pending upsert를 둔다.
    let now = Date()
    let pendingExpiry = lifecycle.pendingExpiry(codeTTL: pairingSession.ttl, now: now)
    let device = Device(id: deviceId, name: "paired-device", tokenId: issued.tokenId,
                        expiresAt: pendingExpiry)
    do { try await store.upsert(device, secret: issued.secret) } catch {
        FileHandle.standardError.write(Data("device upsert failed: \(error)\n".utf8)); return 8
    }

    let payload = PairingPayload(
        pairingId: UUID().uuidString,
        deviceTokenSecret: issued.secretBase64url,
        wsEndpoint: "ws://127.0.0.1:\(port)/",
        pushChannelHint: "mock-\(deviceId.uuidString.prefix(8))",
        expiresAt: pendingExpiry
    )
    let code: String
    do { code = try await pairingSession.issue(payload: payload, deviceId: deviceId) } catch {
        FileHandle.standardError.write(Data("code issue failed: \(error)\n".utf8)); return 9
    }
    emit("CODE \(code)")

    // 시뮬레이션 디바이스: pre-auth claim 연결로 코드 제출 → payload 수신.
    let claimClient = PairingClaimClient(port: port)
    let outcome = await claimClient.claim(code: code)
    guard case let .success(received) = outcome else {
        FileHandle.standardError.write(Data("claim failed: \(outcome)\n".utf8)); return 10
    }

    // DeviceStore 등록 확인(claim 전 upsert가 살아 있는지).
    guard let registered = try? await store.find(byTokenId: issued.tokenId), !registered.revoked else {
        FileHandle.standardError.write(Data("device not registered\n".utf8)); return 11
    }

    // 받은 secret으로 인증 connect → session.start → "가나다" echo 라운드트립.
    let bearer = "\(issued.tokenId).\(received.deviceTokenSecret)"
    let handle: PTYHandle
    do {
        handle = try PTYSpawner.spawn(command: "/bin/cat", args: [], cwd: "/tmp",
                                      env: ProcessInfo.processInfo.environment, rows: 24, cols: 80)
    } catch {
        FileHandle.standardError.write(Data("spawn cat failed: \(error)\n".utf8)); return 2
    }
    let sessionId = UUID()
    let daemon = SessionDaemon()
    await attachExternalSession(server: server, daemon: daemon, masterFD: handle.masterFD)

    let received2 = Collector()
    let acked = Collector()
    let client = WSClient(port: port, bearerToken: bearer)
    do { try await client.connect() } catch {
        FileHandle.standardError.write(Data("auth connect failed: \(error)\n".utf8)); return 4
    }
    client.receiveLoop { env in
        if env.kind == .output, let text = env.payloadText { received2.append(text) }
        if env.kind == .ack { acked.append("ack") }
    }
    client.send(WSEnvelope(seq: 1, actor: cliActor, kind: .sessionStart,
                           text: client.firstSessionStartPayload(sessionId: sessionId)))
    guard await poll(timeout: 5, { acked.contains("ack") }) else {
        FileHandle.standardError.write(Data("no ack after pairing\n".utf8)); return 5
    }
    client.send(WSEnvelope(seq: 2, actor: cliActor, kind: .input, text: "가나다\n"))
    let echoed = await poll(timeout: 5, { received2.contains("가나다") })

    await server.stop()
    guard echoed else {
        FileHandle.standardError.write(Data("no echo after pairing\n".utf8)); return 6
    }
    // deviceId만 출력한다(secret 평문 금지).
    emit("PAIRED \(deviceId.uuidString)")
    return 0
}

/// P6b Day 4: 토큰 lifecycle 무효화 e2e. 데몬 1개 위에서 revoke 끊기 + 만료 거부 + revoked push
/// 제외를 순차 측정하고 3 신호를 stdout으로 내보낸다. 모바일 없이 시뮬레이션 디바이스로 전 경로를
/// 통과시킨다(LifecycleE2ETests의 in-process 검증과 동형 경로). secret/실 IP 평문은 출력하지 않는다.
func runLifecycle() async -> Int32 {
    let registry = SessionBindRegistry()
    let store = InMemoryDeviceStore()
    let server = WSServer(registry: registry, authGate: WSAuthGate(),
                          verifier: DeviceTokenVerifier(store: store))
    let pushSink = InMemoryPushRevocationSink()
    let coordinator = DeviceRevocationCoordinator(store: store, server: server, pushRevocation: pushSink)

    // 디바이스 A(유효 — revoke 대상)와 B(만료 — expiresAt 과거)를 등록한다.
    let issuedA: DeviceTokenIssuer.IssuedToken
    let issuedB: DeviceTokenIssuer.IssuedToken
    do {
        issuedA = try DeviceTokenIssuer.issue()
        issuedB = try DeviceTokenIssuer.issue()
    } catch {
        FileHandle.standardError.write(Data("token issue failed: \(error)\n".utf8)); return 7
    }
    let deviceIdA = UUID()
    let deviceIdB = UUID()
    do {
        try await store.upsert(
            Device(id: deviceIdA, name: "lifecycle-A", tokenId: issuedA.tokenId,
                   expiresAt: Date().addingTimeInterval(3600)),
            secret: issuedA.secret)
        try await store.upsert(
            Device(id: deviceIdB, name: "lifecycle-B", tokenId: issuedB.tokenId,
                   expiresAt: Date().addingTimeInterval(-3600)),
            secret: issuedB.secret)
    } catch {
        FileHandle.standardError.write(Data("device upsert failed: \(error)\n".utf8)); return 8
    }

    let port: UInt16
    do { port = try await server.start() } catch {
        FileHandle.standardError.write(Data("server start failed: \(error)\n".utf8)); return 3
    }

    // 신호 ① REVOKE_DISCONNECTED: A 인증 연결 → revoke → 끊김.
    let aState = Collector()
    let aRecv = Collector()
    let clientA = WSClient(port: port, bearerToken: issuedA.bearer)
    do {
        try await clientA.connect(onState: { aState.append($0) })
    } catch {
        FileHandle.standardError.write(Data("A connect failed: \(error)\n".utf8)); return 4
    }
    clientA.receiveLoop { env in
        if env.kind == .ack { aRecv.append("ack") }
    }
    clientA.send(WSEnvelope(seq: 1, actor: cliActor, kind: .sessionStart,
                            text: clientA.firstSessionStartPayload(sessionId: UUID())))
    guard await poll(timeout: 5, { aRecv.contains("ack") }) else {
        FileHandle.standardError.write(Data("A no ack\n".utf8)); return 5
    }
    do { try await coordinator.revoke(deviceId: deviceIdA) } catch {
        FileHandle.standardError.write(Data("revoke failed: \(error)\n".utf8)); return 12
    }
    // revoke 후 살아 있던 연결이 끊긴다 — 상태 전이가 cancelled/failed로 흐른다.
    let aDisconnected = await poll(timeout: 5, {
        aState.contains("cancelled") || aState.contains("failed")
    })
    let aDisconnectedCount = await server.disconnectedCount
    guard aDisconnected || aDisconnectedCount >= 1 else {
        FileHandle.standardError.write(Data("A not disconnected after revoke\n".utf8)); return 13
    }
    clientA.close()
    emit("REVOKE_DISCONNECTED")

    // 신호 ② EXPIRED_REJECTED: B(만료) connect → 게이트 ② UNAUTHORIZED.
    let bRecv = Collector()
    let clientB = WSClient(port: port, bearerToken: issuedB.bearer)
    do {
        try await clientB.connect()
    } catch {
        FileHandle.standardError.write(Data("B connect failed: \(error)\n".utf8)); return 4
    }
    clientB.receiveLoop { env in
        if env.kind == .error, env.code == "UNAUTHORIZED" { bRecv.append("unauthorized") }
    }
    clientB.send(WSEnvelope(seq: 1, actor: cliActor, kind: .sessionStart,
                            text: clientB.firstSessionStartPayload(sessionId: UUID())))
    guard await poll(timeout: 5, { bRecv.contains("unauthorized") }) else {
        FileHandle.standardError.write(Data("B not rejected (expected UNAUTHORIZED)\n".utf8)); return 14
    }
    clientB.close()
    emit("EXPIRED_REJECTED")

    // 신호 ③ PUSH_REJECTED_REVOKED: revoked A로의 push 발신이 필터에서 제외(transport 미호출).
    let transport = MockPushTransport()
    let sender = PushSender(
        transport: transport,
        attachment: LifecycleDetachedAttachment(),
        config: PushPolicyConfig(skipWhenAttached: true),
        revocationSink: pushSink
    )
    let pushEnvelope = PushEnvelope(
        sessionId: UUID(), messageId: UUID(), preview: "lifecycle",
        chatRoomId: UUID().uuidString, timestamp: Date(timeIntervalSince1970: 1_700_000_000),
        fetchHint: nil)
    await sender.sendIfNotRevoked(pushEnvelope, target: .fcm, deviceId: deviceIdA)
    let sentCount = await transport.sentCount
    let excludedCount = await sender.excludedCount
    guard sentCount == 0, excludedCount == 1 else {
        FileHandle.standardError.write(
            Data("push not excluded (sent=\(sentCount) excluded=\(excludedCount))\n".utf8)); return 15
    }
    emit("PUSH_REJECTED_REVOKED")

    await server.stop()
    return 0
}

/// push 발신 필터 측정 시 WS-attached skip이 가로채지 않도록 항상 detached를 반환한다(deviceId
/// 필터 경로만 격리). LifecycleE2ETests의 AlwaysDetachedAttachment와 동형.
private struct LifecycleDetachedAttachment: AttachmentQuerying {
    func isAttached(_ sessionId: UUID) async -> Bool { false }
}

if arguments.contains("--lifecycle") {
    Task { exit(await runLifecycle()) }
    RunLoop.main.run()
} else if arguments.contains("--pair") {
    Task { exit(await runPair()) }
    RunLoop.main.run()
} else if arguments.contains("--roundtrip") {
    Task { exit(await runRoundtrip()) }
    RunLoop.main.run()
} else if arguments.contains("--flood") {
    Task { exit(await runFlood()) }
    RunLoop.main.run()
} else if arguments.contains("--connect-auth") {
    Task { exit(await runConnectAuth()) }
    RunLoop.main.run()
} else if let idx = arguments.firstIndex(of: "--connect"),
          idx + 1 < arguments.count, let port = UInt16(arguments[idx + 1]) {
    // --connect는 외부 --serve-probe에 붙는다. 그 서버는 같은 store를 모르므로 이 probe는
    // 자체 발급 토큰으로 핸드셰이크 구조 검증만 통과한다(게이트 ②는 store 불일치로 막힘).
    // 연결성/상태 전이 진단이 목적이라 ack까지 요구하지 않는다.
    let issued = try? DeviceTokenIssuer.issue()
    // 발급 실패 fallback도 구조 검증(secret이 base64url로 디코드 가능)을 확실히 통과하는
    // 형식으로 만든다. 내용은 무의미해도 된다 — 이 probe는 핸드셰이크 구조 검증까지만 본다.
    let fallbackBearer = "tok.\(Base64URL.encode(Data(repeating: 0, count: 32)))"
    let client = WSClient(port: port, bearerToken: issued?.bearer ?? fallbackBearer)
    Task {
        do {
            try await client.connect(onState: { emit("STATE \($0)") })
            emit("CONNECTED")
            client.receiveLoop { env in emit("RECV kind=\(env.kind.rawValue) code=\(env.code ?? "-")") }
            let sessionId = UUID()
            client.send(WSEnvelope(seq: 1, actor: cliActor, kind: .sessionStart,
                                   text: client.firstSessionStartPayload(sessionId: sessionId)))
        } catch {
            emit("CONNECT_FAILED \(error)")
            exit(2)
        }
    }
    RunLoop.main.run()
} else if arguments.contains("--serve-probe") {
    let registry = SessionBindRegistry()
    Task {
        do {
            let authed = try await makeAuthedDaemon(registry: registry)
            let port = try await authed.server.start()
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
        Data("usage: daemon-dev-cli [--pair|--lifecycle|--roundtrip|--flood|--serve-probe|--connect <port>|--connect-auth]\n".utf8)
    )
    exit(0)
}
