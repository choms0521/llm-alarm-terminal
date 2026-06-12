import XCTest
import Foundation
import Network

/// P6b Day 2 — revoke 즉시 끊기(D-2 옵션 A) 검증.
///
/// 측정 대상(계획서 Day 2 종료 조건):
/// - revoke 즉시 끊기: 인증 연결 수립 후 coordinator.revoke → 5초 내 끊김 + boundSession nil
/// - 같은 Bearer 2연결 동시 수립 → revoke → 두 connection 모두 5초 내 끊김 + disconnectedCount == 2
/// - 역참조 정합: 서로 다른 2 디바이스 중 1개 revoke → 그 연결만 끊김, 다른 연결 생존(ack 수신)
/// - revoke 후 재연결 거부: 같은 Bearer 재connect → 게이트 ② UNAUTHORIZED + 5초 내 끊김
/// - disconnectDevice 멱등: 같은 deviceId 2회 호출 + 미연결 디바이스 revoke no-op
/// - Coordinator 순서 보장: revoke 후 revoked == true + connection 끊김 + push 카운터 +1
/// - Coordinator 부분 실패: store.revoke throw → ②③ 미진입 + throw 전파
final class RevocationDisconnectTests: XCTestCase {
    private let clientActor = EnvelopeActor(deviceId: "revoke-test-client")

    // MARK: - fixture

    /// 디바이스 N개를 등록한 인증 서버 + 각 디바이스의 (bearer, deviceId)를 만든다.
    private func makeServerWithDevices(count: Int, registry: SessionBindRegistry) async throws
        -> (server: WSServer, store: InMemoryDeviceStore, devices: [(bearer: String, deviceId: UUID)]) {
        let store = InMemoryDeviceStore()
        var devices: [(bearer: String, deviceId: UUID)] = []
        for i in 0..<count {
            let issued = try DeviceTokenIssuer.issue()
            let deviceId = UUID()
            let device = Device(id: deviceId, name: "dev-\(i)", tokenId: issued.tokenId,
                                expiresAt: Date().addingTimeInterval(3600))
            try await store.upsert(device, secret: issued.secret)
            devices.append((bearer: issued.bearer, deviceId: deviceId))
        }
        let server = WSServer(registry: registry, authGate: WSAuthGate(),
                              verifier: DeviceTokenVerifier(store: store))
        return (server, store, devices)
    }

    // MARK: - 종료 조건: revoke 즉시 끊기 (5초 내 + boundSession nil)

