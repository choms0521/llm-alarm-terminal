import XCTest
import Foundation

/// Day 4 acceptance: (h) internal input wiring through the NEW
/// `attachInternalSession` → `SerialInputQueue` path (layer a, daemon seam).
///
/// These assert the new attach path — not the control filter that existed since
/// P4 — by driving input through `SessionDaemon.attachInternalSession` /
/// `sendInput` and observing a spy injector. The serial queue is async, so the
/// spy is polled with a timeout (the daemon's `inputQueue` is private).
final class InternalSessionWiringTests: XCTestCase {

    /// Printable bytes injected through the new path reach the sink in full.
    func testInternalInputReachesSinkViaNewPath() async throws {
        let spy = await MainActor.run { WiringSpyInjector() }
        let daemon = SessionDaemon()
        let sid = UUID()
        await daemon.attachInternalSession(sessionId: sid, sink: InternalSink(injector: spy))

        let input: [UInt8] = Array("가나다".utf8)
        await daemon.sendInput(InputItem(bytes: input), to: sid)

        try await waitFor { await MainActor.run { spy.flat } == input }
        let got = await MainActor.run { spy.flat }
        XCTAssertEqual(got, input)
        await daemon.detach(sessionId: sid)
    }

    /// Multiple injections preserve order through the serial queue (R8).
    func testInternalInputPreservesOrder() async throws {
        let spy = await MainActor.run { WiringSpyInjector() }
        let daemon = SessionDaemon()
        let sid = UUID()
        await daemon.attachInternalSession(sessionId: sid, sink: InternalSink(injector: spy))

        for i in 0..<10 {
            await daemon.sendInput(InputItem(bytes: [UInt8(0x30 + i)]), to: sid)
        }
        try await waitFor { await MainActor.run { spy.received.count } == 10 }
        let got = await MainActor.run { spy.received }
        XCTAssertEqual(got, (0..<10).map { [UInt8(0x30 + $0)] })
        await daemon.detach(sessionId: sid)
    }

    /// A control byte injected through the new path is rejected (C1): the injector
    /// is never called and INTERNAL_CONTROL_INPUT_UNSUPPORTED surfaces.
    func testControlByteRejectedOnNewPath() async throws {
        let spy = await MainActor.run { WiringSpyInjector() }
        let errors = WiringErrorBox()
        let daemon = SessionDaemon()
        let sid = UUID()
        let sink = InternalSink(injector: spy, onUnsupported: { errors.append($0) })
        await daemon.attachInternalSession(sessionId: sid, sink: sink)

        await daemon.sendInput(InputItem(bytes: [0x03]), to: sid)   // control byte
        try await waitFor { errors.all().count == 1 }

        XCTAssertEqual(errors.all(), [.internalControlInputUnsupported])
        let got = await MainActor.run { spy.received }
        XCTAssertTrue(got.isEmpty)
        await daemon.detach(sessionId: sid)
    }

    // MARK: - Helpers

    private func waitFor(_ condition: @escaping () async -> Bool,
                         timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { XCTFail("condition not met within \(timeout)s"); return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

@MainActor
private final class WiringSpyInjector: PrintableTextInjecting {
    var received: [[UInt8]] = []
    var flat: [UInt8] { received.flatMap { $0 } }
    func injectPrintable(_ bytes: [UInt8]) { received.append(bytes) }
}

private final class WiringErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [DaemonErrorCode] = []
    func append(_ code: DaemonErrorCode) { lock.lock(); items.append(code); lock.unlock() }
    func all() -> [DaemonErrorCode] { lock.lock(); defer { lock.unlock() }; return items }
}
