import Foundation

/// PairingPayload ↔ URL scheme 변환. JSON → base64url → custom scheme의 라운드트립이
/// byte-identical하도록 인코더/디코더에 동일한 ISO8601 Date 전략을 고정한다.
///
/// QR 경로: encodeURL로 만든 `claudealarm://pair?d=<base64url>`를 QR에 직접 싣고,
/// 스캔 측은 decodeURL로 원본 payload를 복원한다.
public enum PairingCodec {
    /// 변환 중 발생할 수 있는 오류.
    public enum CodecError: Error, Equatable {
        case urlConstructionFailed
        case missingPayloadQuery
        case base64URLDecodeFailed
    }

    /// 인코드·디코드가 공유하는 JSON 인코더. ISO8601 Date 전략을 고정해 라운드트립을 보장한다.
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // 키 순서를 안정화해 동일 입력이 항상 동일 바이트로 인코딩되게 한다.
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    /// 인코드·디코드가 공유하는 JSON 디코더.
    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// payload를 JSON으로 인코딩한다(claim 응답 본문 등에 직접 사용).
    public static func encodeJSON(_ payload: PairingPayload) throws -> Data {
        try makeEncoder().encode(payload)
    }

    /// JSON 본문을 payload로 디코딩한다.
    public static func decodeJSON(_ data: Data) throws -> PairingPayload {
        try makeDecoder().decode(PairingPayload.self, from: data)
    }

    /// payload를 custom URL scheme(`claudealarm://pair?d=<base64url(JSON)>`)으로 인코딩한다.
    public static func encodeURL(_ payload: PairingPayload) throws -> URL {
        let json = try encodeJSON(payload)
        let b64 = Base64URL.encode(json)
        guard let url = URL(string: "claudealarm://pair?d=\(b64)") else {
            throw CodecError.urlConstructionFailed
        }
        return url
    }

    /// custom URL scheme에서 payload를 복원한다. 쿼리 누락·base64url 위반은 오류.
    public static func decodeURL(_ url: URL) throws -> PairingPayload {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let b64 = components.queryItems?.first(where: { $0.name == "d" })?.value else {
            throw CodecError.missingPayloadQuery
        }
        guard let json = Base64URL.decode(b64) else {
            throw CodecError.base64URLDecodeFailed
        }
        return try decodeJSON(json)
    }
}
