import Foundation

/// grapheme cluster 단위 truncation. Swift `String.prefix(_:)` 은 이미 grapheme
/// 경계에서 자르므로 본 enum 은 의미적 anchor 역할이다.
///
/// `Data.prefix(byte)` 또는 utf8 byte 절단을 절대 사용하지 않는다. 한글
/// ("가나다") 또는 ZWJ emoji("👨‍👩‍👧‍👦") 가 중간에서 절단되면 mojibake / broken
/// rendering 이 발생한다.
public enum Utf8BoundaryTruncator {
    /// `maxGraphemes` 개 이하의 grapheme cluster 로 잘라낸 새 문자열.
    /// 입력이 이미 짧으면 그대로 반환한다.
    public static func truncate(_ s: String, maxGraphemes: Int) -> String {
        if maxGraphemes <= 0 { return "" }
        if s.count <= maxGraphemes { return s }
        return String(s.prefix(maxGraphemes))
    }
}
