import Foundation
import AnyCodable

/// pane 안에서 실행되는 단일 터미널 세션 단위.
///
/// P3.5 schema v2 에서 도입. v1 Pane.sessionId / Pane.kind 의 위치를 옮긴 모델로
/// 한 pane이 멀티탭 컨테이너가 되도록 한다(REQ-2).
///
/// `sessionId` 는 영속화되지만 다음 부팅 시 `SessionManager` 에 해당 session 이
/// 존재하지 않으므로 UI 는 "세션 없음" 빈 탭으로 표시한다(P2 결정 항목: 자동 respawn 안 함).
/// v1 → v2 migration 은 단일 sessionId 를 단일 Tab 으로 wrap 한다(WorkspaceSchemaMigration 참조).
public struct Tab: Codable, Identifiable, Equatable, @unchecked Sendable {
    public let id: UUID
    public let sessionId: UUID?
    public let kind: PaneKind
    public let name: String
    public let createdAt: Date

    /// M6 forward-compat: 알려지지 않은 top-level 키와 명시적 `extraFields`
    /// 객체를 단일 dict 로 흡수.
    public let extraFields: [String: AnyCodable]?

    public init(
        id: UUID = UUID(),
        sessionId: UUID? = nil,
        kind: PaneKind,
        name: String,
        createdAt: Date = Date(),
        extraFields: [String: AnyCodable]? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.kind = kind
        self.name = name
        self.createdAt = createdAt
        self.extraFields = extraFields
    }

    /// `UUID??` 이중 옵셔널 패턴: nil = 기존 유지, `.some(nil)` = 명시적 clear,
    /// `.some(x)` = 새 값으로 교체. Pane.with / Session.with 와 정합.
    public func with(
        sessionId: UUID?? = nil,
        name: String? = nil
    ) -> Tab {
        Tab(
            id: id,
            sessionId: sessionId ?? self.sessionId,
            kind: kind,
            name: name ?? self.name,
            createdAt: createdAt,
            extraFields: extraFields
        )
    }

    /// kind 별 localized default 이름. "+ 새 탭" / migration wrap 시 사용.
    public static func defaultName(for kind: PaneKind) -> String {
        switch kind {
        case .claude: return "Claude"
        case .shell:  return "셸"
        }
    }

    // MARK: - Codable (forward-compat extraFields catch-all)

    private static let knownKeys: Set<String> = [
        "id", "sessionId", "kind", "name", "createdAt", "extraFields"
    ]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.id = try c.decode(UUID.self, forKey: DynamicCodingKey(stringValue: "id"))
        self.sessionId = try c.decodeIfPresent(UUID.self, forKey: DynamicCodingKey(stringValue: "sessionId"))
        self.kind = try c.decode(PaneKind.self, forKey: DynamicCodingKey(stringValue: "kind"))
        self.name = try c.decode(String.self, forKey: DynamicCodingKey(stringValue: "name"))
        self.createdAt = try c.decode(Date.self, forKey: DynamicCodingKey(stringValue: "createdAt"))

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
        try c.encode(name, forKey: DynamicCodingKey(stringValue: "name"))
        try c.encode(createdAt, forKey: DynamicCodingKey(stringValue: "createdAt"))
        try c.encodeIfPresent(extraFields, forKey: DynamicCodingKey(stringValue: "extraFields"))
    }
}
