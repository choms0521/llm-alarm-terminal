import Foundation
import AnyCodable

/// schema v1 (P2 stamp) 의 read-only decoder.
///
/// P3.5 schema v2 로 migration 하기 위해서만 존재. 일반 production read/write 경로는
/// `Workspace` / `Pane` (v2) 가 담당하며, 이 enum 은 `WorkspaceSchemaMigration` 에서만
/// 사용한다. v1 → v2 migration 이 끝나면 v1 파일은 별도 backup 으로 보관되고 main
/// `workspaces.json` 은 v2 stamp(version: 2) 로 잠긴다.
///
/// v1 모델 (P2 시점 그대로):
/// - `WorkspaceFile.version: Int = 1`
/// - `Workspace`: id, name, cwd, panes, createdAt, kind, envSnapshot, pushChannelHints, fetchHintMetadata, extraFields
/// - `Pane`: id, sessionId, kind, position("top"|"bottom"), chatRoomId, extraFields
internal enum WorkspaceSchemaV1 {

    /// v1 Pane 의 read-only decoder. v2 Pane 과 필드가 호환되지 않으므로 별도 struct.
    internal struct V1Pane: Decodable {
        let id: UUID
        let sessionId: UUID?
        let kind: PaneKind
        let position: String          // "top" | "bottom"
        let chatRoomId: String?
        let extraFields: [String: AnyCodable]?

        private static let knownKeys: Set<String> = [
            "id", "sessionId", "kind", "position", "chatRoomId", "extraFields"
        ]

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: DynamicCodingKey.self)
            self.id = try c.decode(UUID.self, forKey: DynamicCodingKey(stringValue: "id"))
            self.sessionId = try c.decodeIfPresent(UUID.self, forKey: DynamicCodingKey(stringValue: "sessionId"))
            self.kind = try c.decode(PaneKind.self, forKey: DynamicCodingKey(stringValue: "kind"))
            self.position = try c.decode(String.self, forKey: DynamicCodingKey(stringValue: "position"))
            self.chatRoomId = try c.decodeIfPresent(String.self, forKey: DynamicCodingKey(stringValue: "chatRoomId"))

            var extra: [String: AnyCodable] = (try c.decodeIfPresent([String: AnyCodable].self, forKey: DynamicCodingKey(stringValue: "extraFields"))) ?? [:]
            for key in c.allKeys where !Self.knownKeys.contains(key.stringValue) {
                extra[key.stringValue] = try c.decode(AnyCodable.self, forKey: key)
            }
            self.extraFields = extra.isEmpty ? nil : extra
        }
    }

    /// v1 Workspace 의 read-only decoder. envSnapshot / pushChannelHints / fetchHintMetadata 는
    /// v2 와 같은 형식이므로 그대로 carry over 한다.
    internal struct V1Workspace: Decodable {
        let id: UUID
        let name: String
        let cwd: String
        let panes: [V1Pane]
        let createdAt: Date
        let kind: WorkspaceKind
        let envSnapshot: [String: String]
        let pushChannelHints: [String: String]?
        let fetchHintMetadata: [String: AnyCodable]?
        let extraFields: [String: AnyCodable]?

        private static let knownKeys: Set<String> = [
            "id", "name", "cwd", "panes", "createdAt", "kind",
            "envSnapshot", "pushChannelHints", "fetchHintMetadata", "extraFields"
        ]

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: DynamicCodingKey.self)
            self.id = try c.decode(UUID.self, forKey: DynamicCodingKey(stringValue: "id"))
            self.name = try c.decode(String.self, forKey: DynamicCodingKey(stringValue: "name"))
            self.cwd = try c.decode(String.self, forKey: DynamicCodingKey(stringValue: "cwd"))
            self.panes = try c.decodeIfPresent([V1Pane].self, forKey: DynamicCodingKey(stringValue: "panes")) ?? []
            self.createdAt = try c.decode(Date.self, forKey: DynamicCodingKey(stringValue: "createdAt"))
            self.kind = try c.decode(WorkspaceKind.self, forKey: DynamicCodingKey(stringValue: "kind"))
            self.envSnapshot = try c.decodeIfPresent([String: String].self, forKey: DynamicCodingKey(stringValue: "envSnapshot")) ?? [:]
            self.pushChannelHints = try c.decodeIfPresent([String: String].self, forKey: DynamicCodingKey(stringValue: "pushChannelHints"))
            self.fetchHintMetadata = try c.decodeIfPresent([String: AnyCodable].self, forKey: DynamicCodingKey(stringValue: "fetchHintMetadata"))

            var extra: [String: AnyCodable] = (try c.decodeIfPresent([String: AnyCodable].self, forKey: DynamicCodingKey(stringValue: "extraFields"))) ?? [:]
            for key in c.allKeys where !Self.knownKeys.contains(key.stringValue) {
                extra[key.stringValue] = try c.decode(AnyCodable.self, forKey: key)
            }
            self.extraFields = extra.isEmpty ? nil : extra
        }
    }

    /// v1 file root. v1 에서는 version 필드가 1 이거나 미존재(P2 이전 stamp)이다.
    internal struct V1WorkspaceFile: Decodable {
        let version: Int?
        let workspaces: [V1Workspace]
        let lastActiveWorkspaceId: UUID?
    }

    /// v1 파일 판정. version 필드가 미존재 또는 < 2 이면 v1 으로 본다.
    /// Pane.position 검사는 일부 v1 파일이 빈 panes 를 가질 수도 있으므로 보조 기준으로만 사용.
    internal static func isV1(data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        if let version = json["version"] as? Int {
            return version < 2
        }
        // version 필드 미존재 = pre-P2 또는 손상. v1 으로 본다.
        return true
    }

    /// v1 파일 디코드. 호출 전 `isV1` 검증을 권장.
    internal static func decode(data: Data) throws -> V1WorkspaceFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(V1WorkspaceFile.self, from: data)
    }
}
