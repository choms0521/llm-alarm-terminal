import XCTest
import Foundation
import Network

/// P6b Day 1 — 토큰 lifecycle 코어 + pending 승격(부채 해소) 검증.
///
/// 측정 대상(계획서 Day 1 종료 조건):
/// - pending 발급: issueNewCode 후 store 디바이스 expiresAt이 now+ttl(5분) 경계(30일 아님)
/// - claim 승격 데몬 경로 e2e: pending 디바이스를 PairingClaimClient로 claim 성공 → onClaimed →
///   DevicePromotionCoordinator.promote 경로로 expiresAt이 now+30일 갱신(수동 promote 호출 금지)
/// - 만료 임박 판정: 6일/8일/0.5일 → expiringWithin(7)이 6일·0.5일만 포함
/// - 만료 거부 회귀: expiresAt 과거 디바이스 verify == nil(P6a 비파괴)
/// - revoked 부활 차단 경쟁: revoke 후 promote → revoked 유지 + expiresAt 미갱신
/// - 승격 경쟁 경계: 만료 1초 전 claim → 승격 / 만료 1초 후 claim → claim == nil(승격 미트리거)
/// - 승격기 actor 카운터: onClaimed 콜백 경유 후 promotedCount >= 1
final class DeviceLifecycleTests: XCTestCase {

    // MARK: - 만료 임박 판정 (순수 정책)

    func testExpiringSoonIncludesOnlyWithinWindow() {
        let policy = DeviceLifecyclePolicy(activeLifetime: 30 * 86400, expiringWithinDays: 7)
        let now = Date(timeIntervalSince1970: 1_000_000)

        let in6Days = makeDevice(expiresAt: now.addingTimeInterval(6 * 86400))
        let in8Days = makeDevice(expiresAt: now.addingTimeInterval(8 * 86400))
        let inHalfDay = makeDevice(expiresAt: now.addingTimeInterval(0.5 * 86400))
        let alreadyExpired = makeDevice(expiresAt: now.addingTimeInterval(-3600))

        XCTAssertEqual(policy.isExpiringSoon(in6Days, now: now), true,
                       "6일 후 만료는 7일 창 안이라 임박이다")
        XCTAssertEqual(policy.isExpiringSoon(in8Days, now: now), false,
                       "8일 후 만료는 7일 창 밖이라 임박이 아니다")
        XCTAssertEqual(policy.isExpiringSoon(inHalfDay, now: now), true,
                       "0.5일 후 만료는 7일 창 안이라 임박이다")
        XCTAssertEqual(policy.isExpiringSoon(alreadyExpired, now: now), false,
                       "이미 만료된 디바이스는 임박에서 제외된다(거부는 verifier 몫)")
    }

    func testDaysRemainingRoundsUp() {
        let policy = DeviceLifecyclePolicy(activeLifetime: 30 * 86400, expiringWithinDays: 7)
        let now = Date(timeIntervalSince1970: 1_000_000)
        // 6.5일 남으면 올림으로 7일 표기.
        let device = makeDevice(expiresAt: now.addingTimeInterval(6.5 * 86400))
        XCTAssertEqual(policy.daysRemaining(device, now: now), 7,
                       "6.5일 남으면 올림으로 7일이다")
    }

    // MARK: - pending 발급 (발급 시퀀스 후 5분 경계)

    /// 발급 시 pending(코드 ttl=5분) upsert를 검증한다. PairingModel은 app 타겟 전용(5개 non-app
    /// 타겟에서 excludes)이라 DaemonTests에서 직접 호출할 수 없으므로, issueNewCode와 동형인 발급
    /// 시퀀스(lifecycle.pendingExpiry(codeTTL: ttl) → store.upsert)를 데몬 경로 그대로 실측한다.
    /// DaemonDevCLI --pair와 PairingModel.issueNewCode가 공유하는 그 시퀀스가 5분 경계를 만든다.
    func testIssueSequenceUpsertsPendingExpiryNotThirtyDays() async throws {
        let store = InMemoryDeviceStore()
        let ttl: TimeInterval = 300
        let lifecycle = DeviceLifecyclePolicy(activeLifetime: 30 * 86400, expiringWithinDays: 7)
        let issued = try DeviceTokenIssuer.issue()

        let before = Date()
        let pendingExpiry = lifecycle.pendingExpiry(codeTTL: ttl, now: before)
        let device = Device(id: UUID(), name: "페어링 대기 디바이스",
                            tokenId: issued.tokenId, expiresAt: pendingExpiry)
        try await store.upsert(device, secret: issued.secret)
        let after = Date()

        let devices = try await store.list()
        XCTAssertEqual(devices.count, 1, "발급 후 디바이스 1건이 store에 있어야 한다")
        let stored = try XCTUnwrap(devices.first)

        // pending expiry는 발급 시각 + ttl(5분) 경계여야 한다(30일 아님). ±2초 허용.
        let lowerBound = before.addingTimeInterval(ttl - 2)
        let upperBound = after.addingTimeInterval(ttl + 2)
        XCTAssertTrue(stored.expiresAt >= lowerBound && stored.expiresAt <= upperBound,
                      "expiresAt이 now+ttl(5분) 경계여야 한다(30일 아님). actual=\(stored.expiresAt)")

        // 30일 경계와 명확히 구분: 5분 expiry는 now + 1일보다 훨씬 작다.
        XCTAssertTrue(stored.expiresAt < after.addingTimeInterval(86400),
                      "pending expiry는 1일 미만이어야 한다(30일 부여 부채 제거 확인)")
    }

