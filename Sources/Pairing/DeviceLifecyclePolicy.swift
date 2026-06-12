import Foundation

/// 토큰 수명 정책. P6a Device.expiresAt 스키마 위에 "발급=pending, claim=active 승격"
/// 의미론을 얹는다. now 주입 clock으로 만료 경계를 결정론적으로 테스트한다(PairingSession 선례).
///
/// 순수 로직이며 상태를 갖지 않는다(Sendable struct). 시간은 호출자가 주입한 now로만 읽어
/// 만료 경계를 결정론적으로 어서션할 수 있게 한다.
public struct DeviceLifecyclePolicy: Sendable {
    /// active 토큰 수명(기본 30일 — 부록 A CLAUDE_ALARM_DEVICE_TOKEN_EXPIRY_DAYS).
    let activeLifetime: TimeInterval
    /// 만료 임박 판정 창(기본 7일 — 이 안이면 "만료 임박").
    let expiringWithinDays: Int

    /// 정책을 직접 주입해 초기화한다(테스트). 기본값은 환경 변수 기반 lifetime + 7일 창.
    public init(
        activeLifetime: TimeInterval = DeviceLifecyclePolicy.defaultActiveLifetime(),
        expiringWithinDays: Int = DeviceLifecyclePolicy.defaultExpiringWithinDays()
    ) {
        self.activeLifetime = activeLifetime
        self.expiringWithinDays = expiringWithinDays
    }

    /// pending 만료: 코드 ttl(5분)을 expiresAt로 둔다. claim 안 되면 verifier가 5분 후 거부.
    /// "발급=권한 부여"가 아니라 "claim=권한 부여"라는 의미론을 강제하는 핵심(D-3).
    public func pendingExpiry(codeTTL: TimeInterval, now: Date) -> Date {
        now.addingTimeInterval(codeTTL)
    }

    /// claim 성공 시 active 승격: expiresAt를 now+30일로 갱신. 동일 deviceId 재upsert는
    /// P6a upsert가 옛 tokenId/secret 폐기와 정합한다.
    public func activeExpiry(now: Date) -> Date {
        now.addingTimeInterval(activeLifetime)
    }

    /// 만료 임박 판정: 0 < (expiresAt - now) <= 7일. 이미 만료(<=0)는 제외(거부는 verifier 몫),
    /// 7일 초과도 제외. 데스크톱 UI가 이 결과로 "N일 후 만료" 경고를 그린다(push는 seam·미배선, D-4).
    public func isExpiringSoon(_ device: Device, now: Date) -> Bool {
        let remaining = device.expiresAt.timeIntervalSince(now)
        let window = TimeInterval(expiringWithinDays) * 86400
        return remaining > 0 && remaining <= window
    }

    /// 남은 일수(올림). UI 뱃지 "N일 후 만료" 표기용. 음수/0은 호출 전 isExpiringSoon이 거른다.
    public func daysRemaining(_ device: Device, now: Date) -> Int {
        let remaining = device.expiresAt.timeIntervalSince(now)
        return Int((remaining / 86400).rounded(.up))
    }

    // MARK: - 환경 변수 기본값

    /// CLAUDE_ALARM_DEVICE_TOKEN_EXPIRY_DAYS(기본 30일). active 승격 시 부여할 수명.
    public static func defaultActiveLifetime() -> TimeInterval {
        let days = ProcessInfo.processInfo.environment["CLAUDE_ALARM_DEVICE_TOKEN_EXPIRY_DAYS"]
            .flatMap(Double.init) ?? 30
        return days * 24 * 60 * 60
    }

    /// CLAUDE_ALARM_DEVICE_TOKEN_EXPIRING_WITHIN_DAYS(기본 7일). 만료 임박 경고 창.
    public static func defaultExpiringWithinDays() -> Int {
        ProcessInfo.processInfo.environment["CLAUDE_ALARM_DEVICE_TOKEN_EXPIRING_WITHIN_DAYS"]
            .flatMap(Int.init) ?? 7
    }
}
