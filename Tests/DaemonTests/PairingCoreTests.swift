import XCTest
import Foundation

/// P6a Day 1 페어링 코어 단위 테스트. Keychain·UI·WS 배선을 제외한 순수 로직
/// (코덱 라운드트립, constant-time 검증, 만료 경계, 6자리 코드 형식, DeviceStore CRUD,
/// rate-limit)을 측정한다. Day 1 카드 종료 조건 6항목과 1:1 대응한다.
final class PairingCoreTests: XCTestCase {

    // MARK: - 종료 조건 ② PairingCodec 라운드트립 (한국어/emoji/4KB 경계)

    private func makePayload(secret: String, hint: String) -> PairingPayload {
        // ISO8601 라운드트립 안정성을 위해 소수점 이하를 버린 정수초 Date를 쓴다.
        let whole = Date(timeIntervalSince1970: 1_749_600_000)
        return PairingPayload(
            pairingId: "pairing-\(hint)",
            deviceTokenSecret: secret,
            wsEndpoint: "ws://127.0.0.1:55123/",
            pushChannelHint: hint,
            expiresAt: whole
        )
    }

    func testCodecRoundtripKorean() throws {
        let payload = makePayload(secret: "ko-secret-한국어값", hint: "한국어채널-가나다")
        let url = try PairingCodec.encodeURL(payload)
        let decoded = try PairingCodec.decodeURL(url)
        XCTAssertEqual(decoded, payload)
    }

    func testCodecRoundtripEmoji() throws {
        let payload = makePayload(secret: "emoji-🔐🚀✅", hint: "channel-😀🎉")
        let url = try PairingCodec.encodeURL(payload)
        let decoded = try PairingCodec.decodeURL(url)
        XCTAssertEqual(decoded, payload)
    }

    func testCodecRoundtrip4KBBoundary() throws {
        // 4KB 경계 payload: hint를 길게 채워 직렬화 본문이 4KB를 넘도록 한다.
        let largeHint = String(repeating: "안녕A", count: 1400)   // 약 5.6KB UTF-8
        let payload = makePayload(secret: "boundary-secret", hint: largeHint)
        let url = try PairingCodec.encodeURL(payload)
        let decoded = try PairingCodec.decodeURL(url)
        XCTAssertEqual(decoded, payload)
    }

    func testCodecURLBytesAreStableAcrossEncodes() throws {
        // 동일 payload는 항상 동일 URL 바이트로 인코딩된다(sortedKeys 안정성).
        let payload = makePayload(secret: "stable-secret", hint: "stable")
        let first = try PairingCodec.encodeURL(payload)
        let second = try PairingCodec.encodeURL(payload)
        XCTAssertEqual(first, second)
    }

    // MARK: - 종료 조건 ③ DeviceTokenVerifier constant-time

    func testVerifierConstantTimeEqualMatch() {
        let a = Data([1, 2, 3, 4, 5, 6])
        let b = Data([1, 2, 3, 4, 5, 6])
        XCTAssertTrue(DeviceTokenVerifier.constantTimeEqual(a, b))
    }

    func testVerifierConstantTimeEqualMismatchSameLength() {
        let a = Data([1, 2, 3, 4, 5, 6])
        let b = Data([1, 2, 3, 4, 5, 9])   // 마지막 바이트만 다름
        XCTAssertFalse(DeviceTokenVerifier.constantTimeEqual(a, b))
    }

    func testVerifierConstantTimeEqualLengthMismatch() {
        let a = Data([1, 2, 3])
        let b = Data([1, 2, 3, 4])
        XCTAssertFalse(DeviceTokenVerifier.constantTimeEqual(a, b))
    }

    func testVerifierVerifiesIssuedToken() async throws {
        // Issuer가 발급한 secret이 store에 등록되면 verify가 그 디바이스를 승격한다.
        let issued = try DeviceTokenIssuer.issue()
        let store = InMemoryDeviceStore()
        let device = Device(
            id: UUID(),
            name: "device-A",
            tokenId: issued.tokenId,
            expiresAt: Date().addingTimeInterval(3600)
        )
        try await store.upsert(device, secret: issued.secret)

        let verifier = DeviceTokenVerifier(store: store)
        let verified = await verifier.verify(tokenId: issued.tokenId, presentedSecret: issued.secret)
        XCTAssertEqual(verified?.deviceId, device.id)
        XCTAssertEqual(verified?.tokenId, issued.tokenId)
    }

