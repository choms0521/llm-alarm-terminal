import Foundation
import os

/// Logger for the push path. Never logs FCM/APNs keys or device tokens — only
/// previews, error codes, and session identifiers (§6.1 security). All push code
/// routes diagnostics through here so the no-secret invariant has one choke point.
public enum PushLog {
    private static let logger = Logger(
        subsystem: "com.choms0521.ClaudeAlarmTerminal",
        category: "Push"
    )

    public static func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }

    public static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    public static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}
