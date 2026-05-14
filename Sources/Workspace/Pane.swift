import Foundation
import AnyCodable

/// pane 의 화면상 위치. 2-pane horizontal split 의 상/하 배치를 기술한다.
public enum PanePosition: String, Codable, Sendable, Equatable {
    case top
    case bottom
}

/// pane 내부에서 실행되는 프로세스 종류.
public enum PaneKind: String, Codable, Sendable, Equatable {
    case claude
    case shell
}

/// 한 워크스페이스 내부의 단일 pane(터미널 영역).
///
/// `sessionId` 는 영속화되지만 다음 부팅 시 `SessionManager` 에 해당 session 이
/// 존재하지 않으므로 UI 는 "세션 없음" 빈 pane 으로 표시한다(P2 결정 항목:
/// 자동 respawn 안 함).
/// `chatRoomId` 는 master § P9 line 351 "채팅룸은 데스크톱의 특정 pane 에
/// 1:1 바인딩" 명세를 따라 pane level 에 위치한다(P2 v2 H1 결정).
public struct Pane: Codable, Identifiable, Equatable, @unchecked Sendable {
    public let id: UUID
    public let sessionId: UUID?
    public let kind: PaneKind
    public let position: PanePosition

    /// P6a/P9 reserved field. master § P9 line 351 의 1:1 바인딩 명세에 따라
    /// workspace 가 아닌 pane level 에 위치(P2 v2 H1 결정 항목). P2 에서는 nil.
    public let chatRoomId: String?

    /// M6 forward-compat: 알려지지 않은 top-level 키와 명시적 `extraFields`
    /// 객체를 단일 dict 로 흡수.
    public let extraFields: [String: AnyCodable]?

    public init(
        id: UUID = UUID(),
        sessionId: UUID? = nil,
        kind: PaneKind,
        position: PanePosition,
        chatRoomId: String? = nil,
        extraFields: [String: AnyCodable]? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.kind = kind
        self.position = position
        self.chatRoomId = chatRoomId
        self.extraFields = extraFields
    }

    /// `UUID??` 이중 옵셔널 패턴: nil = 기존 유지, `.some(nil)` = 명시적 clear,
    /// `.some(x)` = 새 값으로 교체. P1 `Session.with(...)` 패턴과 정합.
    public func with(
        sessionId: UUID?? = nil,
        chatRoomId: String?? = nil
    ) -> Pane {
        Pane(
            id: id,
            sessionId: sessionId ?? self.sessionId,
            kind: kind,
            position: position,
            chatRoomId: chatRoomId ?? self.chatRoomId,
            extraFields: extraFields
        )
    }

    // MARK: - Codable (forward-compat extraFields catch-all)

    private static let knownKeys: Set<String> = [
        "id", "sessionId", "kind", "position", "chatRoomId", "extraFields"
    ]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.id = try c.decode(UUID.self, forKey: DynamicCodingKey(stringValue: "id"))
        self.sessionId = try c.decodeIfPresent(UUID.self, forKey: DynamicCodingKey(stringValue: "sessionId"))
        self.kind = try c.decode(PaneKind.self, forKey: DynamicCodingKey(stringValue: "kind"))
        self.position = try c.decode(PanePosition.self, forKey: DynamicCodingKey(stringValue: "position"))
        self.chatRoomId = try c.decodeIfPresent(String.self, forKey: DynamicCodingKey(stringValue: "chatRoomId"))

        var extra: [String: AnyCodable] = (try c.decodeIfPresent([String: AnyCodable].self, forKey: DynamicCodingKey(stringValue: "extraFields"))) ?? [:]
        for key in c.allKeys where !Self.knownKeys.contains(key.stringValue) {
            extra[key.stringValue] = try c.decode(AnyCodable.self, forKey: key)
        }
        self.extraFields = extra.isEmpty ? nil : extra
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode(id, forKey: DynamicCodingKey(stringValue: "id"))
        try c.encodeIfPresent(sessionId, forKey: DynamicCodingKey(stringValue: "sessionId"))
        try c.encode(kind, forKey: DynamicCodingKey(stringValue: "kind"))
        try c.encode(position, forKey: DynamicCodingKey(stringValue: "position"))
        try c.encodeIfPresent(chatRoomId, forKey: DynamicCodingKey(stringValue: "chatRoomId"))
        try c.encodeIfPresent(extraFields, forKey: DynamicCodingKey(stringValue: "extraFields"))
    }
}
