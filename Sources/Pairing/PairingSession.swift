import Foundation

/// 6자리 코드 기반 페어링 세션을 관리하는 actor. 코드 발급 → 만료(기본 5분) → claim
/// (정답 코드 제출 시 PairingPayload 반환) → rate-limit(틀린 코드 기본 5회 제출 시 폐기)을
/// 담당한다.
///
/// 단일 활성 코드 모델이다. 한 번에 하나의 in-flight 코드만 존재하며, 그 코드를 향한
/// 틀린 제출(오claim)이 한도에 도달하면 코드를 폐기해 brute-force를 차단한다
/// (pre-mortem 시나리오 2). 시간은 주입된 clock(`now`)으로만 읽어 만료 경계를
/// 결정론적으로 테스트할 수 있다. 거부 사유는 PushSender.rejectedCount 선례대로
/// testable 카운터·lastRejectCode로 노출해 os_log 캡처 없이 어서션한다.
/// secret(payload.deviceTokenSecret)은 어떤 로그에도 남기지 않는다.
public actor PairingSession {
    /// claim 거부 사유 코드(§5.5 pairing.response 에러 코드와 정합).
    public enum RejectCode: String, Sendable, Equatable {
        case invalid = "PAIRING_CODE_INVALID"
        case expired = "PAIRING_CODE_EXPIRED"
        case rateLimited = "PAIRING_RATE_LIMITED"
    }

    /// 발급된 단일 활성 코드의 상태.
    private struct ActiveCode {
        let code: String
        let payload: PairingPayload
        let expiresAt: Date
        var failedAttempts: Int
    }

    private let ttl: TimeInterval
    private let maxClaimAttempts: Int
    private let now: @Sendable () -> Date

    /// 현재 in-flight 활성 코드. 발급 시 설정, claim 성공/만료/폐기 시 nil로 비운다.
    private var active: ActiveCode?

    /// testable 카운터(PushSender 선례). 누적 claim/만료/오claim 측정용.
    public private(set) var rejectedCount = 0
    public private(set) var lastRejectCode: String?

    /// 환경 변수에서 정책을 읽어 초기화한다. ttl/maxClaimAttempts/now는 테스트에서 주입한다.
    public init(
        ttl: TimeInterval = PairingSession.defaultTTL(),
        maxClaimAttempts: Int = PairingSession.defaultMaxClaimAttempts(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.ttl = ttl
        self.maxClaimAttempts = maxClaimAttempts
        self.now = now
    }

    /// 새 6자리 코드를 발급하고, claim 시 반환할 payload를 그 코드에 묶는다. 만료 시각은
    /// now + ttl로 고정한다. 직전 활성 코드가 있으면 교체(폐기)된다. 발급된 코드를 반환한다.
    public func issue(payload: PairingPayload) throws -> String {
        let code = try SixDigitCode.generate()
        active = ActiveCode(
            code: code,
            payload: payload,
            expiresAt: now().addingTimeInterval(ttl),
            failedAttempts: 0
        )
        return code
    }

    /// 코드를 제출해 payload를 받는다. 단일 진입점으로 rate-limit·만료·1회 소비를 모두 처리한다.
    ///   - 활성 코드 없음: PAIRING_CODE_INVALID
    ///   - 만료: PAIRING_CODE_EXPIRED(코드 폐기)
    ///   - 정답 일치: 성공, 코드 1회 소비(replay 방지)
    ///   - 불일치: 오claim 누적. 한도 도달 시 PAIRING_RATE_LIMITED(폐기), 그 전엔 PAIRING_CODE_INVALID
    public func claim(code: String) -> PairingPayload? {
        guard var entry = active else {
            recordReject(.invalid)
            return nil
        }

        // 만료 경계: now가 expiresAt를 지난 경우에만 만료. expiresAt 시점 이전(만료 1초 전
        // 포함)은 유효하다(now > expiresAt 일 때만 만료로 본다).
        if now() > entry.expiresAt {
            active = nil
            recordReject(.expired)
            return nil
        }

        // 정답 일치: 코드를 1회 소비하고 payload 반환.
        if entry.code == code {
            active = nil
            return entry.payload
        }

        // 오claim: 활성 코드의 실패 카운터를 올린다. 한도 도달 시 코드를 폐기한다.
        entry.failedAttempts += 1
        if entry.failedAttempts >= maxClaimAttempts {
            active = nil
            recordReject(.rateLimited)
            return nil
        }
        active = entry
        recordReject(.invalid)
        return nil
    }

    /// 현재 활성 코드가 살아 있는지(테스트 introspection).
    public func hasActiveCode() -> Bool {
        active != nil
    }

    private func recordReject(_ code: RejectCode) {
        rejectedCount += 1
        lastRejectCode = code.rawValue
    }

    // MARK: - 환경 변수 기본값

    /// CLAUDE_ALARM_PAIRING_TTL_SECONDS(기본 300초 = 5분).
    public static func defaultTTL() -> TimeInterval {
        envDouble("CLAUDE_ALARM_PAIRING_TTL_SECONDS") ?? 300
    }

    /// CLAUDE_ALARM_PAIRING_MAX_CLAIM_ATTEMPTS(기본 5).
    public static func defaultMaxClaimAttempts() -> Int {
        envInt("CLAUDE_ALARM_PAIRING_MAX_CLAIM_ATTEMPTS") ?? 5
    }

    private static func envDouble(_ key: String) -> Double? {
        guard let raw = ProcessInfo.processInfo.environment[key] else { return nil }
        return Double(raw)
    }

    private static func envInt(_ key: String) -> Int? {
        guard let raw = ProcessInfo.processInfo.environment[key] else { return nil }
        return Int(raw)
    }
}