    // MARK: - claim 승격 데몬 경로 e2e (PairingClaimClient 실 채널)

    func testClaimPromotesPendingToActiveViaDaemonPath() async throws {
        let store = InMemoryDeviceStore()
        let ttl: TimeInterval = 300
        let activeLifetime: TimeInterval = 30 * 86400
        let lifecycle = DeviceLifecyclePolicy(activeLifetime: activeLifetime, expiringWithinDays: 7)
        let session = PairingSession(ttl: ttl)
        let coordinator = DevicePromotionCoordinator(store: store, lifecycle: lifecycle)
        await session.setOnClaimed { deviceId in
            await coordinator.promote(deviceId: deviceId)
        }
        let verifier = DeviceTokenVerifier(store: store)
        let server = WSServer(registry: SessionBindRegistry(), authGate: WSAuthGate(),
                              verifier: verifier, pairingSession: session)
        let port = try await server.start()
        defer { Task { await server.stop() } }

        // pending 디바이스 발급(5분 수명) + 코드에 deviceId 묶기.
        let deviceId = UUID()
        let issued = try DeviceTokenIssuer.issue()
        let now = Date()
        let pendingExpiry = lifecycle.pendingExpiry(codeTTL: ttl, now: now)
        let device = Device(id: deviceId, name: "pending-device", tokenId: issued.tokenId,
                            expiresAt: pendingExpiry)
        try await store.upsert(device, secret: issued.secret)
        let payload = PairingPayload(pairingId: UUID().uuidString,
                                     deviceTokenSecret: issued.secretBase64url,
                                     wsEndpoint: "ws://127.0.0.1:\(port)/",
                                     pushChannelHint: "mock-e2e", expiresAt: pendingExpiry)
        let code = try await session.issue(payload: payload, deviceId: deviceId)

        // 실 claim 채널 통과(수동 promote 직접 호출 금지). PairingClaimClient가 코드를 제출한다.
        let claimClient = PairingClaimClient(port: port)
        let outcome = await claimClient.claim(code: code)
        guard case .success = outcome else {
            return XCTFail("claim이 성공해야 한다 — \(outcome)")
        }

        // onClaimed → Coordinator.promote가 store의 expiresAt을 now+30일로 갱신했는지 확인한다.
        let promotedFound = try await store.find(byTokenId: issued.tokenId)
        let promoted = try XCTUnwrap(promotedFound)
        let expectedActive = now.addingTimeInterval(activeLifetime)
        XCTAssertEqual(promoted.expiresAt.timeIntervalSince1970,
                       expectedActive.timeIntervalSince1970, accuracy: 5,
                       "claim 승격 후 expiresAt이 now+30일로 갱신돼야 한다")
        XCTAssertFalse(promoted.revoked, "승격된 디바이스는 미폐기 상태여야 한다")
        let count = await coordinator.promotedCount
        XCTAssertGreaterThanOrEqual(count, 1, "claim 채널 통과 후 승격기 카운터가 올라야 한다")

        await server.stop()
    }

    func testUnclaimedPendingDeviceRejectedAfterExpiry() async throws {
        // 미claim pending 디바이스는 5분 후 verifier가 거부한다(승격 미발생 → pending 만료).
        let store = InMemoryDeviceStore()
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        let issued = try DeviceTokenIssuer.issue()
        // expiresAt을 과거(이미 만료)로 두어 "미claim 후 만료" 상태를 직접 구성한다.
        let device = Device(id: UUID(), name: "unclaimed", tokenId: issued.tokenId,
                            expiresAt: t0.addingTimeInterval(-1))
        try await store.upsert(device, secret: issued.secret)
        let verifier = DeviceTokenVerifier(store: store)
        let verified = await verifier.verify(tokenId: issued.tokenId, presentedSecret: issued.secret)
        XCTAssertNil(verified, "미claim 후 만료된 pending 디바이스는 verify가 nil이어야 한다")
    }

    // MARK: - 만료 거부 회귀 (P6a 비파괴)

