import Foundation

/// 신뢰 목록의 1 디바이스. P6a는 토큰 발급만 담당하며 expiresAt/revoked/fcm/apns는
/// P6b lifecycle UI와 S1/P10a 실 push를 수용하는 스키마이되 P6a에서는 미배선이다.
///
/// tokenId는 secret 자체가 아닌 식별자다. 로그·매칭에 안전하게 노출할 수 있으며,
/// 실제 secret은 DeviceStore.secret(forTokenId:)로만 조회된다.
public struct Device: Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    /// secret 자체가 아닌 식별자(로그·매칭에 안전).
    public let tokenId: String
    /// 예약 — S1/P10a에서 실 등록.
    public let fcmToken: String?
    /// 예약 — S1/P10a.
    public let apnsToken: String?
    /// 예약 — P6b lifecycle UI가 강제.
    public let expiresAt: Date
    /// 예약 — P6b revoke UI가 토글.
    public let revoked: Bool

    public init(
        id: UUID,
        name: String,
        tokenId: String,
        fcmToken: String? = nil,
        apnsToken: String? = nil,
        expiresAt: Date,
        revoked: Bool = false
    ) {
        self.id = id
        self.name = name
        self.tokenId = tokenId
        self.fcmToken = fcmToken
        self.apnsToken = apnsToken
        self.expiresAt = expiresAt
        self.revoked = revoked
    }
}
