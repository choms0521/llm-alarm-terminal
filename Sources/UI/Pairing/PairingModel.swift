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

    private let session: PairingSession
    private let store: any DeviceStore
    private let wsEndpoint: String
    private let pushChannelHint: String
    /// 만료 카운트다운 기준 시각. 발급 시 갱신.
    private var expiresAt: Date?
    private var timerCancellable: AnyCancellable?

    /// PairingSession/DeviceStore/엔드포인트를 주입한다. wsEndpoint는 데몬 port로 구성한
    /// ws://127.0.0.1:<port>/ 문자열이다.
    public init(
        session: PairingSession,
        store: any DeviceStore,
        wsEndpoint: String,
        pushChannelHint: String = "mock-channel"
    ) {
        self.session = session
        self.store = store
        self.wsEndpoint = wsEndpoint
        self.pushChannelHint = pushChannelHint
    }

    /// 새 페어링 코드를 발급한다. 새 토큰 secret을 만들어 DeviceStore에 등록하고, 같은
    /// payload를 QR/6자리 코드 두 채널로 노출한다. 발급 결과로 카운트다운 타이머를 시작한다.
    public func issueNewCode() async {
        do {
            let issued = try DeviceTokenIssuer.issue()
            let expiry = Date().addingTimeInterval(deviceTokenLifetime())
            let pairingId = UUID().uuidString
            let device = Device(
                id: UUID(),
                name: "페어링 디바이스",
                tokenId: issued.tokenId,
                expiresAt: expiry
            )
            try await store.upsert(device, secret: issued.secret)

            // 세션에 주입된 실제 ttl로 계산해 UI 카운트다운/payload expiresAt이
            // PairingSession.issue의 만료 판정과 항상 일치하게 한다.
            let codeExpiry = Date().addingTimeInterval(session.ttl)
            let payload = PairingPayload(
                pairingId: pairingId,
                deviceTokenSecret: issued.secretBase64url,
                wsEndpoint: wsEndpoint,
                pushChannelHint: pushChannelHint,
                expiresAt: codeExpiry
            )
            let code = try await session.issue(payload: payload)
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

    /// CLAUDE_ALARM_DEVICE_TOKEN_EXPIRY_DAYS(기본 30일). P6a는 스키마만 — 강제는 P6b.
    private func deviceTokenLifetime() -> TimeInterval {
        let days = ProcessInfo.processInfo.environment["CLAUDE_ALARM_DEVICE_TOKEN_EXPIRY_DAYS"]
            .flatMap(Double.init) ?? 30
        return days * 24 * 60 * 60
    }
}
