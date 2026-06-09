import XCTest
import Foundation

/// Day 0 smoke test: proves the DaemonTests bundle compiles and links a real
/// XCTest case so `build-for-testing` produces a valid test bundle. Day 1+
/// add the envelope/ring-buffer/server/queue test suites alongside this file.
final class DaemonSmokeTests: XCTestCase {
    func testDaemonModuleSchemaVersion() {
        XCTAssertEqual(DaemonModule.envelopeSchemaVersion, "0.9")
    }
}
