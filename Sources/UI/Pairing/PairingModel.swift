import Foundation
import Combine

/// 페어링 화면의 상태를 보유하는 @MainActor ObservableObject. PairingSession에 코드를
/// 발급시키고, QR용 payload URL 문자열과 6자리 코드, 만료 카운트다운, 등록 디바이스 목록을
/// 뷰에 노출한다.
///
/// secret(payload.deviceTokenSecret)은 QR/코드 채널로만 운반된다. 이 모델은 secret 평문을
/// @Published로 노출하지 않으며, QR payload URL과 6자리 코드만 뷰에 전달한다. payload는
/// 발급 시점에만 보유하고 QR/코드 표면으로만 흐른다.
@MainActor
public final class PairingModel: ObservableObject {
    /// QR에 실을 payload URL 문자열(claudealarm://pair?d=<base64url>). 코드 발급 전엔 nil.
    @Published public private(set) var qrPayloadURL: String?
    /// 화면에 표시할 6자리 페어링 코드. 발급 전엔 nil.
    @Published public private(set) var sixDigitCode: String?
    /// 만료까지 남은 초(0 이상). 발급 전이거나 만료 시 0.
    @Published public private(set) var secondsRemaining: Int = 0
    /// 등록된 디바이스 목록(read-only). 발급/새로고침 시 갱신.
    @Published public private(set) var devices: [Device] = []
    /// 발급/조회 중 발생한 사용자 표시용 오류 메시지(한국어). 정상 시 nil.
    @Published public private(set) var errorMessage: String?

    /// Tailscale 진단 결과(설정 진입 시 1회 + 수동 새로고침). nil이면 아직 진단 전이다.
    @Published public private(set) var tailscaleResult: TailscaleDiagnostics.Result?

    private let session: PairingSession
    private let store: any DeviceStore
    private let lifecycle: DeviceLifecyclePolicy
    private let wsEndpoint: String
    private let pushChannelHint: String
    /// revoke 단일 진입점(§5.4). nil이면 데몬 미부트스트랩 상태 — revokeDevice가 한국어
    /// 안내 메시지("데몬이 준비되지 않아...")로 실패한다. AppDelegate가 데몬 핸들을 얻은 뒤 주입한다.
    private let revocationCoordinator: DeviceRevocationCoordinator?
    /// Tailscale 사전 진단(§5.5, ADR-F). nil이면 refreshTailscale이 no-op이라
    /// tailscaleResult가 nil로 남고, 진단 카드는 진단 전 상태에 머문다.
    private let tailscaleDiagnostics: TailscaleDiagnostics?
    /// 만료 카운트다운 기준 시각. 발급 시 갱신.
    private var expiresAt: Date?
    private var timerCancellable: AnyCancellable?

    /// PairingSession/DeviceStore/엔드포인트를 주입한다. wsEndpoint는 데몬 port로 구성한
    /// ws://127.0.0.1:<port>/ 문자열이다. revocationCoordinator/tailscaleDiagnostics는
    /// 데몬 부트스트랩 후 AppDelegate가 주입한다(미주입 시 폐기는 안내 메시지로 실패하고
    /// 진단 새로고침은 no-op).
    public init(
        session: PairingSession,
        store: any DeviceStore,
        wsEndpoint: String,
        pushChannelHint: String = "mock-channel",
        lifecycle: DeviceLifecyclePolicy = DeviceLifecyclePolicy(),
        revocationCoordinator: DeviceRevocationCoordinator? = nil,
        tailscaleDiagnostics: TailscaleDiagnostics? = nil
    ) {
        self.session = session
        self.store = store
        self.lifecycle = lifecycle
        self.wsEndpoint = wsEndpoint
        self.pushChannelHint = pushChannelHint
        self.revocationCoordinator = revocationCoordinator
        self.tailscaleDiagnostics = tailscaleDiagnostics
    }

    /// 새 페어링 코드를 발급한다. 새 토큰 secret을 만들어 DeviceStore에 등록하고, 같은
    /// payload를 QR/6자리 코드 두 채널로 노출한다. 발급 결과로 카운트다운 타이머를 시작한다.
    public func issueNewCode() async {
        do {
            let issued = try DeviceTokenIssuer.issue()
            let now = Date()
            // 부채 해소(D-3): 발급 즉시 30일 부여하던 부채를 pending(코드 ttl=5분 수명)로 교체한다.
            // 30일 active 수명은 claim 성공 시 데몬 레이어(DevicePromotionCoordinator)의 승격만이
            // 부여한다 — claim 안 된 코드는 5분 후 verifier가 자연 거부해 누적되지 않는다.
            let codeExpiry = lifecycle.pendingExpiry(codeTTL: session.ttl, now: now)
            let pairingId = UUID().uuidString
            let deviceId = UUID()
            let device = Device(
                id: deviceId,
                name: "페어링 대기 디바이스",
                tokenId: issued.tokenId,
                expiresAt: codeExpiry
            )
            try await store.upsert(device, secret: issued.secret)

            let payload = PairingPayload(
                pairingId: pairingId,
                deviceTokenSecret: issued.secretBase64url,
                wsEndpoint: wsEndpoint,
                pushChannelHint: pushChannelHint,
                expiresAt: codeExpiry
            )
            // deviceId를 함께 전달해 PairingSession이 (code → deviceId)를 보유하게 한다. claim
            // 성공 시 데몬 레이어가 onClaimed로 이 deviceId를 받아 active로 승격한다(§5.2).
            let code = try await session.issue(payload: payload, deviceId: deviceId)
            let url = try PairingCodec.encodeURL(payload)

            self.sixDigitCode = code
            self.qrPayloadURL = url.absoluteString
            self.expiresAt = codeExpiry
            self.errorMessage = nil
            startCountdown(until: codeExpiry)
            await refreshDevices()
        } catch {
            self.errorMessage = "페어링 코드 발급에 실패했습니다."
        }
    }

