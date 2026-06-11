import Foundation
import Security

/// 디바이스 토큰을 발급한다. secret은 SecRandomCopyBytes 32바이트의 암호학적 난수이며
/// base64url로 표현한다. Bearer 형식은 `<tokenId>.<secretBase64url>`이다.
///
/// tokenId는 secret이 아닌 식별자라 로그·매칭에 노출해도 안전하다. raw secret(Data)은
/// Keychain 저장과 constant-time 검증에만 쓰이고 어떤 로그에도 남기지 않는다.
public enum DeviceTokenIssuer {
    /// 토큰 발급 중 발생할 수 있는 오류.
    public enum IssueError: Error, Equatable {
        case randomGenerationFailed(OSStatus)
    }

    /// 발급 결과. tokenId는 식별자, secret은 raw bytes(Keychain 저장용),
    /// secretBase64url은 운반용 표현이다.
    public struct IssuedToken: Sendable, Equatable {
        public let tokenId: String
        public let secret: Data
        public let secretBase64url: String

        /// `<tokenId>.<secretBase64url>` 형식의 Bearer 토큰 문자열.
        public var bearer: String { "\(tokenId).\(secretBase64url)" }
    }

    /// 새 토큰을 발급한다. tokenId는 UUID(소문자), secret은 32바이트 난수다.
    public static func issue(tokenId: String = UUID().uuidString.lowercased()) throws -> IssuedToken {
        let secret = try randomBytes(count: 32)
        return IssuedToken(
            tokenId: tokenId,
            secret: secret,
            secretBase64url: Base64URL.encode(secret)
        )
    }

    /// SecRandomCopyBytes로 암호학적 난수 바이트를 생성한다.
    static func randomBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else {
            throw IssueError.randomGenerationFailed(status)
        }
        return Data(bytes)
    }
}
