import Foundation
import AnyCodable

/// pane 의 화면상 위치. 2-pane horizontal split 의 좌/우 배치를 기술한다.
///
/// P3.5 schema v2 에서 .top/.bottom → .left/.right 로 전환됨(REQ-1).
/// 분할 layout 도 VStack → HStack 으로 함께 전환된다.
public enum PanePosition: String, Codable, Sendable, Equatable {
    case left
    case right
}

/// pane 내부에서 실행되는 프로세스 종류.
///
/// P3.5 schema v2 에서 위치는 Pane 이 아닌 Tab.kind 로 이동. 이 enum 자체는
/// Tab 이 그대로 사용한다.
public enum PaneKind: String, Codable, Sendable, Equatable {
    case claude
    case shell
}

/// 한 워크스페이스 내부의 단일 pane(멀티탭 컨테이너).
///
/// P3.5 schema v2: pane 은 더 이상 단일 sessionId/kind 를 갖지 않고 `tabs: [Tab]`
/// + `activeTabId: UUID?` 의 멀티탭 컨테이너로 동작한다(REQ-2). v1 의 단일
/// sessionId/kind 는 migration 시 단일 Tab 으로 wrap 된다.
/// `chatRoomId` 는 master § P9 line 351 "채팅룸은 데스크톱의 특정 pane 에
/// 1:1 바인딩" 명세를 따라 pane level 에 위치한다(P2 v2 H1 결정).
public struct Pane: Codable, Identifiable, Equatable, @unchecked Sendable {
    public let id: UUID
    public let position: PanePosition
    public let tabs: [Tab]
    public let activeTabId: UUID?

    /// P6a/P9 reserved field. master § P9 line 351 의 1:1 바인딩 명세에 따라
    /// workspace 가 아닌 pane level 에 위치(P2 v2 H1 결정 항목). P2 에서는 nil.
    public let chatRoomId: String?

    /// M6 forward-compat: 알려지지 않은 top-level 키와 명시적 `extraFields`
    /// 객체를 단일 dict 로 흡수.
    public let extraFields: [String: AnyCodable]?

    public init(
        id: UUID = UUID(),
        position: PanePosition,
        tabs: [Tab] = [],
        activeTabId: UUID? = nil,
        chatRoomId: String? = nil,
        extraFields: [String: AnyCodable]? = nil
    ) {
        self.id = id
        self.position = position
        self.tabs = tabs
        self.activeTabId = activeTabId
        self.chatRoomId = chatRoomId
        self.extraFields = extraFields
    }

    /// activeTabId 가 가리키는 Tab. 없으면 첫 Tab 을 fallback (UI 가 빈 상태로 죽지 않도록).
    /// tabs 가 비어 있으면 nil.
    public var activeTab: Tab? {
        if let id = activeTabId, let t = tabs.first(where: { $0.id == id }) {
            return t
        }
        return tabs.first
    }

    /// `UUID??` 이중 옵셔널 패턴: nil = 기존 유지, `.some(nil)` = 명시적 clear,
    /// `.some(x)` = 새 값으로 교체. P1 `Session.with(...)` 패턴과 정합.
    public func with(
        tabs: [Tab]? = nil,
        activeTabId: UUID?? = nil,
        chatRoomId: String?? = nil
    ) -> Pane {
        Pane(
            id: id,
            position: position,
            tabs: tabs ?? self.tabs,
            activeTabId: activeTabId ?? self.activeTabId,
            chatRoomId: chatRoomId ?? self.chatRoomId,
            extraFields: extraFields
        )
    }

    // MARK: - Codable (forward-compat extraFields catch-all)

    private static let knownKeys: Set<String> = [
        "id", "position", "tabs", "activeTabId", "chatRoomId", "extraFields"
    ]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.id = try c.decode(UUID.self, forKey: DynamicCodingKey(stringValue: "id"))
        self.position = try c.decode(PanePosition.self, forKey: DynamicCodingKey(stringValue: "position"))
        self.tabs = try c.decodeIfPresent([Tab].self, forKey: DynamicCodingKey(stringValue: "tabs")) ?? []
        self.activeTabId = try c.decodeIfPresent(UUID.self, forKey: DynamicCodingKey(stringValue: "activeTabId"))
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
        try c.encode(position, forKey: DynamicCodingKey(stringValue: "position"))
        try c.encode(tabs, forKey: DynamicCodingKey(stringValue: "tabs"))
        try c.encodeIfPresent(activeTabId, forKey: DynamicCodingKey(stringValue: "activeTabId"))
        try c.encodeIfPresent(chatRoomId, forKey: DynamicCodingKey(stringValue: "chatRoomId"))
        try c.encodeIfPresent(extraFields, forKey: DynamicCodingKey(stringValue: "extraFields"))
    }
}