    func testExpiredDeviceRejectedByVerifier() async throws {
        let store = InMemoryDeviceStore()
        let issued = try DeviceTokenIssuer.issue()
        let device = Device(id: UUID(), name: "expired", tokenId: issued.tokenId,
                            expiresAt: Date().addingTimeInterval(-3600))
        try await store.upsert(device, secret: issued.secret)
        let verifier = DeviceTokenVerifier(store: store)
        let verified = await verifier.verify(tokenId: issued.tokenId, presentedSecret: issued.secret)
        XCTAssertNil(verified, "expiresAt 과거 디바이스는 verify == nil이어야 한다(P6a 거부 비파괴)")
    }

    // MARK: - revoked 부활 차단 경쟁

    func testRevokedDeviceNotResurrectedByPromote() async throws {
        let store = InMemoryDeviceStore()
        let ttl: TimeInterval = 300
        let lifecycle = DeviceLifecyclePolicy(activeLifetime: 30 * 86400, expiringWithinDays: 7)
        let issued = try DeviceTokenIssuer.issue()
        let deviceId = UUID()
        let now = Date()
        let pendingExpiry = lifecycle.pendingExpiry(codeTTL: ttl, now: now)
        let device = Device(id: deviceId, name: "pending", tokenId: issued.tokenId,
                            expiresAt: pendingExpiry)
        try await store.upsert(device, secret: issued.secret)

        // revoke 후 도착한 promote가 폐기 디바이스를 30일 active로 되살리면 안 된다(no-op).
        try await store.revoke(id: deviceId)
        try await store.promote(id: deviceId, to: lifecycle.activeExpiry(now: now))

        let afterFound = try await store.find(byTokenId: issued.tokenId)
        let after = try XCTUnwrap(afterFound)
        XCTAssertTrue(after.revoked, "revoke 후 promote는 revoked 상태를 유지해야 한다(부활 차단)")
        XCTAssertEqual(after.expiresAt.timeIntervalSince1970,
                       pendingExpiry.timeIntervalSince1970, accuracy: 0.001,
                       "revoked 디바이스 promote는 expiresAt을 갱신하지 않아야 한다(no-op)")
    }

    func testRevokedDeviceNotResurrectedViaCoordinator() async throws {
        let store = InMemoryDeviceStore()
        let lifecycle = DeviceLifecyclePolicy(activeLifetime: 30 * 86400, expiringWithinDays: 7)
        let coordinator = DevicePromotionCoordinator(store: store, lifecycle: lifecycle)
        let issued = try DeviceTokenIssuer.issue()
        let deviceId = UUID()
        let now = Date()
        let pendingExpiry = now.addingTimeInterval(300)
        let device = Device(id: deviceId, name: "pending", tokenId: issued.tokenId,
                            expiresAt: pendingExpiry)
        try await store.upsert(device, secret: issued.secret)

        try await store.revoke(id: deviceId)
        await coordinator.promote(deviceId: deviceId)

        let afterFound = try await store.find(byTokenId: issued.tokenId)
        let after = try XCTUnwrap(afterFound)
        XCTAssertTrue(after.revoked, "Coordinator.promote도 revoked 디바이스를 부활시키지 않아야 한다")
        XCTAssertEqual(after.expiresAt.timeIntervalSince1970,
                       pendingExpiry.timeIntervalSince1970, accuracy: 0.001,
                       "Coordinator 경유 promote도 revoked면 expiresAt 미갱신")
    }

    // MARK: - 승격 경쟁 경계

