import Foundation

/// 디바이스가 페어링을 완료하는 데 필요한 정보 묶음. QR은 이 payload 전체를 직접
/// 인코딩하고(원샷), 6자리 코드 경로는 pairing.claim→pairing.response로 이 payload를
/// 교환한다(secret 포함).
///
/// deviceTokenSecret은 QR/claim 응답에만 존재하며 운영 envelope payload·로그에는
/// 절대 담기지 않는다(master § 7 보안 원칙).
public struct PairingPayload: Codable, Equatable, Sendable {
    public let pairingId: String
    /// base64url(32 random bytes). QR/claim 응답에만 존재.
    public let deviceTokenSecret: String
    /// P6a: ws://127.0.0.1:<port>/ (D-5). P6b: tailnet.
    public let wsEndpoint: String
    /// P6a: mock 채널 ID 문자열. S1/P10a 실 채널.
    public let pushChannelHint: String
    public let expiresAt: Date

    public init(
        pairingId: String,
        deviceTokenSecret: String,
        wsEndpoint: String,
        pushChannelHint: String,
        expiresAt: Date
    ) {
        self.pairingId = pairingId
        self.deviceTokenSecret = deviceTokenSecret
        self.wsEndpoint = wsEndpoint
        self.pushChannelHint = pushChannelHint
        self.expiresAt = expiresAt
    }
}
