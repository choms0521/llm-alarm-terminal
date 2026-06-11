import Foundation

/// One recorded push delivery (test introspection).
public struct SentPush: Sendable, Equatable {
    public let payload: Data
    public let target: PushTarget
    public let sessionId: UUID
}

/// In-memory `PushTransport` for tests: records every delivered payload so a test
/// can assert the send count and inspect what was sent. The real FCM HTTP v1 /
/// APNs HTTP/2 transports replace this at P6/S1 (§7 D1) without touching
/// `PushSender`.
public actor MockPushTransport: PushTransport {
    public private(set) var sent: [SentPush] = []

    public init() {}

    public var sentCount: Int { sent.count }

    public func send(_ payload: Data, target: PushTarget, sessionId: UUID) async {
        sent.append(SentPush(payload: payload, target: target, sessionId: sessionId))
    }
}
