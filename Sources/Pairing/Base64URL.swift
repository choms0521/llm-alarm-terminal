import Foundation

/// base64url(RFC 4648 §5) 인코딩/디코딩 헬퍼.
///
/// 토큰 secret과 페어링 payload는 URL/QR/헤더에 안전하게 실려야 하므로 표준
/// base64의 `+`/`/`/`=` 대신 URL-safe 알파벳(`-`/`_`)을 쓰고 padding을 제거한다.
/// PairingCodec과 DeviceTokenIssuer가 공유하는 단일 변환 지점이다.
public enum Base64URL {
    /// raw bytes를 base64url 문자열로 인코딩한다(padding 제거).
    public static func encode(_ data: Data) -> String {
        let base64 = data.base64EncodedString()
        return base64
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// base64url 문자열을 raw bytes로 디코딩한다. 형식이 어긋나면 nil.
    public static func decode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // base64는 4의 배수 길이를 요구하므로 제거됐던 padding을 복원한다.
        let remainder = base64.count % 4
        if remainder > 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: base64)
    }
}
