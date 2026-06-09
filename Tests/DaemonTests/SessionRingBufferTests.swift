import XCTest
import Foundation

/// Day 2 acceptance: per-session ring buffer with message-boundary drop-and-mark.
/// Covers A2 (single drop mark per overflow episode) plus latch reset and
/// UTF-8 integrity of retained envelopes.
final class SessionRingBufferTests: XCTestCase {
    private let deviceActor = EnvelopeActor(deviceId: "daemon-local")

    private func env(_ i: Int, text: String? = nil) -> WSEnvelope {
        WSEnvelope(seq: UInt64(i), actor: deviceActor, kind: .output, text: text ?? "msg-\(i)")
    }

    // 600 enqueues into a 500-capacity buffer -> count 500, exactly one drop mark.
    func testOverflowDropsToCapacityWithSingleMark() {
        let buffer = SessionRingBuffer(sessionId: UUID(), capacity: 500)
        var marks: [WSEnvelope] = []
        for i in 0..<600 {
            if let mark = buffer.enqueue(env(i)) { marks.append(mark) }
        }
        XCTAssertEqual(buffer.count, 500)
        XCTAssertEqual(buffer.dropEventCount, 1)
        XCTAssertEqual(marks.count, 1)
        XCTAssertEqual(marks.first?.kind, .error)
        XCTAssertEqual(marks.first?.code, "BUFFER_OVERFLOW_DROPPED")
    }

    // No mark while the buffer stays at or below capacity.
    func testNoMarkBelowCapacity() {
        let buffer = SessionRingBuffer(sessionId: UUID(), capacity: 500)
        for i in 0..<500 { XCTAssertNil(buffer.enqueue(env(i))) }
        XCTAssertEqual(buffer.count, 500)
        XCTAssertEqual(buffer.dropEventCount, 0)
    }

    // Retained envelopes are all valid UTF-8 (whole-message drops never split bytes).
    func testRetainedEnvelopesAllValidUtf8() {
        let buffer = SessionRingBuffer(sessionId: UUID(), capacity: 500)
        for i in 0..<600 { buffer.enqueue(env(i)) }
        let retained = buffer.drain(upTo: 1000)
        XCTAssertEqual(retained.count, 500)
        XCTAssertTrue(retained.allSatisfy { $0.payloadText != nil })
    }

    // Drain below capacity resets the latch; a later overflow emits a 2nd mark.
    func testLatchResetsAfterDrain() {
        let buffer = SessionRingBuffer(sessionId: UUID(), capacity: 500)
        for i in 0..<600 { buffer.enqueue(env(i)) }           // mark 1
        XCTAssertEqual(buffer.dropEventCount, 1)

        _ = buffer.drain(upTo: 100)                           // 500 -> 400 (< capacity, latch reset)
        XCTAssertEqual(buffer.count, 400)

        var secondMark: WSEnvelope?
        for i in 600..<702 {                                  // 400 -> 500 (no drop) then overflow
            if let mark = buffer.enqueue(env(i)) { secondMark = mark }
        }
        XCTAssertEqual(buffer.count, 500)
        XCTAssertEqual(buffer.dropEventCount, 2)
        XCTAssertEqual(secondMark?.code, "BUFFER_OVERFLOW_DROPPED")
    }

    // Korean payloads survive enqueue/drain and remain fully decodable.
    func testKoreanPayloadRetainedDecodable() throws {
        let buffer = SessionRingBuffer(sessionId: UUID(), capacity: 500)
        for i in 0..<560 { buffer.enqueue(env(i, text: "한국어 메시지 \(i) 가나다라마")) }
        let retained = buffer.drain(upTo: 1000)
        XCTAssertEqual(retained.count, 500)
        for envelope in retained {
            let roundTripped = try EnvelopeCodec.decode(EnvelopeCodec.encode(envelope))
            XCTAssertEqual(roundTripped.payloadText, envelope.payloadText)
            XCTAssertNotNil(roundTripped.payloadText)
        }
    }

    // The drop mark payload carries the session id and a drop count (§7 schema).
    func testDropMarkPayloadShape() throws {
        let sid = UUID()
        let buffer = SessionRingBuffer(sessionId: sid, capacity: 10)
        var mark: WSEnvelope?
        for i in 0..<12 { if let m = buffer.enqueue(env(i)) { mark = m } }
        let payload = try XCTUnwrap(mark?.payloadText)
        XCTAssertTrue(payload.contains("\"sessionId\":\"\(sid.uuidString)\""))
        XCTAssertTrue(payload.contains("\"droppedCount\":"))
    }
}
