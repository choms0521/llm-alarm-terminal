import Foundation

/// revoke의 단일 진입점(§5.4). store 무효화 + 살아있는 연결 끊기 + push 거부 통지(seam)를
/// 순서가 보장된 다단계로 조율한다. UI 폐기 버튼, CLI --lifecycle, "Device lost"가 모두 이 1점으로
/// 수렴해 세 부수효과가 항상 같은 순서로 일어난다(부분 폐기로 인한 잔존 방지).
///
/// 원자 아님 — 순서가 보장된 다단계: 이 Coordinator는 3개 독립 await를 순차 실행하는 것이지 원자
/// 트랜잭션이 아니다(Swift actor await 사이에 다른 작업이 끼어들 수 있다). 그럼에도 안전한 이유는
/// store.revoke 선행 때문이다 — ① 이후 단계가 진행되는 사이 구간에 그 Bearer로 재연결이 시도돼도,
/// P6a DeviceTokenVerifier.verify의 !revoked 거부가 게이트 ②에서 막는다. 즉 ②(기존 연결 끊기)가
/// 완료되기 전이라도 새 연결은 절대 승격되지 않는다. ②는 "이미 떠 있던 연결"만 처리하면 되고,
/// 그 사이의 신규 연결은 ①이 닫는다.
///
/// actor로 둔다 — DevicePromotionCoordinator(승격기)와 대칭이다. 상태(연결 끊김 수)는 단일 출처인
/// WSServer.disconnectedCount(actor 격리, §5.3)가 보유하므로 폐기기에 중복 카운터를 두지 않는다.
/// 두 Coordinator의 핵심 동작(store.promote / store.revoke)이 모두 store 레이어 원자 메서드라는
/// 점에서 대칭이 완성된다.
public actor DeviceRevocationCoordinator {
    private let store: any DeviceStore
    private let server: WSServer
    /// push 거부 통지 seam(③). revoked 디바이스를 push 발신 대상에서 제외하는 필터로 쓰인다
    /// (D-7로 발신 호출자 자체는 dead — 통지만 한다).
    private let pushRevocation: any PushRevocationSink

    public init(store: any DeviceStore, server: WSServer, pushRevocation: any PushRevocationSink) {
        self.store = store
        self.server = server
        self.pushRevocation = pushRevocation
    }

    /// 폐기 절차: ① store에서 revoked 표시 → ② 살아있는 WS 연결 즉시 끊기 → ③ push 발신 제외 통지.
    ///
    /// 부분 실패 정책: throw 가능 지점은 ① store.revoke뿐이다. ①이 throw하면 ②③에 진입하지 않는다
    /// (무효화 자체가 실패했으면 끊기·push 제외는 의미 없음 — 호출자가 재시도). ②③은 non-throwing이라
    /// ①이 성공한 뒤에는 항상 끝까지 진행된다.
    ///
    /// 순서가 중요: ① 선행이 사이 구간 재연결도 거부되게 한다(verifier !revoked가 게이트 ②에서 막음).
    /// ②가 완료되기 전 떠 있던 신규 연결도 ①이 이미 닫는 효과를 낸다.
    public func revoke(deviceId: UUID) async throws {
        try await store.revoke(id: deviceId)               // ① 무효화(throw 가능 — 실패 시 ②③ 미진입). 재연결도 거부
        await server.disconnectDevice(deviceId: deviceId)  // ② 살아있는 연결 전부 cancel(non-throwing, disconnectedCount 증가)
        await pushRevocation.markRevoked(deviceId: deviceId) // ③ push 발신 제외(non-throwing seam)
    }
}
