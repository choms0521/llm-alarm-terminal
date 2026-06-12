import Foundation

/// 신뢰 디바이스 목록의 저장 추상. 정책·UI는 이 protocol에만 의존하고, 실 Keychain은
/// 한 conformer(P6a Day 3 KeychainDeviceStore)로 격리해 비밀이 디스크에 닿는 곳을
/// 1점으로 모은다. P5의 PushTransport ← MockPushTransport 선례와 동형이다.
///
/// secret은 Keychain으로만 운반되며 Device 모델에는 담지 않는다(tokenId만 식별자로 보유).
public protocol DeviceStore: Sendable {
    /// 등록된 모든 디바이스를 반환한다.
    func list() async throws -> [Device]
    /// 디바이스를 등록/갱신한다. secret은 Keychain으로만. 동일 deviceId 재페어링 시
    /// 옛 secret을 즉시 폐기(replace)한다 — 옛 tokenId로는 더 이상 검증되지 않는다.
    func upsert(_ device: Device, secret: Data) async throws
    /// tokenId로 Device를 조회한다(verifier가 revoked/expiresAt를 확인).
    func find(byTokenId tokenId: String) async throws -> Device?
    /// 검증 시 constant-time 대조에 쓸 secret을 조회한다.
    func secret(forTokenId tokenId: String) async throws -> Data?
    /// 디바이스를 폐기 표시한다(미배선 seam — P6b가 UI를 연결).
    func revoke(id: UUID) async throws
    /// 디바이스를 저장소에서 완전히 삭제한다. revoke와 달리 메타·secret을 모두 제거해
    /// 해당 tokenId로는 더 이상 secret/Device 조회가 되지 않으므로 Bearer가 즉시 무효화된다.
    /// 존재하지 않는 id는 no-op로 처리한다(이미 삭제된 상태와 멱등).
    func remove(id: UUID) async throws
}

/// 테스트·개발용 in-memory DeviceStore. 실 Keychain conformer는 P6a Day 3에서
/// 추가되며 이 actor를 대체하지 않고 병존한다(테스트는 계속 이 구현을 쓴다).
///
/// actor로 격리해 동시 upsert/verify 사이의 자료 경쟁을 차단한다. tokenId를 1차 키로
/// device와 secret을 보유하고, revoke(id:)가 UUID로 들어오므로 id→tokenId 역참조 맵을
/// 함께 유지한다.
public actor InMemoryDeviceStore: DeviceStore {
    private var devicesByTokenId: [String: Device] = [:]
    private var secretsByTokenId: [String: Data] = [:]
    private var tokenIdByDeviceId: [UUID: String] = [:]

    public init() {}

    public func list() async throws -> [Device] {
        Array(devicesByTokenId.values)
    }

    public func upsert(_ device: Device, secret: Data) async throws {
        // 동일 deviceId가 새 tokenId로 재페어링되면 옛 tokenId 엔트리(옛 secret 포함)를
        // 제거한다. 이로써 옛 secret은 즉시 폐기되고 옛 tokenId로는 검증이 실패한다.
        if let oldTokenId = tokenIdByDeviceId[device.id], oldTokenId != device.tokenId {
            devicesByTokenId.removeValue(forKey: oldTokenId)
            secretsByTokenId.removeValue(forKey: oldTokenId)
        }
        devicesByTokenId[device.tokenId] = device
        secretsByTokenId[device.tokenId] = secret
        tokenIdByDeviceId[device.id] = device.tokenId
    }

    public func find(byTokenId tokenId: String) async throws -> Device? {
        devicesByTokenId[tokenId]
    }

    public func secret(forTokenId tokenId: String) async throws -> Data? {
        secretsByTokenId[tokenId]
    }

    public func revoke(id: UUID) async throws {
        guard let tokenId = tokenIdByDeviceId[id],
              let device = devicesByTokenId[tokenId] else {
            return
        }
        // revoked 플래그만 토글한 새 Device로 교체한다(immutable — 기존 객체 변형 금지).
        devicesByTokenId[tokenId] = Device(
            id: device.id,
            name: device.name,
            tokenId: device.tokenId,
            fcmToken: device.fcmToken,
            apnsToken: device.apnsToken,
            expiresAt: device.expiresAt,
            revoked: true
        )
    }

    public func remove(id: UUID) async throws {
        // id→tokenId 역참조로 세 맵에서 모두 제거한다. 없으면 멱등 no-op.
        guard let tokenId = tokenIdByDeviceId.removeValue(forKey: id) else {
            return
        }
        devicesByTokenId.removeValue(forKey: tokenId)
        secretsByTokenId.removeValue(forKey: tokenId)
    }
}
