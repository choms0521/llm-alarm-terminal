import XCTest
import Foundation

/// Day 5 acceptance: external output tap byte-fidelity (A1/A9), internal output
/// unsupported (A10), and external write hard-failure surfacing (A10/Risks).
///
/// The output tap is exercised by writing known UTF-8 bytes into a pipe whose
/// read end is the session "master fd" — the reverse of the Day 4 input pipe
/// trick — and asserting the emitted kind=output payload.
final class RoundTripTests: XCTestCase {

    func testExternalOutputKoreanRoundTrip() async throws {
        try await assertOutputContains("가나다\n", expected: "가나다")
    }

    func testExternalOutputEmojiRoundTrip() async throws {
        try await assertOutputContains("👍\n", expected: "👍")
    }

    // EOF must flush the accumulator's trailing incomplete UTF-8 carry as U+FFFD
    // instead of dropping it silently (Copilot PR #1 review).
    func testExternalOutputFlushesIncompleteUtf8OnEOF() async throws {
        var fds = [Int32](repeating: 0, count: 2)
        XCTAssertEqual(pipe(&fds), 0)
        let readFD = fds[0], writeFD = fds[1]

        let daemon = SessionDaemon()
        let collected = EnvelopeCollector()
        let readerClosed = expectation(description: "output reader saw EOF")
        let sid = UUID()
        await daemon.attachExternalOutput(
            sessionId: sid,
            masterFD: readFD,
            emit: { collected.append($0) },
            onClosed: { readerClosed.fulfill() }
        )

        // "가" = EA B0 80; write only the first two bytes -> incomplete trailing seq.
        let incomplete = Data([0xEA, 0xB0])
        _ = incomplete.withUnsafeBytes { write(writeFD, $0.baseAddress, incomplete.count) }

        // Closing the write end induces EOF; the carry must flush before onClosed.
        close(writeFD)
        await fulfillment(of: [readerClosed], timeout: 5)

        let joined = collected.all()
            .filter { $0.kind == .output }
            .compactMap { $0.payloadText }
            .joined()
        XCTAssertTrue(joined.contains("\u{FFFD}"),
                      "EOF should flush the incomplete UTF-8 carry as U+FFFD; got \(joined)")

        await daemon.detach(sessionId: sid)
        close(readFD)
    }

    private func assertOutputContains(_ source: String, expected: String) async throws {
        var fds = [Int32](repeating: 0, count: 2)
        XCTAssertEqual(pipe(&fds), 0)
        let readFD = fds[0], writeFD = fds[1]

        let daemon = SessionDaemon()
        let collected = EnvelopeCollector()
        let readerClosed = expectation(description: "output reader saw EOF")
        let sid = UUID()
        await daemon.attachExternalOutput(
            sessionId: sid,
            masterFD: readFD,
            emit: { collected.append($0) },
            onClosed: { readerClosed.fulfill() }
        )

        let bytes = Data(source.utf8)
        _ = bytes.withUnsafeBytes { write(writeFD, $0.baseAddress, bytes.count) }

        try await poll(timeout: 5) {
            collected.all().contains { ($0.payloadText ?? "").contains(expected) }
        }
        let outputs = collected.all().filter { $0.kind == .output }
        let joined = outputs.compactMap { $0.payloadText }.joined()
        XCTAssertTrue(joined.contains(expected), "output payload should contain \(expected); got \(joined)")

        // Safe teardown (mirrors SessionVerifier): induce EOF, wait for the read
        // to finish, then stop and close — never close an fd a DispatchIO read is
        // still monitoring.
        close(writeFD)
        await fulfillment(of: [readerClosed], timeout: 5)
        await daemon.detach(sessionId: sid)
        close(readFD)
    }

    // A10: requesting byte-faithful output for an internal session surfaces
    // INTERNAL_OUTPUT_UNSUPPORTED exactly once.
    func testInternalOutputUnsupported() async {
        let daemon = SessionDaemon()
        let collected = EnvelopeCollector()
        await daemon.requestInternalOutput(sessionId: UUID(), emit: { collected.append($0) })
        let unsupported = collected.all().filter {
            $0.kind == .error && $0.code == DaemonErrorCode.internalOutputUnsupported.rawValue
        }
        XCTAssertEqual(unsupported.count, 1)
    }

    // A hard write failure (closed fd -> EBADF) surfaces PTY_WRITE_FAILED exactly
    // once rather than dropping silently.
    func testExternalWriteHardFailureSurfacesError() async {
        var fds = [Int32](repeating: 0, count: 2)
        XCTAssertEqual(pipe(&fds), 0)
        let writeFD = fds[1]
        close(fds[0])
        close(fds[1]) // writeFD is now closed -> write() returns EBADF

        let errors = ErrorCollector()
        let sink = ExternalSink(masterFD: writeFD, onError: { errors.append($0) })
        await sink.write(InputItem(bytes: [0x41]))
        XCTAssertEqual(errors.all(), [.ptyWriteFailed])
    }

    // MARK: - Helpers

    private func poll(timeout: TimeInterval, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("condition not met within \(timeout)s"); return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

private final class EnvelopeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [WSEnvelope] = []
    func append(_ env: WSEnvelope) { lock.lock(); items.append(env); lock.unlock() }
    func all() -> [WSEnvelope] { lock.lock(); defer { lock.unlock() }; return items }
}

private final class ErrorCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [DaemonErrorCode] = []
    func append(_ code: DaemonErrorCode) { lock.lock(); items.append(code); lock.unlock() }
    func all() -> [DaemonErrorCode] { lock.lock(); defer { lock.unlock() }; return items }
}