    func testVerifierRejectsWrongSecret() async throws {
        let issued = try DeviceTokenIssuer.issue()
        let store = InMemoryDeviceStore()
        let device = Device(id: UUID(), name: "device-A", tokenId: issued.tokenId,
                            expiresAt: Date().addingTimeInterval(3600))
        try await store.upsert(device, secret: issued.secret)

        let verifier = DeviceTokenVerifier(store: store)
        let wrong = Data(repeating: 0xAB, count: 32)
        let verified = await verifier.verify(tokenId: issued.tokenId, presentedSecret: wrong)
        XCTAssertNil(verified)
    }

    func testVerifierRejectsRevokedAndExpired() async throws {
        let store = InMemoryDeviceStore()
        let secret = Data(repeating: 0x11, count: 32)

        let revoked = Device(id: UUID(), name: "rev", tokenId: "tok-rev",
                             expiresAt: Date().addingTimeInterval(3600), revoked: true)
        try await store.upsert(revoked, secret: secret)

        let expired = Device(id: UUID(), name: "exp", tokenId: "tok-exp",
                             expiresAt: Date().addingTimeInterval(-1))
        try await store.upsert(expired, secret: secret)

        let verifier = DeviceTokenVerifier(store: store)
        let revVerified = await verifier.verify(tokenId: "tok-rev", presentedSecret: secret)
        let expVerified = await verifier.verify(tokenId: "tok-exp", presentedSecret: secret)
        XCTAssertNil(revVerified)
        XCTAssertNil(expVerified)
    }

    // MARK: - 종료 조건 ④ PairingSession 만료 경계 (시간 주입)

    func testPairingSessionExpiryBoundary() async throws {
        // 시간 주입: 발급 시점 t0, ttl 300초. claim을 만료 1초 전/후 시점으로 주입해 측정한다.
        let t0 = Date(timeIntervalSince1970: 1_749_600_000)
        let clockBox = ClockBox(now: t0)
        let session = PairingSession(ttl: 300, maxClaimAttempts: 5, now: { clockBox.value })
        let payload = makePayload(secret: "expiry-secret", hint: "expiry")

        let code = try await session.issue(payload: payload)

        // 만료 1초 전(t0 + 299s): claim 성공.
        clockBox.value = t0.addingTimeInterval(299)
        let beforeResult = await session.claim(code: code)
        XCTAssertEqual(beforeResult, payload)

        // 같은 payload를 새로 발급해 만료 후 케이스를 측정한다(직전 코드는 소비됨).
        clockBox.value = t0
        let code2 = try await session.issue(payload: payload)
        // 만료 1초 후(t0 + 301s): claim 실패.
        clockBox.value = t0.addingTimeInterval(301)
        let afterResult = await session.claim(code: code2)
        XCTAssertNil(afterResult)
        let lastCode = await session.lastRejectCode
        XCTAssertEqual(lastCode, PairingSession.RejectCode.expired.rawValue)
    }

    // MARK: - 종료 조건 ⑤ SixDigitCode 형식 (10,000회)

    func testSixDigitCodeFormatTenThousand() throws {
        let pattern = try NSRegularExpression(pattern: "^[0-9]{6}$")
        var violations = 0
        for _ in 0..<10_000 {
            let code = try SixDigitCode.generate()
            let range = NSRange(code.startIndex..<code.endIndex, in: code)
            if pattern.firstMatch(in: code, range: range) == nil {
                violations += 1
            }
        }
        XCTAssertEqual(violations, 0)
    }

    // MARK: - InMemoryDeviceStore CRUD + upsert replace

    func testDeviceStoreCRUD() async throws {
        let store = InMemoryDeviceStore()
        let secret = Data(repeating: 0x22, count: 32)
        let device = Device(id: UUID(), name: "crud", tokenId: "tok-crud",
                            expiresAt: Date().addingTimeInterval(3600))
        try await store.upsert(device, secret: secret)

        let listed = try await store.list()
        XCTAssertEqual(listed.count, 1)
        let found = try await store.find(byTokenId: "tok-crud")
        XCTAssertEqual(found, device)
        let storedSecret = try await store.secret(forTokenId: "tok-crud")
        XCTAssertEqual(storedSecret, secret)

        try await store.revoke(id: device.id)
        let afterRevoke = try await store.find(byTokenId: "tok-crud")
        XCTAssertEqual(afterRevoke?.revoked, true)
    }

