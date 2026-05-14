import Foundation

/// `Codable` 동적 키 컨테이너. `Workspace`/`Pane` 의 forward-compat
/// `extraFields` 캐치-올 디코딩에 사용된다.
internal struct DynamicCodingKey: CodingKey {
    let stringValue: String
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
    var intValue: Int? { nil }
}
