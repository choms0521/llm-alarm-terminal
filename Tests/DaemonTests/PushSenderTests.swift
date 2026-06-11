import XCTest
import Foundation

/// Day 2 acceptance: PushSender WS-attached skip policy + 4KB reject-before-send.
final class PushSenderTests: XCTestCase {

    private struct MockAttachment: AttachmentQuerying {
        let attached: Bool
        func isAttached(_ sessionId: UUID) async -> Bool { attached }
    }

    private func makeEnvelope(fetchHint: String? = nil) -> PushEnvelope {
        let sid = UUID()
        return PushEnvelope(
            sessionId: sid,
            messageId: UUID(),
            preview: "테스트 메시지",
            chatRoomId: sid.uuidString,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            fetchHint: fetchHint
        )
    }

    /// attached + skipWhenAttached=true → skip (transport never called).
    func testSkipsWhenAttachedAndToggleOn() async {
        let mock = MockPushTransport()
        let sender = PushSender(
            transport: mock,
            attachment: MockAttachment(attached: true),
            config: PushPolicyConfig(skipWhenAttached: true)
        )
        await sender.send(makeEnvelope(), target: .fcm)
        let count = await mock.sentCount
        XCTAssertEqual(count, 0)
    }

    /// not attached → push is sent.
    func testSendsWhenNotAttached() async {
        let mock = MockPushTransport()
        let sender = PushSender(
            transport: mock,
            attachment: MockAttachment(attached: false),
            config: PushPolicyConfig(skipWhenAttached: true)
        )
        await sender.send(makeEnvelope(), target: .fcm)
        let count = await mock.sentCount
        XCTAssertEqual(count, 1)
    }

    /// attached but toggle off → push is sent anyway.
    func testSendsWhenAttachedButToggleOff() async {
        let mock = MockPushTransport()
        let sender = PushSender(
            transport: mock,
            attachment: MockAttachment(attached: true),
            config: PushPolicyConfig(skipWhenAttached: false)
        )
        await sender.send(makeEnvelope(), target: .apns)
        let count = await mock.sentCount
        XCTAssertEqual(count, 1)
    }

    /// oversized payload → rejected before the transport is called;
    /// PUSH_PAYLOAD_TOO_LARGE is recorded on the sender's reject surface.
    func testOversizedPayloadRejectedBeforeTransport() async {
        let mock = MockPushTransport()
        let sender = PushSender(
            transport: mock,
            attachment: MockAttachment(attached: false),
            config: PushPolicyConfig(skipWhenAttached: true)
        )
        await sender.send(
            makeEnvelope(fetchHint: String(repeating: "a", count: 4096)),
            target: .fcm
        )
        let count = await mock.sentCount
        let code = await sender.lastRejectCode
        XCTAssertEqual(count, 0)
        XCTAssertEqual(code, "PUSH_PAYLOAD_TOO_LARGE")
    }
}
