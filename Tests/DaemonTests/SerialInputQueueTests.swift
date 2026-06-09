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

    // Internal control byte is unsupported (C1): surfaces the code, injects nothing.
    func testInternalControlByteUnsupported() async throws {
        let injector = await MainActor.run { RecordingInjector() }
        let errors = ErrorBox()
        let sink = InternalSink(injector: injector, onUnsupported: { errors.append($0) })
        let queue = SerialInputQueue()
        let sid = UUID()
        await queue.attach(sessionId: sid, sink: sink)
        await queue.enqueue(InputItem(bytes: [0x03], isControl: true), for: sid)
        try await waitForDrain(queue, sid)

        XCTAssertEqual(errors.all(), [.internalControlInputUnsupported])
        let received = await MainActor.run { injector.received }
        XCTAssertTrue(received.isEmpty)
        await queue.detach(sessionId: sid)
    }

    // Teardown leaves no pending items.
    func testTeardownPendingZero() async throws {
        let queue = SerialInputQueue()
        let sid = UUID()
        let injector = await MainActor.run { RecordingInjector() }
        await queue.attach(sessionId: sid, sink: InternalSink(injector: injector))
        for i in 0..<5 {
            await queue.enqueue(InputItem(bytes: [UInt8(0x30 + i)]), for: sid)
        }
        await queue.detach(sessionId: sid)
        let pending = await queue.pendingCount(for: sid)
        XCTAssertEqual(pending, 0)
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