    func testClaimJustBeforeExpiryPromotesJustAfterDoesNot() async throws {
        let store = InMemoryDeviceStore()
        let ttl: TimeInterval = 300
        let lifecycle = DeviceLifecyclePolicy(activeLifetime: 30 * 86400, expiringWithinDays: 7)
        let t0 = Date(timeIntervalSince1970: 3_000_000)

        // (a) 만료 1초 전 claim → 승격 성공.
        let clockBefore = ClockBox(now: t0)
        let sessionBefore = PairingSession(ttl: ttl, now: { clockBefore.value })
        let coordinatorBefore = DevicePromotionCoordinator(store: store, lifecycle: lifecycle)
        await sessionBefore.setOnClaimed { deviceId in
            await coordinatorBefore.promote(deviceId: deviceId)
        }
        let issuedA = try DeviceTokenIssuer.issue()
        let deviceIdA = UUID()
        let deviceA = Device(id: deviceIdA, name: "a", tokenId: issuedA.tokenId,
                             expiresAt: t0.addingTimeInterval(ttl))
        try await store.upsert(deviceA, secret: issuedA.secret)
        let payloadA = PairingPayload(pairingId: UUID().uuidString,
                                      deviceTokenSecret: issuedA.secretBase64url,
                                      wsEndpoint: "ws://127.0.0.1:1/", pushChannelHint: "m",
                                      expiresAt: t0.addingTimeInterval(ttl))
        let codeA = try await sessionBefore.issue(payload: payloadA, deviceId: deviceIdA)
        clockBefore.value = t0.addingTimeInterval(ttl - 1)   // 만료 1초 전(주입 clock은 claim 만료 판정용)
        // Coordinator.promote는 실제 시각(Date())으로 activeExpiry를 계산하므로, 승격 전후의 실제
        // 시각으로 30일 경계를 잡는다(주입 clock은 만료 경계 판정에만 쓰이고 승격 수명에는 무관).
        let realBefore = Date()
        let claimedA = await sessionBefore.claim(code: codeA)
        let realAfter = Date()
        XCTAssertNotNil(claimedA, "만료 1초 전 claim은 성공해야 한다")
        let promotedAFound = try await store.find(byTokenId: issuedA.tokenId)
        let promotedA = try XCTUnwrap(promotedAFound)
        let lower30d = realBefore.addingTimeInterval(30 * 86400 - 2).timeIntervalSince1970
        let upper30d = realAfter.addingTimeInterval(30 * 86400 + 2).timeIntervalSince1970
        XCTAssertTrue(promotedA.expiresAt.timeIntervalSince1970 >= lower30d &&
                      promotedA.expiresAt.timeIntervalSince1970 <= upper30d,
                      "만료 1초 전 claim은 30일 승격을 부여한다. actual=\(promotedA.expiresAt)")

        // (b) 만료 1초 후 claim → PairingSession.claim == nil이라 승격 트리거 미발생.
        let clockAfter = ClockBox(now: t0)
        let sessionAfter = PairingSession(ttl: ttl, now: { clockAfter.value })
        let coordinatorAfter = DevicePromotionCoordinator(store: store, lifecycle: lifecycle)
        await sessionAfter.setOnClaimed { deviceId in
            await coordinatorAfter.promote(deviceId: deviceId)
        }
        let issuedB = try DeviceTokenIssuer.issue()
        let payloadB = PairingPayload(pairingId: UUID().uuidString,
                                      deviceTokenSecret: issuedB.secretBase64url,
                                      wsEndpoint: "ws://127.0.0.1:1/", pushChannelHint: "m",
                                      expiresAt: t0.addingTimeInterval(ttl))
        let codeB = try await sessionAfter.issue(payload: payloadB, deviceId: UUID())
        clockAfter.value = t0.addingTimeInterval(ttl + 1)   // 만료 1초 후
        let claimedB = await sessionAfter.claim(code: codeB)
        XCTAssertNil(claimedB, "만료 1초 후 claim은 nil이라 승격이 트리거되지 않는다")
        let countAfter = await coordinatorAfter.promotedCount
        XCTAssertEqual(countAfter, 0, "만료된 코드 claim은 onClaimed를 발화하지 않는다")
    }

    // MARK: - 승격기 actor 카운터

    func testPromotionCoordinatorCounterIncrementsViaCallback() async throws {
        let store = InMemoryDeviceStore()
        let lifecycle = DeviceLifecyclePolicy(activeLifetime: 30 * 86400, expiringWithinDays: 7)
        let coordinator = DevicePromotionCoordinator(store: store, lifecycle: lifecycle)
        let session = PairingSession(ttl: 300)
        await session.setOnClaimed { deviceId in
            await coordinator.promote(deviceId: deviceId)
        }
        let issued = try DeviceTokenIssuer.issue()
        let deviceId = UUID()
        let device = Device(id: deviceId, name: "d", tokenId: issued.tokenId,
                            expiresAt: Date().addingTimeInterval(300))
        try await store.upsert(device, secret: issued.secret)
        let payload = PairingPayload(pairingId: UUID().uuidString,
                                     deviceTokenSecret: issued.secretBase64url,
                                     wsEndpoint: "ws://127.0.0.1:1/", pushChannelHint: "m",
                                     expiresAt: Date().addingTimeInterval(300))
        let code = try await session.issue(payload: payload, deviceId: deviceId)

        let before = await coordinator.promotedCount
        XCTAssertEqual(before, 0, "claim 전 카운터는 0이어야 한다")
        let claimed = await session.claim(code: code)
        XCTAssertNotNil(claimed, "claim은 성공해야 한다")
        let after = await coordinator.promotedCount
        XCTAssertGreaterThanOrEqual(after, 1, "onClaimed 콜백 경유 후 promotedCount >= 1")
    }

    // MARK: - 헬퍼

    private func makeDevice(expiresAt: Date) -> Device {
        Device(id: UUID(), name: "device", tokenId: UUID().uuidString, expiresAt: expiresAt)
    }
}
