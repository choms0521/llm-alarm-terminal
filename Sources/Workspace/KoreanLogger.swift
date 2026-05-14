import Foundation
import os.log

/// 한국어 메시지를 unified logging 시스템에 송출하는 얇은 wrapper.
///
/// `WorkspaceStore` 의 복구 경고와 동일 카테고리로 묶기 위해 단일 진입점을 둔다.
/// 후속 단계(P3~)에서 새 카테고리가 필요해지면 `Logger` 인스턴스를 추가한다.
public enum KoreanLogger {
    private static let log = Logger(
        subsystem: "com.choms0521.ClaudeAlarmTerminal",
        category: "Workspace"
    )

    public static func info(_ message: String) {
        log.info("\(message, privacy: .public)")
    }

    public static func warn(_ message: String) {
        log.warning("\(message, privacy: .public)")
    }

    public static func error(_ message: String) {
        log.error("\(message, privacy: .public)")
    }
}
