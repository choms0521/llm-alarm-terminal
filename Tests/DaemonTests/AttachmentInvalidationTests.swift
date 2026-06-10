import XCTest
import Foundation

/// Day 5 acceptance: lid-close → invalidate all WS attachments → push fallback.
/// The gating assertion is the result of `invalidateAllAttached()`, not a real
/// `NSWorkspace.willSleep` notification.
final class AttachmentInvalidationTests: XCTestCase {

    /// Invalidation clears all bindings (boundClient → nil) but preserves lastSeq
    /// (clientCount unchanged), so reconnect after wake keeps seq continuity.
    func testInvalidationClearsBindingsPreservesSeq() async {
        let registry = SessionBindRegistry()
        var sessions: [UUID] = []
        for _ in 0..<3 {
            let client = UUID(), session = UUID()
            await registry.register(clientId: client)
            await registry.bind(clientId: client, sessionId: session)
            sessions.append(session)
        }
        let before = await registry.clientCount
        XCTAssertEqual(before, 3)

        await AttachmentInvalidator(registry: registry).invalidateAllAttached()

        for session in sessions {
            let bound = await registry.boundClient(forSession: session)
            XCTAssertNil(bound)
        }
        let after = await registry.clientCount
        XCTAssertEqual(after, 3)   // lastSeq preserved
    }

    /// Integration: attached → push skipped (0); after invalidation → push sent (1)
    /// through the same authoritative source the skip policy queries.
    func testPushFallbackAfterInvalidation() async {
        let registry = SessionBindRegistry()
        let client = UUID(), session = UUID()
        await registry.register(clientId: client)
        await registry.bind(clientId: client, sessionId: session)

        let mock = MockPushTransport()
        let sender = PushSender(
            transport: mock,
            attachment: BindRegistryAttachment(registry: registry),
            config: PushPolicyConfig(skipWhenAttached: true)
        )
        let env = makeEnvelope(sessionId: session)

        await sender.send(env, target: .fcm)
        let skipped = await mock.sentCount
        XCTAssertEqual(skipped, 0)   // attached → skip

        await AttachmentInvalidator(registry: registry).invalidateAllAttached()
        await sender.send(env, target: .fcm)
        let afterInvalidate = await mock.sentCount
        XCTAssertEqual(afterInvalidate, 1)   // not attached → push sent
    }

    private func makeEnvelope(sessionId: UUID) -> PushEnvelope {
        PushEnvelope(
            sessionId: sessionId,
            messageId: UUID(),
            preview: "메시지",
            chatRoomId: sessionId.uuidString,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            fetchHint: nil
        )
    }
}
