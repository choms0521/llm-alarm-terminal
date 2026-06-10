import Foundation

/// Push envelope v0.9 (frozen at P7). Deliberately separate from the WS wire
/// model: push carries a 4KB-bounded preview and a `chatRoomId` that the WS
/// protocol has no notion of, so the two stay distinct wire models.
public struct PushEnvelope: Codable, Equatable, Sendable {
    public let sessionId: UUID
    public let messageId: UUID
    /// ≤200 characters, cut on a grapheme (message) boundary by `PreviewBuilder`.
    public let preview: String
    /// Reserved: no mapping source exists yet, so P5 uses `sessionId` as a
    /// placeholder value; the real chat-room mapping is deferred to the pairing
    /// phase.
    public let chatRoomId: String
    public let timestamp: Date
    public let fetchHint: String?

    public init(
        sessionId: UUID,
        messageId: UUID,
        preview: String,
        chatRoomId: String,
        timestamp: Date,
        fetchHint: String?
    ) {
        self.sessionId = sessionId
        self.messageId = messageId
        self.preview = preview
        self.chatRoomId = chatRoomId
        self.timestamp = timestamp
        self.fetchHint = fetchHint
    }
}

/// Push-path error surfaced as an explicit rejection (never a silent drop).
public enum PushError: Error, Equatable {
    case payloadTooLarge

    public var code: String {
        switch self {
        case .payloadTooLarge: return "PUSH_PAYLOAD_TOO_LARGE"
        }
    }
}
