import XCTest
import Foundation

/// Day 4 acceptance: serial input queue (origin-specific 2-path, strict FIFO, R8).
/// A7 intra-queue ordering plus single-consumer invariant and pending cleanup.
final class SerialInputQueueTests: XCTestCase {

    // A7: 100 items enqueued in order reach the real ExternalSink (a pipe master
    // fd) byte-for-byte in enqueue order.
    func testExternalSinkPreservesOrder() async throws {
        var fds = [Int32](repeating: 0, count: 2)
        XCTAssertEqual(pipe(&fds), 0)
        let readFD = fds[0], writeFD = fds[1]
        defer { close(readFD); close(writeFD) }

        let queue = SerialInputQueue()
        let sid = UUID()
        await queue.attach(sessionId: sid, sink: ExternalSink(masterFD: writeFD))
        for i in 0..<100 {
            await queue.enqueue(InputItem(bytes: [UInt8(i)]), for: sid)
        }
        try await waitForDrain(queue, sid)

        let received = readExactly(readFD, 100)
        XCTAssertEqual(received.map(Int.init), Array(0..<100))
        await queue.detach(sessionId: sid)
    }

    // Exactly one consumer per session; a second attach is a no-op.
    func testSingleConsumerInvariant() async throws {
        let queue = SerialInputQueue()
        let sid = UUID()
        let injector = await MainActor.run { RecordingInjector() }
        await queue.attach(sessionId: sid, sink: InternalSink(injector: injector))
        await queue.attach(sessionId: sid, sink: InternalSink(injector: injector))
        let count = await queue.consumerCount(for: sid)
        XCTAssertEqual(count, 1)
        await queue.detach(sessionId: sid)
        let afterDetach = await queue.consumerCount(for: sid)
        XCTAssertEqual(afterDetach, 0)
    }

    // Internal sink: 10 printable items injected in call order.
    func testInternalSinkPreservesOrder() async throws {
        let injector = await MainActor.run { RecordingInjector() }
        let queue = SerialInputQueue()
        let sid = UUID()
        await queue.attach(sessionId: sid, sink: InternalSink(injector: injector))
        for i in 0..<10 {
            await queue.enqueue(InputItem(bytes: [UInt8(0x30 + i)]), for: sid)
        }
        try await waitForDrain(queue, sid)

        let received = await MainActor.run { injector.received }
        XCTAssertEqual(received, (0..<10).map { [UInt8(0x30 + $0)] })
        await queue.detach(sessionId: sid)
    }

    // Internal control input is unsupported (C1): both a single control byte and
    // a multi-byte ESC/CSI sequence surface the code and inject nothing. Control
    // is derived from the bytes (InputItem.containsControl), not a trusted flag.
    func testInternalControlInputUnsupported() async throws {
        let injector = await MainActor.run { RecordingInjector() }
        let errors = ErrorBox()
        let sink = InternalSink(injector: injector, onUnsupported: { errors.append($0) })
        let queue = SerialInputQueue()
        let sid = UUID()
        await queue.attach(sessionId: sid, sink: sink)
        await queue.enqueue(InputItem(bytes: [0x03]), for: sid)              // single control
        await queue.enqueue(InputItem(bytes: [0x1b, 0x5b, 0x41]), for: sid)  // ESC [ A (multi-byte)
        try await waitForDrain(queue, sid)

        XCTAssertEqual(errors.all(), [.internalControlInputUnsupported, .internalControlInputUnsupported])
        let received = await MainActor.run { injector.received }
        XCTAssertTrue(received.isEmpty)
        await queue.detach(sessionId: sid)
    }

    // Pending drains to 0 via real itemDrained accounting, and stays 0 after teardown.
    func testTeardownPendingZero() async throws {
        let queue = SerialInputQueue()
        let sid = UUID()
        let injector = await MainActor.run { RecordingInjector() }
        await queue.attach(sessionId: sid, sink: InternalSink(injector: injector))
        for i in 0..<5 {
            await queue.enqueue(InputItem(bytes: [UInt8(0x30 + i)]), for: sid)
        }
        // The consumer decrements pending as each item drains — assert that before
        // detach, so the assertion is not satisfied merely by detach nil-ing state.
        try await waitForDrain(queue, sid)
        let drainedPending = await queue.pendingCount(for: sid)
        XCTAssertEqual(drainedPending, 0)

        await queue.detach(sessionId: sid)
        let afterDetach = await queue.pendingCount(for: sid)
        XCTAssertEqual(afterDetach, 0)
    }

    // MARK: - Helpers

    private func waitForDrain(_ queue: SerialInputQueue, _ sid: UUID,
                              timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while await queue.pendingCount(for: sid) > 0 {
            if Date() > deadline { XCTFail("queue did not drain within \(timeout)s"); return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func readExactly(_ fd: Int32, _ count: Int) -> [UInt8] {
        var out = [UInt8]()
        var buf = [UInt8](repeating: 0, count: count)
        while out.count < count {
            let n = read(fd, &buf, count - out.count)
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        return out
    }
}

@MainActor
private final class RecordingInjector: PrintableTextInjecting {
    var received: [[UInt8]] = []
    func injectPrintable(_ bytes: [UInt8]) { received.append(bytes) }
}

private final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [DaemonErrorCode] = []
    func append(_ code: DaemonErrorCode) { lock.lock(); items.append(code); lock.unlock() }
    func all() -> [DaemonErrorCode] { lock.lock(); defer { lock.unlock() }; return items }
}
