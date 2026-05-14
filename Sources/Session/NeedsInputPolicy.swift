import Foundation

/// claude 세션의 viewport text 에서 사용자 입력 대기 여부를 판정하는 정책.
///
/// false positive (입력 대기가 아닌데 needsInput 표시) 는 잘못된 액션을 유도하므로
/// 절대 금지한다. false negative (실제 입력 대기인데 idle 표시) 는 다음 polling
/// tick 에서 회수되는 수준이라 허용한다.
///
/// 신규 v2 정책 도입 시 v1 은 namespace 보존하여 regression 비교 + telemetry
/// 카운터 추적을 유지한다.
public protocol NeedsInputPolicy: Sendable {
    var version: String { get }
    func detect(in viewportText: String) -> Bool
}

/// 첫 정책 버전. 보수적 white-list + SGR reset prefix 매칭 + 마지막 80 bytes 한정.
///
/// 마지막 80 bytes 한정의 이유: 스크롤 위쪽의 historical 메시지가 false positive
/// 를 유도하는 시나리오 차단. 사용자가 입력을 기다리는 시점에는 prompt 가 viewport
/// 최하단에 있다는 사실을 활용한다.
public struct NeedsInputPolicyV1: NeedsInputPolicy {
    public let version: String = "v1-2026-05"

    /// 마지막 80 bytes 안에서만 매칭하는 보수 white-list 패턴.
    private static let patterns: [String] = [
        "Do you want to apply this change?",
        "Do you want to proceed?",
        "Press Enter to continue",
        "[y/n]",
    ]

    /// claude REPL 의 ❯ prompt 는 항상 직전 SGR reset 시퀀스를 동반한다.
    /// 다른 cat/ls 같은 출력에서는 reset prefix 가 없으므로 FP 차단.
    private static let claudePromptMarker = "\u{1b}[0m❯ "
    private static let claudePromptMarkerDefaultFg = "\u{1b}[39m❯ "

    /// 정책 검사 영역. utf8 바이트 기준 마지막 80개.
    private static let scanByteWindow = 80

    public init() {}

    public func detect(in viewportText: String) -> Bool {
        let scan = Self.tailByteWindow(of: viewportText, byteCount: Self.scanByteWindow)
        for pattern in Self.patterns where scan.contains(pattern) {
            return true
        }
        if scan.contains(Self.claudePromptMarker) { return true }
        if scan.contains(Self.claudePromptMarkerDefaultFg) { return true }
        return false
    }

    /// utf8 byte 기준 마지막 N 바이트를 안전하게 잘라낸 문자열.
    /// 다중 바이트 경계 mid 절단 시 `String(decoding:as:)` 의 replacement
    /// character 가 채워지지만, 본 정책은 ASCII 패턴 + ESC 시퀀스만 매칭하므로 안전.
    private static func tailByteWindow(of text: String, byteCount: Int) -> String {
        let bytes = Array(text.utf8)
        guard bytes.count > byteCount else { return text }
        let tail = bytes.suffix(byteCount)
        return String(decoding: tail, as: UTF8.self)
    }
}
