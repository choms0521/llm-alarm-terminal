import Foundation

/// push 거부 통지 seam(§5.4 Coordinator ③ / §5.6). revoke된 디바이스를 push 발신 대상에서
/// 제외하는 필터로 쓰인다. 발신 호출자 자체는 D-7로 dead이나, "revoked는 발신 제외"라는 정책과
/// 그 단위 검증은 P6b에 둔다 — DeviceRevocationCoordinator.revoke의 ③단계가 markRevoked로
/// 통지하고, 미래 push 발신 경로(PushSender.sendIfNotRevoked)가 isRevoked로 조회한다.
public protocol PushRevocationSink: Sendable {
    /// 디바이스를 push 발신 제외 대상으로 표시한다(Coordinator ③ — non-throwing seam).
    func markRevoked(deviceId: UUID) async
    /// 디바이스가 push 발신 제외 대상인지 조회한다(발신 필터가 transport 호출 전 확인).
    func isRevoked(deviceId: UUID) async -> Bool
}

/// in-memory PushRevocationSink. 표시된 deviceId 집합을 actor로 격리해 동시 markRevoked/isRevoked
/// 사이의 자료 경쟁을 차단한다. P10a 실 push 인프라 전까지의 기본 구현이며, 테스트는 이 구현으로
/// "revoke 후 isRevoked == true" + "발신 필터 제외"를 결정론적으로 검증한다.
public actor InMemoryPushRevocationSink: PushRevocationSink {
    private var revoked: Set<UUID> = []

    public init() {}

    public func markRevoked(deviceId: UUID) async {
        revoked.insert(deviceId)
    }

    public func isRevoked(deviceId: UUID) async -> Bool {
        revoked.contains(deviceId)
    }
}
