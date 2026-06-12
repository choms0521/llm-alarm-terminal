import XCTest
import Foundation

/// P6a Day 2 — WSAuthGate carry-over 상태 저장소의 순수 단위 테스트.
///
/// 소켓 없는 단위 수준에서 nonce 등록/소비/replay/만료/구조분해를 측정한다. WS 통합
/// 거동(핸드셰이크 reject, 게이트 ② close, identity 비교차)은 WSAuthGateIntegrationTests가 다룬다.
final class WSAuthGateTests: XCTestCase {

    private func secret(_ bytes: [UInt8]) -> Data { Data(bytes) }

    // MARK: - registerPending / consumePending (carry-over)

    func testRegisterThenConsumeReturnsCarriedPair() async {
        let gate = WSAuthGate()
        let nonce = "nonce-a"
        await gate.registerPending(nonce: nonce, tokenId: "tok-1", secret: secret([1, 2, 3]), at: Date())

        let claimed = await gate.consumePending(nonce: nonce, within: 10)
        XCTAssertEqual(claimed?.tokenId, "tok-1")
        XCTAssertEqual(claimed?.secret, secret([1, 2, 3]))
    }

    // replay: 동일 nonce는 1회만 소비 가능. 두 번째 consume은 항목이 없어 nil.
    func testConsumeIsOneShot_replayRejected() async {
        let gate = WSAuthGate()
        let nonce = "nonce-replay"
        await gate.registerPending(nonce: nonce, tokenId: "tok-1", secret: secret([9]), at: Date())

        let first = await gate.consumePending(nonce: nonce, within: 10)
        XCTAssertNotNil(first, "첫 consume은 carry 항목을 반환해야 한다")
        let second = await gate.consumePending(nonce: nonce, within: 10)
        XCTAssertNil(second, "같은 nonce 재사용은 소비할 항목이 없어 nil이어야 한다(replay 방지)")
    }

    func testConsumeUnknownNonceReturnsNil() async {
        let gate = WSAuthGate()
        let claimed = await gate.consumePending(nonce: "never-registered", within: 10)
        XCTAssertNil(claimed)
    }

    // 시간창 초과 항목은 소비되지 않고 nil(만료 폐기).
    func testConsumeExpiredEntryReturnsNil() async {
        let gate = WSAuthGate()
        let nonce = "nonce-expired"
        let past = Date().addingTimeInterval(-20)   // 20초 전 등록 — within=10 초과
        await gate.registerPending(nonce: nonce, tokenId: "tok-1", secret: secret([7]), at: past)

        let claimed = await gate.consumePending(nonce: nonce, within: 10)
        XCTAssertNil(claimed, "시간창 만료 항목은 소비되지 않아야 한다")
    }

    // MARK: - 중복 nonce (핸드셰이크 reject 트리거)

    func testHandshakeRegisterRejectsDuplicateNonce() async {
        let gate = WSAuthGate()
        let nonce = "dup-nonce"
        let first = gate.handshakeRegister(nonce: nonce, tokenId: "tok-1", secret: secret([1]))
        let second = gate.handshakeRegister(nonce: nonce, tokenId: "tok-2", secret: secret([2]))
        XCTAssertTrue(first, "첫 등록은 성공해야 한다")
        XCTAssertFalse(second, "중복 nonce 등록은 거부(false)되어야 한다")
        XCTAssertTrue(gate.isNonceRegistered(nonce))
    }

    // MARK: - structurallySplit (Bearer 구조 분해)

    func testStructurallySplitValidBearer() {
        let gate = WSAuthGate()
        // secret base64url("ABCD" 4바이트) = "QUJDRA" (padding 제거)
        let secretBytes = Data([0x41, 0x42, 0x43, 0x44])
        let bearer = "tok-id-1.\(Base64URL.encode(secretBytes))"
        let split = gate.structurallySplit(bearer)
        XCTAssertEqual(split?.tokenId, "tok-id-1")
        XCTAssertEqual(split?.secret, secretBytes)
    }

    func testStructurallySplitRejectsMalformed() {
        let gate = WSAuthGate()
        XCTAssertNil(gate.structurallySplit(nil), "nil은 거부")
        XCTAssertNil(gate.structurallySplit("no-dot-separator"), "구분자 없으면 거부")
        XCTAssertNil(gate.structurallySplit(".onlysecret"), "빈 tokenId 거부")
        XCTAssertNil(gate.structurallySplit("onlytoken."), "빈 secret 거부")
        XCTAssertNil(gate.structurallySplit("tok.@@@invalid@@@"), "base64url 위반 secret 거부")
    }

    // MARK: - nonce 생성/형식

    func testMakeNonceProducesValid16ByteBase64url() {
        let nonce = WSAuthGate.makeNonce()
        XCTAssertNotNil(nonce)
        XCTAssertTrue(WSAuthGate.isValidNonce(nonce), "생성된 nonce는 형식 검증을 통과해야 한다")
        let decoded = nonce.flatMap { Base64URL.decode($0) }
        XCTAssertEqual(decoded?.count, 16, "nonce는 16바이트로 디코드돼야 한다")
    }

    func testMakeNonceIsUniquePerCall() {
        let a = WSAuthGate.makeNonce()
        let b = WSAuthGate.makeNonce()
        XCTAssertNotNil(a); XCTAssertNotNil(b)
        XCTAssertNotEqual(a, b, "연결마다 신규 nonce — 두 호출이 같으면 안 된다")
    }

    func testIsValidNonceRejectsBadFormat() {
        XCTAssertFalse(WSAuthGate.isValidNonce(nil))
        XCTAssertFalse(WSAuthGate.isValidNonce(""))
        XCTAssertFalse(WSAuthGate.isValidNonce(Base64URL.encode(Data([1, 2, 3]))), "3바이트는 16바이트가 아니라 거부")
        XCTAssertFalse(WSAuthGate.isValidNonce("@@@not-base64url@@@"))
    }
}
