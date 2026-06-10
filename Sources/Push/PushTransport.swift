import Foundation

/// Delivery target for a push payload. P5 ships a single `MockPushTransport`
/// behind `PushTransport`; the real FCM HTTP v1 (Android) and APNs HTTP/2 (iOS)
/// transports swap in at P6/S1 without touching `PushSender` (§7 D1).
public enum PushTarget: Sendable, Equatable {
    case fcm
    case apns
}

/// Transport seam for sending an already-encoded push payload. Keeping the wire
/// call behind this protocol isolates the real FCM/APNs integration to a single
/// new conformer, so `PushSender`'s policy logic stays transport-agnostic and
/// unit-testable against a mock.
public protocol PushTransport: Sendable {
    func send(_ payload: Data, target: PushTarget, sessionId: UUID) async
}
