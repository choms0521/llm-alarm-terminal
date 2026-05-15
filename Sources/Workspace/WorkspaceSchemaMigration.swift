import Foundation

/// `workspaces.json` v1 → v2 backward-compat migration.
///
/// 부팅 시 `WorkspaceStore.load()` 진입 직전에 1회 실행한다. v1 감지 시 v1 원본을
/// 별도 backup 파일로 보존하고 main 파일을 v2 schema 로 overwrite 한다. v2 파일에
/// 호출 시 idempotent no-op.
///
/// **backup 파일명 명명 규약**: `workspaces.json.v1-pre-migration-<ISO8601>`.
/// P2 atomic write 의 `.bak` 은 "직전 정상본" 의미로 이미 사용 중이므로 의미 분리
/// 위해 별도 명명. migration backup 은 영속 보존이 목적(사용자가 직접 삭제해야 사라짐).
///
/// **invariant**: backup copy 가 먼저 성공해야 v2 overwrite 진행. backup 실패 시
/// abort + 원본 v1 파일 보존 + 한국어 다이얼로그 표시 위임.
public enum WorkspaceSchemaMigration {

    /// migration 결과.
    public enum Result: Equatable {
        /// v1 감지되지 않음(이미 v2 또는 파일 부재). no-op.
        case noMigrationNeeded
        /// v1 → v2 변환 성공. backup 파일이 생성됨.
        case migrated(backupURL: URL)
        /// v1 감지됐으나 backup 생성 실패. 원본 v1 파일 보존됨.
        case aborted(backupFailure: String)
    }

    /// 부팅 시 1회 실행. 호출부는 결과에 따라 한국어 다이얼로그를 표시한다.
    public static func migrateIfNeeded(at url: URL, now: Date = Date()) throws -> Result {
        // 파일 부재면 no-op (첫 부팅 시나리오, WorkspaceStore.load 가 빈 file 반환).
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .noMigrationNeeded
        }

        let data = try Data(contentsOf: url)

        // v1 detection: version field 부재 또는 < 2.
        guard WorkspaceSchemaV1.isV1(data: data) else {
            return .noMigrationNeeded
        }

        // 1. v1 decode.
        let v1File = try WorkspaceSchemaV1.decode(data: data)

        // 2. v1 → v2 convert.
        let v2Workspaces = convert(v1Workspaces: v1File.workspaces, now: now)
        let v2File = WorkspaceFile(
            version: 2,
            workspaces: v2Workspaces,
            lastActiveWorkspaceId: v1File.lastActiveWorkspaceId
        )

        // 3. backup 파일 생성 (실패 시 abort + 원본 v1 보존).
        let backupURL = backupFileURL(for: url, at: now)
        do {
            try FileManager.default.copyItem(at: url, to: backupURL)
        } catch {
            return .aborted(backupFailure: error.localizedDescription)
        }

        // 4. v2 stamp 로 overwrite.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let v2Data = try encoder.encode(v2File)
        try v2Data.write(to: url, options: [.atomic])

        return .migrated(backupURL: backupURL)
    }

    /// v1 panes 를 v2 panes 로 변환. v1 의 단일 sessionId 는 단일 Tab 으로 wrap된다.
    /// "top" → .left, "bottom" → .right 1:1 매핑.
    /// 알 수 없는 position 값은 .left fallback (defensive — production 에서는 발생하지 않을 케이스).
    internal static func convert(v1Workspaces: [WorkspaceSchemaV1.V1Workspace], now: Date) -> [Workspace] {
        v1Workspaces.map { v1Ws in
            let v2Panes: [Pane] = v1Ws.panes.map { v1Pane in
                let position: PanePosition = (v1Pane.position == "bottom") ? .right : .left
                let tab = Tab(
                    id: UUID(),
                    sessionId: v1Pane.sessionId,
                    kind: v1Pane.kind,
                    name: Tab.defaultName(for: v1Pane.kind),
                    createdAt: now
                )
                return Pane(
                    id: v1Pane.id,
                    position: position,
                    tabs: [tab],
                    activeTabId: tab.id,
                    chatRoomId: v1Pane.chatRoomId,
                    extraFields: v1Pane.extraFields
                )
            }
            return Workspace(
                id: v1Ws.id,
                name: v1Ws.name,
                cwd: v1Ws.cwd,
                panes: v2Panes,
                createdAt: v1Ws.createdAt,
                kind: v1Ws.kind,
                envSnapshot: v1Ws.envSnapshot,
                pushChannelHints: v1Ws.pushChannelHints,
                fetchHintMetadata: v1Ws.fetchHintMetadata,
                extraFields: v1Ws.extraFields
            )
        }
    }

    /// backup 파일 URL 생성. main URL 과 같은 디렉터리에 위치하며 timestamp suffix 포함.
    internal static func backupFileURL(for mainURL: URL, at now: Date) -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        // ":" 가 파일 시스템에서 호환되지 않을 수 있으므로 "-" 로 치환.
        let timestamp = formatter.string(from: now).replacingOccurrences(of: ":", with: "-")
        return mainURL.deletingLastPathComponent()
            .appendingPathComponent("workspaces.json.v1-pre-migration-\(timestamp)")
    }
}
