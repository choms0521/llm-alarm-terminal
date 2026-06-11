import Foundation
import Security

/// 6자리 페어링 코드(000000~999999). 항상 6자리 형식을 보장하기 위해 앞자리를 0으로
/// 채운다(zero-pad). 암호학적 난수(SecRandomCopyBytes)를 쓰고, modulo bias를 없애기
/// 위해 rejection sampling으로 균일 분포를 보장한다.
public enum SixDigitCode {
    /// 코드 생성 중 발생할 수 있는 오류.
    public enum CodeError: Error, Equatable {
        case randomGenerationFailed(OSStatus)
    }

    /// 가능한 코드 수(10^6). 균일 추출의 상한이다.
    private static let range: UInt32 = 1_000_000

    /// 6자리 코드 문자열을 생성한다. 항상 정확히 6자(필요 시 앞자리 0 패딩).
    public static func generate() throws -> String {
        let value = try uniformRandom(below: range)
        return String(format: "%06u", value)
    }

    /// [0, upperBound) 범위의 균일 난수를 rejection sampling으로 뽑는다. 단순 modulo는
    /// 2^32가 upperBound로 나누어떨어지지 않아 작은 값에 편향이 생기므로, 편향 구간에
    /// 떨어진 표본은 버리고 다시 뽑는다.
    static func uniformRandom(below upperBound: UInt32) throws -> UInt32 {
        // 버려야 할 상위 잔여 구간의 시작점. 이 값 이상이면 modulo 편향에 해당해 재추출한다.
        let limit = UInt32.max - (UInt32.max % upperBound)
        while true {
            let candidate = try randomUInt32()
            if candidate < limit {
                return candidate % upperBound
            }
        }
    }

    /// SecRandomCopyBytes로 4바이트를 읽어 UInt32로 합성한다.
    private static func randomUInt32() throws -> UInt32 {
        var bytes = [UInt8](repeating: 0, count: 4)
        let status = SecRandomCopyBytes(kSecRandomDefault, 4, &bytes)
        guard status == errSecSuccess else {
            throw CodeError.randomGenerationFailed(status)
        }
        return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}
