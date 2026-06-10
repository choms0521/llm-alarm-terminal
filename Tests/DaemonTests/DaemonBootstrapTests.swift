import XCTest
import Foundation

/// Day 3 acceptance: (g) the daemon bootstrap returns a live loopback port,
/// proving the app's startup path can launch the in-process daemon.
final class DaemonBootstrapTests: XCTestCase {

    func testStartReturnsLivePort() async throws {
        let handle = try await DaemonBootstrap().start()
        defer { Task { await handle.server.stop() } }
        XCTAssertGreaterThan(handle.port, 0)
    }
}
