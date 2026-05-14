import Foundation
import AnyCodable

/// 카드 정렬 방식 4종.
///
/// - `lastActivityAtDesc`: 최근 활동 우선 (default).
/// - `lastActivityAtAsc`: 오래된 활동 우선.
/// - `workspaceName`: workspace 이름 알파벳 / 한국어 순.
/// - `statusFirst`: needsInput → working → idle → exited 우선 정렬.
public enum AgentSortOrder: String, Codable, CaseIterable, Sendable {
    case lastActivityAtDesc
    case lastActivityAtAsc
    case workspaceName
    case statusFirst
}

/// 카드 필터 옵션 4종.
public enum AgentFilterOption: String, Codable, CaseIterable, Sendable {
    case all
    case needsInput
    case working
    case claudeOnly
}

/// agent-view 영구 설정. agent-view workspace 의 `extraFields["agentView.settings"]`
/// 에 JSON 인코딩되어 보관된다. 부팅 시 `WorkspaceManager.loadAgentViewSettings()`
/// 가 복원하고, 변경 시 `WorkspaceManager.updateAgentViewSettings(_:)` 가 persist.
public struct AgentViewSettings: Codable, Equatable, Sendable {
    public var sortOrder: AgentSortOrder
    public var filter: AgentFilterOption

    public init(sortOrder: AgentSortOrder = .lastActivityAtDesc, filter: AgentFilterOption = .all) {
        self.sortOrder = sortOrder
        self.filter = filter
    }

    /// extraFields 직렬화 안에서 사용하는 key.
    public static let extraFieldKey: String = "agentView.settings"

    /// AnyCodable 로 wrap 된 dict 에서 settings 를 디코딩한다. 누락/decode 실패 시 default 반환.
    public static func decode(from extraFields: [String: AnyCodable]?) -> AgentViewSettings {
        guard let extra = extraFields,
              let any = extra[Self.extraFieldKey] else {
            return AgentViewSettings()
        }
        do {
            let data = try JSONEncoder().encode(any)
            return try JSONDecoder().decode(AgentViewSettings.self, from: data)
        } catch {
            return AgentViewSettings()
        }
    }

    /// 기존 extraFields 에 settings 를 merge 하여 새 dict 반환.
    public func encoded(merging existing: [String: AnyCodable]?) -> [String: AnyCodable] {
        var merged = existing ?? [:]
        if let data = try? JSONEncoder().encode(self),
           let any = try? JSONDecoder().decode(AnyCodable.self, from: data) {
            merged[Self.extraFieldKey] = any
        }
        return merged
    }
}