    func testRevokeDisconnectsLiveConnectionWithinFiveSeconds() async throws {
        let registry = SessionBindRegistry()
        let (server, store, devices) = try await makeServerWithDevices(count: 1, registry: registry)
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let pushSink = InMemoryPushRevocationSink()
        let coordinator = DeviceRevocationCoordinator(store: store, server: server, pushRevocation: pushSink)

        // 인증 연결 수립 + session.start 바인딩.
        let nonce = WSAuthGate.makeNonce()!
        let client = RevocationTestClient(port: port, bearer: devices[0].bearer, nonce: nonce)
        try await client.connectReady()
        let sid = UUID()
        client.send(WSEnvelope(seq: 1, actor: clientActor, kind: .sessionStart,
                               text: #"{"sessionId":"\#(sid.uuidString)","nonce":"\#(nonce)"}"#))
        let gotAck = await client.waitForKind(.ack, timeout: 5)
        XCTAssertTrue(gotAck, "인증 연결이 session.start ack을 받아야 한다")
        let boundBefore = await registry.boundClient(forSession: sid)
        XCTAssertNotNil(boundBefore, "revoke 전에는 세션 바인딩이 존재한다")

        // revoke → 5초 내 연결 끊김 + 바인딩 해제.
        try await coordinator.revoke(deviceId: devices[0].deviceId)
        let cancelled = await client.waitForCancelled(timeout: 5)
        XCTAssertTrue(cancelled, "revoke 시 연결이 5초 내 끊겨야 한다(누출 창 0)")
        let boundAfter = await registry.boundClient(forSession: sid)
        XCTAssertNil(boundAfter, "revoke 후 boundSession이 nil이어야 한다(registry cleanup)")
        let count = await server.disconnectedCount
        XCTAssertEqual(count, 1, "단일 연결 revoke는 disconnectedCount == 1")
        client.close()
        await server.stop()
    }

    // MARK: - 종료 조건: 같은 Bearer 2연결 모두 끊김 (disconnectedCount == 2)

    func testSameBearerTwoConnectionsBothDisconnected() async throws {
        let registry = SessionBindRegistry()
        let (server, store, devices) = try await makeServerWithDevices(count: 1, registry: registry)
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let coordinator = DeviceRevocationCoordinator(store: store, server: server,
                                                      pushRevocation: InMemoryPushRevocationSink())

        // 같은 Bearer로 2연결 동시 수립(각 연결은 자신만의 nonce). 둘 다 승격돼 역인덱스 집합에 들어간다.
        let nonce1 = WSAuthGate.makeNonce()!
        let nonce2 = WSAuthGate.makeNonce()!
        let c1 = RevocationTestClient(port: port, bearer: devices[0].bearer, nonce: nonce1)
        let c2 = RevocationTestClient(port: port, bearer: devices[0].bearer, nonce: nonce2)
        try await c1.connectReady()
        try await c2.connectReady()
        c1.send(WSEnvelope(seq: 1, actor: clientActor, kind: .sessionStart,
                           text: #"{"sessionId":"\#(UUID().uuidString)","nonce":"\#(nonce1)"}"#))
        c2.send(WSEnvelope(seq: 1, actor: clientActor, kind: .sessionStart,
                           text: #"{"sessionId":"\#(UUID().uuidString)","nonce":"\#(nonce2)"}"#))
        let ack1 = await c1.waitForKind(.ack, timeout: 5)
        let ack2 = await c2.waitForKind(.ack, timeout: 5)
        XCTAssertTrue(ack1, "연결1 승격(ack)")
        XCTAssertTrue(ack2, "연결2 승격(ack)")

        // 그 deviceId revoke → 두 connection 모두 끊김(단일 매핑 덮어쓰기로 한 연결이 살아남는 회귀 차단).
        try await coordinator.revoke(deviceId: devices[0].deviceId)
        let cancelled1 = await c1.waitForCancelled(timeout: 5)
        let cancelled2 = await c2.waitForCancelled(timeout: 5)
        XCTAssertTrue(cancelled1, "연결1이 5초 내 끊겨야 한다")
        XCTAssertTrue(cancelled2, "연결2도 5초 내 끊겨야 한다")
        let count = await server.disconnectedCount
        XCTAssertEqual(count, 2, "같은 Bearer 2연결 모두 끊겨 disconnectedCount == 2(누출 창 0)")
        c1.close(); c2.close()
        await server.stop()
    }

    // MARK: - 종료 조건: 역참조 정합 (서로 다른 2 디바이스 중 1개만 revoke → 다른 연결 생존)

    func testRevokeOneDeviceLeavesOtherConnectionAlive() async throws {
        let registry = SessionBindRegistry()
        let (server, store, devices) = try await makeServerWithDevices(count: 2, registry: registry)
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let coordinator = DeviceRevocationCoordinator(store: store, server: server,
                                                      pushRevocation: InMemoryPushRevocationSink())

        let nonceA = WSAuthGate.makeNonce()!
        let nonceB = WSAuthGate.makeNonce()!
        let cA = RevocationTestClient(port: port, bearer: devices[0].bearer, nonce: nonceA)
        let cB = RevocationTestClient(port: port, bearer: devices[1].bearer, nonce: nonceB)
        try await cA.connectReady()
        try await cB.connectReady()
        let sidA = UUID()
        let sidB = UUID()
        cA.send(WSEnvelope(seq: 1, actor: clientActor, kind: .sessionStart,
                           text: #"{"sessionId":"\#(sidA.uuidString)","nonce":"\#(nonceA)"}"#))
        cB.send(WSEnvelope(seq: 1, actor: clientActor, kind: .sessionStart,
                           text: #"{"sessionId":"\#(sidB.uuidString)","nonce":"\#(nonceB)"}"#))
        let ackA = await cA.waitForKind(.ack, timeout: 5)
        let ackB = await cB.waitForKind(.ack, timeout: 5)
        XCTAssertTrue(ackA, "A 승격(ack)")
        XCTAssertTrue(ackB, "B 승격(ack)")

        // A만 revoke → A 끊김, B 생존(오끊김 0건). B는 후속 envelope에 정상 ack을 받아 살아 있음을 실증.
        try await coordinator.revoke(deviceId: devices[0].deviceId)
        let cancelledA = await cA.waitForCancelled(timeout: 5)
        XCTAssertTrue(cancelledA, "revoke된 A는 끊겨야 한다")

        // B 생존 확인: pause envelope(예약 kind)에 ack을 받으면 연결이 살아 있다.
        cB.send(WSEnvelope(seq: 2, actor: clientActor, kind: .pause, text: "{}"))
        let ackBSecond = await cB.waitForKindCount(.ack, count: 2, timeout: 5)
        XCTAssertTrue(ackBSecond, "revoke 안 된 B는 살아 후속 envelope에 ack을 받아야 한다(오끊김 0)")
        let bCancelled = await cB.sawCancelled()
        XCTAssertFalse(bCancelled, "B는 끊기지 않아야 한다")
        let count = await server.disconnectedCount
        XCTAssertEqual(count, 1, "1개 디바이스만 revoke → disconnectedCount == 1")
        cA.close(); cB.close()
        await server.stop()
    }

    // MARK: - 종료 조건: revoke 후 재연결 거부 (게이트 ② UNAUTHORIZED)

    func testReconnectAfterRevokeRejectedAtGateTwo() async throws {
        let registry = SessionBindRegistry()
        let (server, store, devices) = try await makeServerWithDevices(count: 1, registry: registry)
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let coordinator = DeviceRevocationCoordinator(store: store, server: server,
                                                      pushRevocation: InMemoryPushRevocationSink())

        // 첫 연결 수립 후 revoke로 끊는다.
        let nonce1 = WSAuthGate.makeNonce()!
        let first = RevocationTestClient(port: port, bearer: devices[0].bearer, nonce: nonce1)
        try await first.connectReady()
        first.send(WSEnvelope(seq: 1, actor: clientActor, kind: .sessionStart,
                              text: #"{"sessionId":"\#(UUID().uuidString)","nonce":"\#(nonce1)"}"#))
        let firstAck = await first.waitForKind(.ack, timeout: 5)
        XCTAssertTrue(firstAck, "첫 연결 승격(ack)")
        try await coordinator.revoke(deviceId: devices[0].deviceId)
        let firstCancelled = await first.waitForCancelled(timeout: 5)
        XCTAssertTrue(firstCancelled, "revoke로 첫 연결 끊김")
        first.close()

        // 같은 Bearer로 재connect → 핸드셰이크는 성립(구조 유효)하나 게이트 ②에서 verifier !revoked 거부.
        let nonce2 = WSAuthGate.makeNonce()!
        let again = RevocationTestClient(port: port, bearer: devices[0].bearer, nonce: nonce2)
        try await again.connectReady()
        again.send(WSEnvelope(seq: 1, actor: clientActor, kind: .sessionStart,
                              text: #"{"sessionId":"\#(UUID().uuidString)","nonce":"\#(nonce2)"}"#))
        let unauthorized = await again.waitForError(code: "UNAUTHORIZED", timeout: 5)
        XCTAssertTrue(unauthorized, "revoked 디바이스 재연결은 게이트 ② UNAUTHORIZED여야 한다")
        let againCancelled = await again.waitForCancelled(timeout: 5)
        XCTAssertTrue(againCancelled, "UNAUTHORIZED 후 5초 내 끊김")
        await server.stop()
    }

    // MARK: - 종료 조건: disconnectDevice 멱등 (2회 호출 + 미연결 디바이스 no-op)

    func testDisconnectDeviceIdempotentAndNoOpForUnconnected() async throws {
        let registry = SessionBindRegistry()
        let (server, _, devices) = try await makeServerWithDevices(count: 1, registry: registry)
        let port = try await server.start()
        defer { Task { await server.stop() } }

        // 연결된 적 없는 deviceId revoke → disconnectDevice no-op(crash 0, 카운터 불변).
        let unconnected = UUID()
        await server.disconnectDevice(deviceId: unconnected)
        let countAfterUnconnected = await server.disconnectedCount
        XCTAssertEqual(countAfterUnconnected, 0, "미연결 디바이스 disconnectDevice는 no-op")

        // 1연결 수립 후 disconnectDevice 2회 연속 호출 → 첫 호출만 끊고 둘째는 no-op(이중 cleanup 0).
        let nonce = WSAuthGate.makeNonce()!
        let client = RevocationTestClient(port: port, bearer: devices[0].bearer, nonce: nonce)
        try await client.connectReady()
        client.send(WSEnvelope(seq: 1, actor: clientActor, kind: .sessionStart,
                               text: #"{"sessionId":"\#(UUID().uuidString)","nonce":"\#(nonce)"}"#))
        let idemAck = await client.waitForKind(.ack, timeout: 5)
        XCTAssertTrue(idemAck, "연결 승격(ack)")

        await server.disconnectDevice(deviceId: devices[0].deviceId)
        await server.disconnectDevice(deviceId: devices[0].deviceId)   // 2회째 = guard no-op
        let countAfterDouble = await server.disconnectedCount
        XCTAssertEqual(countAfterDouble, 1,
                       "2회 연속 disconnectDevice는 1번만 끊는다(둘째는 no-op, 이중 cleanup 부작용 0)")
        client.close()
        await server.stop()
    }

    // MARK: - 종료 조건: Coordinator 순서 보장 (revoked + 끊김 + push 카운터)

    func testCoordinatorOrderingRevokeDisconnectPush() async throws {
        let registry = SessionBindRegistry()
        let (server, store, devices) = try await makeServerWithDevices(count: 1, registry: registry)
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let pushSink = InMemoryPushRevocationSink()
        let coordinator = DeviceRevocationCoordinator(store: store, server: server, pushRevocation: pushSink)

        let nonce = WSAuthGate.makeNonce()!
        let client = RevocationTestClient(port: port, bearer: devices[0].bearer, nonce: nonce)
        try await client.connectReady()
        client.send(WSEnvelope(seq: 1, actor: clientActor, kind: .sessionStart,
                               text: #"{"sessionId":"\#(UUID().uuidString)","nonce":"\#(nonce)"}"#))
        let orderAck = await client.waitForKind(.ack, timeout: 5)
        XCTAssertTrue(orderAck, "연결 승격(ack)")

        // revoke 전: push 미표시.
        let revokedBefore = await pushSink.isRevoked(deviceId: devices[0].deviceId)
        XCTAssertFalse(revokedBefore, "revoke 전 push 미표시")

        try await coordinator.revoke(deviceId: devices[0].deviceId)

        // (a) store revoked == true, (b) connection 끊김, (c) push seam 통지.
        let found = try await store.list().first { $0.id == devices[0].deviceId }
        XCTAssertEqual(found?.revoked, true, "① store revoke 표시")
        let orderCancelled = await client.waitForCancelled(timeout: 5)
        XCTAssertTrue(orderCancelled, "② 연결 끊김")
        let revokedAfter = await pushSink.isRevoked(deviceId: devices[0].deviceId)
        XCTAssertTrue(revokedAfter, "③ push seam 통지(+1)")
        let disconnectedAfter = await server.disconnectedCount
        XCTAssertGreaterThanOrEqual(disconnectedAfter, 1, "연결이 있었으면 disconnectedCount >= 1")
        client.close()
        await server.stop()
    }

    // MARK: - 종료 조건: Coordinator 부분 실패 (store.revoke throw → ②③ 미진입)

    func testCoordinatorPartialFailureStoreRevokeThrows() async throws {
        // store.revoke가 throw하는 fake store → revoke가 throw 전파 + disconnect/push 미실행.
        let throwingStore = ThrowingRevokeStore()
        let registry = SessionBindRegistry()
        let server = WSServer(registry: registry, authGate: WSAuthGate(),
                              verifier: DeviceTokenVerifier(store: throwingStore))
        // 서버를 start하지 않아도 disconnectDevice는 no-op(연결 0). disconnectedCount 불변 측정 목적.
        let pushSink = InMemoryPushRevocationSink()
        let coordinator = DeviceRevocationCoordinator(store: throwingStore, server: server, pushRevocation: pushSink)

        let deviceId = UUID()
        await XCTAssertThrowsErrorAsync(try await coordinator.revoke(deviceId: deviceId)) { error in
            XCTAssertTrue(error is StoreRevokeError, "store.revoke의 throw가 그대로 전파돼야 한다")
        }
        let disconnectedAfterThrow = await server.disconnectedCount
        XCTAssertEqual(disconnectedAfterThrow, 0, "① throw 시 ② disconnectDevice 미진입(카운터 불변)")
        let pushAfterThrow = await pushSink.isRevoked(deviceId: deviceId)
        XCTAssertFalse(pushAfterThrow, "① throw 시 ③ push 통지 미진입")
    }
}

// MARK: - throw하는 fake store (7메서드 전부 스텁)

private struct StoreRevokeError: Error {}

/// revoke만 throw하고 나머지는 no-op/빈값을 반환하는 fake DeviceStore. Coordinator 부분 실패
/// 테스트 전용 — DeviceStore protocol 7메서드를 전부 스텁해야 conformance가 성립한다.
private actor ThrowingRevokeStore: DeviceStore {
    func list() async throws -> [Device] { [] }
    func upsert(_ device: Device, secret: Data) async throws {}
    func find(byTokenId tokenId: String) async throws -> Device? { nil }
    func secret(forTokenId tokenId: String) async throws -> Data? { nil }
    func revoke(id: UUID) async throws { throw StoreRevokeError() }   // ① 실패 지점
    func promote(id: UUID, to expiresAt: Date) async throws {}
    func remove(id: UUID) async throws {}
}

// MARK: - async throws 어서션 헬퍼

/// async 표현식이 throw하는지 검증한다(XCTAssertThrowsError의 async 변형). XCTest에 내장 async
/// 변형이 없어 직접 구성한다 — throw하지 않으면 실패, throw하면 errorHandler에 넘긴다.
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("throw해야 하는데 성공했다. \(message)", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}

// MARK: - revoke 테스트 클라이언트 (헤더 제어 + 끊김/수신 관측)

/// Bearer/nonce 헤더를 제어하고 끊김(.cancelled/.failed/peer-FIN)과 수신 envelope을 관측하는
/// 테스트 클라이언트. WSAuthGateIntegrationTests의 RawAuthClient와 동형이나 ack 카운트 헬퍼를 더했다.
private final class RevocationTestClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "revoke-test-client")
    private let received = RevReceivedStore()
    private let state = RevStateStore()

    init(port: UInt16, bearer: String?, nonce: String?) {
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        var headers: [(name: String, value: String)] = []
        if let bearer { headers.append((name: "Authorization", value: "Bearer \(bearer)")) }
        if let nonce { headers.append((name: "X-Pair-Nonce", value: nonce)) }
        if !headers.isEmpty { ws.setAdditionalHeaders(headers) }
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        let url = URL(string: "ws://127.0.0.1:\(port)/")!
        connection = NWConnection(to: .url(url), using: params)
    }

    func connectReady(timeout: TimeInterval = 5) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = RevOnce()
            connection.stateUpdateHandler = { [weak self] st in
                self?.state.record(st)
                switch st {
                case .ready: if once.fire() { cont.resume() }
                case .failed(let e): if once.fire() { cont.resume(throwing: e) }
                case .cancelled: if once.fire() { cont.resume(throwing: URLError(.cancelled)) }
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                if once.fire() { cont.resume(throwing: URLError(.timedOut)) }
            }
        }
        receiveLoop()
    }

    private func receiveLoop() {
        connection.receiveMessage { [weak self] content, context, _, error in
            guard let self else { return }
            if let content, let env = try? EnvelopeCodec.decode(content) {
                self.received.append(env)
            }
            let closed = error != nil || (context?.isFinal ?? false)
            if closed { self.state.recordClosed(); return }
            self.receiveLoop()
        }
    }

    func send(_ envelope: WSEnvelope) {
        guard let data = try? EnvelopeCodec.encode(envelope) else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "send", metadata: [meta])
        connection.send(content: data, contentContext: context, isComplete: true,
                        completion: .contentProcessed { _ in })
    }

    func waitForKind(_ kind: EnvelopeKind, timeout: TimeInterval) async -> Bool {
        await poll(timeout: timeout) { self.received.all().contains { $0.kind == kind } }
    }

    func waitForKindCount(_ kind: EnvelopeKind, count: Int, timeout: TimeInterval) async -> Bool {
        await poll(timeout: timeout) { self.received.all().filter { $0.kind == kind }.count >= count }
    }

    func waitForError(code: String, timeout: TimeInterval) async -> Bool {
        await poll(timeout: timeout) {
            self.received.all().contains { $0.kind == .error && $0.code == code }
        }
    }

    func waitForCancelled(timeout: TimeInterval) async -> Bool {
        await poll(timeout: timeout) { self.state.sawClosed() }
    }

    func sawCancelled() async -> Bool { state.sawClosed() }

    func close() { connection.cancel() }

    private func poll(timeout: TimeInterval, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }
}

private final class RevReceivedStore: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [WSEnvelope] = []
    func append(_ env: WSEnvelope) { lock.lock(); items.append(env); lock.unlock() }
    func all() -> [WSEnvelope] { lock.lock(); defer { lock.unlock() }; return items }
}

private final class RevStateStore: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    func record(_ st: NWConnection.State) {
        lock.lock(); defer { lock.unlock() }
        if case .cancelled = st { closed = true }
        if case .failed = st { closed = true }
    }
    func recordClosed() { lock.lock(); defer { lock.unlock() }; closed = true }
    func sawClosed() -> Bool { lock.lock(); defer { lock.unlock() }; return closed }
}

private final class RevOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
