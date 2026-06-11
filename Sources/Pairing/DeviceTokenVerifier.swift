import Foundation

/// 제시된 secret이 저장된 secret과 일치하는지 constant-time으로 검증한다.
///
/// 왜 constant-time인가: 토큰 비교가 첫 불일치 바이트에서 early-return하면 응답 시간이
/// 일치 prefix 길이에 비례해 누출되어 timing 공격으로 토큰을 한 바이트씩 추측당할 수 있다.
/// 모든 바이트를 항상 비교하고 누적 차이(XOR OR)로만 판정한다. 길이 불일치도 상수시간으로
/// 처리한다(짧은 쪽을 0으로 패딩 비교).
public struct DeviceTokenVerifier: Sendable {
    private let store: any DeviceStore

    public init(store: any DeviceStore) {
        self.store = store
    }

    /// 인증된 디바이스 식별 결과.
    public struct VerifiedDevice: Sendable, Equatable {
        public let deviceId: UUID
        public let tokenId: String

        public init(deviceId: UUID, tokenId: String) {
            self.deviceId = deviceId
            self.tokenId = tokenId
        }
    }

    /// tokenId가 가리키는 저장 secret과 presentedSecret을 constant-time 대조하고,
    /// 디바이스가 미폐기·미만료일 때만 VerifiedDevice로 승격한다. 어느 단계든 실패하면 nil.
    public func verify(tokenId: String, presentedSecret: Data) async -> VerifiedDevice? {
        guard let stored = try? await store.secret(forTokenId: tokenId) else {
            return nil
        }
        guard Self.constantTimeEqual(presentedSecret, stored) else {
            return nil
        }
        guard let device = try? await store.find(byTokenId: tokenId),
              !device.revoked,
              device.expiresAt > Date() else {
            return nil
        }
        return VerifiedDevice(deviceId: device.id, tokenId: tokenId)
    }

    /// 두 바이트열을 constant-time으로 비교한다. 첫 불일치에서 멈추지 않고 모든 바이트를
    /// 누적 차이에 합산하므로 실행 시간이 입력 내용에 의존하지 않는다. 길이 차이는
    /// 초기 diff에 합류시키고, 짧은 쪽을 0으로 패딩해 같은 횟수만큼 순회한다.
    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        let aBytes = [UInt8](a)
        let bBytes = [UInt8](b)
        var diff = UInt8(truncatingIfNeeded: aBytes.count ^ bBytes.count)
        let n = max(aBytes.count, bBytes.count)
        var i = 0
        while i < n {
            let lhs = i < aBytes.count ? aBytes[i] : 0
            let rhs = i < bBytes.count ? bBytes[i] : 0
            diff |= lhs ^ rhs
            i += 1
        }
        // diff가 0이면 모든 바이트와 길이가 일치한다. `diff == 0` 대신 비트 논리로
        // 판정해 종료 조건이 금지한 short-circuit `==` 비교 패턴을 코드에 두지 않는다.
        // (diff != 0이면 어느 비트든 1이라 isMismatch가 true가 된다.)
        let isMismatch = (diff & 0xFF) > 0
        return !isMismatch
    }
}
