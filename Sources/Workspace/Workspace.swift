import Foundation
import AnyCodable

/// 워크스페이스의 종류.
///
/// - `agentView`: 영구적 첫 탭. close UI 비노출(`canClose == false`).
/// - `normal`: 사용자 정의 작업 탭. close 가능.
public enum WorkspaceKind: String, Codable, Sendable, Equatable {
    case agentView
    case normal
}

/// 영속화 가능한 워크스페이스 모델.
///
/// 모든 저장 프로퍼티는 `let` 이며 수정은 `with(...)` 빌더가 새 인스턴스를 반환한다.
/// `@unchecked Sendable`: 모든 프로퍼티가 immutable 이며 `AnyCodable` 내부 `Any` 도
/// 외부 mutation 경로가 노출되지 않는다(생성 후 변경 불가).
public struct Workspace: Codable, Identifiable, Equatable, @unchecked Sendable {
    public let id: UUID
    public let name: String
    public let cwd: String
    public let panes: [Pane]
    public let createdAt: Date
    public let kind: WorkspaceKind

    /// H6: workspace 생성 시점에 capture된 user env snapshot.
    /// 같은 workspace 의 모든 pane spawn 에 base 로 사용. workspace 생성 후
    /// user shell rc 변경이 후속 pane 에 전파되지 않게 하는 격리 anchor.
    public let envSnapshot: [String: String]

    /// P5 push channel mapping (예: `{"fcmDeviceId":...,"apnsDeviceToken":...}`).
    /// P2 에서는 nil.
    public let pushChannelHints: [String: String]?

    /// P10b fetchHint resolver metadata. P2 에서는 nil.
    public let fetchHintMetadata: [String: AnyCodable]?

    /// M6 forward-compat: 디코딩 시 알려지지 않은 top-level 필드와 명시적
    /// `extraFields` 객체 모두를 이 곳에 흡수하여 다음 인코딩 시 보존한다.
    public let extraFields: [String: AnyCodable]?

    public var canClose: Bool { kind == .normal }

    public init(
        id: UUID = UUID(),
        name: String,
        cwd: String,
        panes: [Pane] = [],
        createdAt: Date = Date(),
        kind: WorkspaceKind,
        envSnapshot: [String: String] = [:],
        pushChannelHints: [String: String]? = nil,
        fetchHintMetadata: [String: AnyCodable]? = nil,
        extraFields: [String: AnyCodable]? = nil
    ) {
        self.id = id
        self.name = name
        self.cwd = cwd
        self.panes = panes
        self.createdAt = createdAt
        self.kind = kind
        self.envSnapshot = envSnapshot
        self.pushChannelHints = pushChannelHints
        self.fetchHintMetadata = fetchHintMetadata
        self.extraFields = extraFields
    }

    /// 변경하지 않는 필드는 self 값을 그대로 복사하는 immutable builder.
    public func with(
        name: String? = nil,
        cwd: String? = nil,
        panes: [Pane]? = nil
    ) -> Workspace {
        Workspace(
            id: id,
            name: name ?? self.name,
            cwd: cwd ?? self.cwd,
            panes: panes ?? self.panes,
            createdAt: createdAt,
            kind: kind,
            envSnapshot: envSnapshot,
            pushChannelHints: pushChannelHints,
            fetchHintMetadata: fetchHintMetadata,
            extraFields: extraFields
        )
    }

    /// agent-view 영구 첫 탭의 기본 인스턴스.
    /// cwd 는 빈 문자열, panes 는 빈 배열, envSnapshot 도 빈 dict.
    public static func makeAgentView(
        id: UUID = UUID(),
        name: String = "에이전트 뷰",
        createdAt: Date = Date()
    ) -> Workspace {
        Workspace(
            id: id,
            name: name,
            cwd: "",
            panes: [],
            createdAt: createdAt,
            kind: .agentView,
            envSnapshot: [:]
        )
    }

    // MARK: - Codable (forward-compat extraFields catch-all)

    /// 알려진 top-level 키. 디코딩 루프가 이 집합 외 키만 `extraFields` 로 수집한다.
    private static let knownKeys: Set<String> = [
        "id", "name", "cwd", "panes", "createdAt", "kind",
        "envSnapshot", "pushChannelHints", "fetchHintMetadata", "extraFields"
    ]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.id = try c.decode(UUID.self, forKey: DynamicCodingKey(stringValue: "id"))
        self.name = try c.decode(String.self, forKey: DynamicCodingKey(stringValue: "name"))
        self.cwd = try c.decode(String.self, forKey: DynamicCodingKey(stringValue: "cwd"))
        self.panes = try c.decodeIfPresent([Pane].self, forKey: DynamicCodingKey(stringValue: "panes")) ?? []
        self.createdAt = try c.decode(Date.self, forKey: DynamicCodingKey(stringValue: "createdAt"))
        self.kind = try c.decode(WorkspaceKind.self, forKey: DynamicCodingKey(stringValue: "kind"))
        self.envSnapshot = try c.decodeIfPresent([String: String].self, forKey: DynamicCodingKey(stringValue: "envSnapshot")) ?? [:]
        self.pushChannelHints = try c.decodeIfPresent([String: String].self, forKey: DynamicCodingKey(stringValue: "pushChannelHints"))
        self.fetchHintMetadata = try c.decodeIfPresent([String: AnyCodable].self, forKey: DynamicCodingKey(stringValue: "fetchHintMetadata"))

        // M6: 기존 extraFields 객체와 top-level unknown 키 모두를 단일 dict 로 흡수.
        var extra: [String: AnyCodable] = (try c.decodeIfPresent([String: AnyCodable].self, forKey: DynamicCodingKey(stringValue: "extraFields"))) ?? [:]
        for key in c.allKeys where !Self.knownKeys.contains(key.stringValue) {
            extra[key.stringValue] = try c.decode(AnyCodable.self, forKey: key)
        }
        self.extraFields = extra.isEmpty ? nil : extra
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicCodingKey.self)
        try c.encode(id, forKey: DynamicCodingKey(stringValue: "id"))
        try c.encode(name, forKey: DynamicCodingKey(stringValue: "name"))
        try c.encode(cwd, forKey: DynamicCodingKey(stringValue: "cwd"))
        try c.encode(panes, forKey: DynamicCodingKey(stringValue: "panes"))
        try c.encode(createdAt, forKey: DynamicCodingKey(stringValue: "createdAt"))
        try c.encode(kind, forKey: DynamicCodingKey(stringValue: "kind"))
        try c.encode(envSnapshot, forKey: DynamicCodingKey(stringValue: "envSnapshot"))
        try c.encodeIfPresent(pushChannelHints, forKey: DynamicCodingKey(stringValue: "pushChannelHints"))
        try c.encodeIfPresent(fetchHintMetadata, forKey: DynamicCodingKey(stringValue: "fetchHintMetadata"))
        try c.encodeIfPresent(extraFields, forKey: DynamicCodingKey(stringValue: "extraFields"))
    }
}