    func testDeviceStoreUpsertReplacesOldSecret() async throws {
        // 동일 deviceId 재페어링: 옛 tokenId의 secret으로는 더 이상 조회/검증되지 않는다.
        let store = InMemoryDeviceStore()
        let deviceId = UUID()
        let oldSecret = Data(repeating: 0x33, count: 32)
        let newSecret = Data(repeating: 0x44, count: 32)

        let old = Device(id: deviceId, name: "dev", tokenId: "tok-old",
                         expiresAt: Date().addingTimeInterval(3600))
        try await store.upsert(old, secret: oldSecret)

        let new = Device(id: deviceId, name: "dev", tokenId: "tok-new",
                         expiresAt: Date().addingTimeInterval(3600))
        try await store.upsert(new, secret: newSecret)

        // 옛 tokenId 엔트리는 제거되어 secret/Device 조회가 nil.
        let oldSecretLookup = try await store.secret(forTokenId: "tok-old")
        let oldDeviceLookup = try await store.find(byTokenId: "tok-old")
        XCTAssertNil(oldSecretLookup)
        XCTAssertNil(oldDeviceLookup)

        // verify도 옛 secret으로는 실패한다.
        let verifier = DeviceTokenVerifier(store: store)
        let oldVerify = await verifier.verify(tokenId: "tok-old", presentedSecret: oldSecret)
        XCTAssertNil(oldVerify)

        // 새 tokenId/secret으로는 검증 성공.
        let newVerify = await verifier.verify(tokenId: "tok-new", presentedSecret: newSecret)
        XCTAssertEqual(newVerify?.deviceId, deviceId)
        // list에는 deviceId당 1건만 남는다.
        let listed = try await store.list()
        XCTAssertEqual(listed.count, 1)
    }

    // MARK: - rate-limit (5회 오claim 후 6회째 거부)

    func testPairingSessionRateLimit() async throws {
        let session = PairingSession(ttl: 300, maxClaimAttempts: 5, now: { Date() })
        let payload = makePayload(secret: "rl-secret", hint: "rl")
        _ = try await session.issue(payload: payload)

        // 1~4회 오claim: 코드는 살아 있고 사유는 INVALID.
        for _ in 0..<4 {
            let result = await session.claim(code: "000000")
            XCTAssertNil(result)
        }
        let aliveAfter4 = await session.hasActiveCode()
        XCTAssertTrue(aliveAfter4)
        let codeAfter4 = await session.lastRejectCode
        XCTAssertEqual(codeAfter4, PairingSession.RejectCode.invalid.rawValue)

        // 5회째 오claim: 한도 도달 → 코드 폐기 + RATE_LIMITED.
        let fifth = await session.claim(code: "000000")
        XCTAssertNil(fifth)
        let aliveAfter5 = await session.hasActiveCode()
        XCTAssertFalse(aliveAfter5)
        let codeAfter5 = await session.lastRejectCode
        XCTAssertEqual(codeAfter5, PairingSession.RejectCode.rateLimited.rawValue)

        // 6회째 claim: 활성 코드 없음 → INVALID 거부.
        let sixth = await session.claim(code: "000000")
        XCTAssertNil(sixth)
        let codeAfter6 = await session.lastRejectCode
        XCTAssertEqual(codeAfter6, PairingSession.RejectCode.invalid.rawValue)
    }

    func testPairingSessionClaimConsumesCodeOnce() async throws {
        // 성공 claim은 코드를 1회 소비한다 — 두 번째 claim은 INVALID(replay 방지).
        let session = PairingSession(ttl: 300, maxClaimAttempts: 5, now: { Date() })
        let payload = makePayload(secret: "consume-secret", hint: "consume")
        let code = try await session.issue(payload: payload)

        let first = await session.claim(code: code)
        XCTAssertEqual(first, payload)
        let second = await session.claim(code: code)
        XCTAssertNil(second)
        let lastCode = await session.lastRejectCode
        XCTAssertEqual(lastCode, PairingSession.RejectCode.invalid.rawValue)
    }

    func testDeviceTokenIssuerBearerFormat() throws {
        // Bearer 형식이 `<tokenId>.<secretBase64url>`이고 secret이 32바이트인지 측정.
        let issued = try DeviceTokenIssuer.issue(tokenId: "fixed-token-id")
        XCTAssertEqual(issued.secret.count, 32)
        XCTAssertEqual(issued.bearer, "fixed-token-id.\(issued.secretBase64url)")

        // base64url 라운드트립: 인코딩 문자열을 디코딩하면 raw secret과 byte-identical.
        let decoded = Base64URL.decode(issued.secretBase64url)
        XCTAssertEqual(decoded, issued.secret)
    }
}

/// 시간 주입용 가변 박스. actor 외부에서 클로저로 현재 시각을 읽게 한다.
/// (테스트 단일 스레드 시나리오 전용 — 동시성 경합 없음.)
final class ClockBox: @unchecked Sendable {
    var value: Date
    init(now: Date) { self.value = now }
}