    /// 디바이스를 저장소에서 삭제하고 목록을 다시 읽는다. 삭제되면 해당 tokenId의 secret이
    /// 사라져 그 Bearer는 즉시 WS 인증에 실패한다.
    public func removeDevice(id: UUID) async {
        do {
            try await store.remove(id: id)
            self.errorMessage = nil
            await refreshDevices()
        } catch {
            self.errorMessage = "디바이스 삭제에 실패했습니다."
        }
    }

    /// 디바이스를 폐기(revoke)한다. remove와 달리 항목을 삭제하지 않고 revoked 표시만 남겨
    /// "폐기됨" 상태로 목록에 존속시킨다. DeviceRevocationCoordinator를 경유해 토큰 무효화 +
    /// 살아있는 WS 연결 즉시 끊기 + push 발신 제외를 순서대로 수행한다(§5.4). 데몬 미부트스트랩
    /// 상태(coordinator nil)면 안내 메시지만 남긴다.
    public func revokeDevice(id: UUID) async {
        guard let coordinator = revocationCoordinator else {
            self.errorMessage = "데몬이 준비되지 않아 폐기할 수 없습니다."
            return
        }
        do {
            try await coordinator.revoke(deviceId: id)
            self.errorMessage = nil
            await refreshDevices()
        } catch {
            self.errorMessage = "디바이스 폐기에 실패했습니다."
        }
    }

    // MARK: - lifecycle 판정 노출 (DeviceLifecyclePolicy 위임)

    /// 디바이스가 만료 임박(7일 이내)인지 판정한다. 판정 코어는 DeviceLifecyclePolicy가 보유하며
    /// (Day 1 테스트 커버) 이 메서드는 위임만 한다. 뷰가 "N일 후 만료" 주황 뱃지 표시 여부에 쓴다.
    public func isExpiringSoon(_ device: Device, now: Date = Date()) -> Bool {
        lifecycle.isExpiringSoon(device, now: now)
    }

    /// 만료까지 남은 일수(올림). 뷰의 "N일 후 만료" 뱃지 표기용. 호출 전 isExpiringSoon로 거른다.
    public func daysRemaining(_ device: Device, now: Date = Date()) -> Int {
        lifecycle.daysRemaining(device, now: now)
    }

    /// 디바이스가 이미 만료됐는지 판정한다(expiresAt <= now). 뷰가 "만료됨" 빨강 뱃지에 쓴다.
    /// revoked와 독립적인 표시다(폐기는 device.revoked, 만료는 시간 경과).
    public func isExpired(_ device: Device, now: Date = Date()) -> Bool {
        device.expiresAt <= now
    }

    // MARK: - Tailscale 진단

    /// Tailscale 상태를 1회 진단해 tailscaleResult에 반영한다(설정 진입 시 + 수동 새로고침).
    /// diagnostics 미주입 시 no-op. 진단은 외부 CLI 호출이라 비동기다(seam 뒤 격리).
    public func refreshTailscale() async {
        guard let diagnostics = tailscaleDiagnostics else { return }
        self.tailscaleResult = await diagnostics.diagnose()
    }

    /// 등록된 디바이스 목록을 다시 읽는다.
    public func refreshDevices() async {
        do {
            self.devices = try await store.list()
        } catch {
            self.errorMessage = "디바이스 목록을 불러오지 못했습니다."
        }
    }

    /// 화면을 떠날 때 카운트다운 타이머를 멈춘다.
    public func stop() {
        timerCancellable?.cancel()
        timerCancellable = nil
    }

    // MARK: - 내부 헬퍼

    /// 1초마다 남은 시간을 갱신하는 카운트다운을 시작한다. 만료 시 코드/QR을 비운다.
    private func startCountdown(until expiry: Date) {
        timerCancellable?.cancel()
        updateRemaining(expiry: expiry)
        timerCancellable = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.updateRemaining(expiry: expiry)
            }
    }

    /// 남은 초를 다시 계산한다. 0 이하로 떨어지면 코드/QR을 비우고 타이머를 멈춘다.
    private func updateRemaining(expiry: Date) {
        let remaining = Int(expiry.timeIntervalSinceNow.rounded(.down))
        if remaining <= 0 {
            self.secondsRemaining = 0
            self.sixDigitCode = nil
            self.qrPayloadURL = nil
            self.expiresAt = nil
            timerCancellable?.cancel()
            timerCancellable = nil
        } else {
            self.secondsRemaining = remaining
        }
    }
}
