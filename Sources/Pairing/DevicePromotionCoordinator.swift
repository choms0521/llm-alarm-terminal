import Foundation

/// 데몬 레이어 전용 승격기. claim 성공 콜백(onClaimed)이 발화하는 deviceId를 받아 pending
/// 디바이스를 active로 승격한다(D-3). revoke의 DeviceRevocationCoordinator(P6b Day 2)와 대칭이며,
/// 핵심 동작도 store.promote(id:to:) ↔ store.revoke(id:)로 모두 store 레이어 원자 메서드라
/// 대칭이 완성된다.
///
/// actor로 격리해 promotedCount를 어서션 가능한 상태로 둔다. @Sendable onClaimed 콜백이 actor를
/// 캡처해 await로 변경하므로, struct였다면 mutating이 복사본에 갇혀 카운터를 검증할 수 없다.
/// UI(@MainActor PairingModel)는 이 Coordinator를 경유하지 않는다 — claim 소비는 데몬측에서만
/// 일어나고, UI는 refreshDevices() polling으로 승격 결과를 따라온다(§5.2).
public actor DevicePromotionCoordinator {
    private let store: any DeviceStore
    private let lifecycle: DeviceLifecyclePolicy

    /// 승격 시도 호출 카운터(테스트 어서션 가능). 실제 갱신 여부는 store의 revoked no-op
    /// 정책이 판정하므로, 이 카운터는 "promote가 트리거된 횟수"를 의미한다.
    public private(set) var promotedCount = 0

    /// store.promote가 throw한 실패 횟수(테스트/운영 관측용). 실패를 조용히 삼키면 claim은
    /// 성공했는데 승격이 누락되어 정상 디바이스가 pending(5분) 만료로 거부되는 상태가
    /// 침묵하므로, 카운터와 마지막 실패 설명으로 표면화한다.
    public private(set) var promotionFailureCount = 0
    /// 마지막 승격 실패의 에러 타입명. secret·실 IP를 포함하지 않는다(타입명만 기록).
    public private(set) var lastPromotionFailure: String?

    public init(store: any DeviceStore, lifecycle: DeviceLifecyclePolicy = DeviceLifecyclePolicy()) {
        self.store = store
        self.lifecycle = lifecycle
    }

    /// pending → active 승격: store 원자 메서드 1줄 위임. deviceId는 PairingSession이 보유한
    /// (code → deviceId) 매핑이 onClaimed로 넘긴다(payload에서 도출 불가). revoked면 store가
    /// no-op이라 폐기 디바이스가 30일 active로 부활하지 않는다(read-check-write가 store actor
    /// 메서드 안에 묶여 revoke와 직렬화).
    public func promote(deviceId: UUID) async {
        promotedCount += 1
        do {
            try await store.promote(id: deviceId, to: lifecycle.activeExpiry(now: Date()))
        } catch {
            promotionFailureCount += 1
            lastPromotionFailure = String(describing: type(of: error))
        }
    }
}
