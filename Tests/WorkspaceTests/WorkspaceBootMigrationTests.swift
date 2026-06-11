import XCTest
import Foundation

/// P3.5 Day 3 (종료조건 #7): 부팅 시 v1 → v2 migration 배선 통합 검증.
///
/// AppDelegate.applicationDidFinishLaunching 이 수행하는 시퀀스
/// (`WorkspaceSchemaMigration.migrateIfNeeded(at: store.fileURL)` → `WorkspaceManager(store:)`)
/// 를 그대로 재현하여, v1 파일이 부팅 경로에서 v2 로 변환되고 manager 가 좌/우 + 단일 탭으로
/// 로드하는지 확인한다. (단위 migrate 로직은 WorkspaceSchemaMigrationTests 가 별도로 커버.)
@MainActor
final class WorkspaceBootMigrationTests: XCTestCase {

    func test_boot_v1File_migratesToV2_andManagerLoadsLeftRightTabs() throws {
        let url = try seed(json: v1TwoPane)

        // AppDelegate 부팅 시퀀스 재현 1: migration.
        let result = try WorkspaceSchemaMigration.migrateIfNeeded(at: url)
        guard case .migrated(let backupURL) = result else {
            return XCTFail("v1 파일이 .migrated 를 반환해야 함, 실제: \(result)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path),
                      "migration backup 파일 생성")
        XCTAssertTrue(backupURL.lastPathComponent.hasPrefix("workspaces.json.v1-pre-migration-"),
                      "backup 명명 규약 (.bak 아님)")

        // AppDelegate 부팅 시퀀스 재현 2: store + manager 로 v2 로드.
        let store = try WorkspaceStore(fileURL: url)
        let manager = WorkspaceManager(store: store)

        let migrated = manager.workspaces.first(where: { $0.name == "마이그레이션 시연" })
        XCTAssertNotNil(migrated, "변환된 normal workspace 로드됨")
        let left = migrated?.panes.first(where: { $0.position == .left })
        let right = migrated?.panes.first(where: { $0.position == .right })
        XCTAssertEqual(left?.tabs.count, 1, "top → .left, 단일 sessionId → 단일 Tab")
        XCTAssertEqual(left?.tabs.first?.kind, .claude)
        XCTAssertEqual(right?.tabs.count, 1, "bottom → .right, 단일 Tab")
        XCTAssertEqual(right?.tabs.first?.kind, .shell)
    }

    func test_boot_v2File_noMigration_loadsNormally() throws {
        let url = try seed(json: v2Empty)
        let result = try WorkspaceSchemaMigration.migrateIfNeeded(at: url)
        XCTAssertEqual(result, .noMigrationNeeded, "v2 파일은 migration no-op")

        let store = try WorkspaceStore(fileURL: url)
        let manager = WorkspaceManager(store: store)
        // agent-view invariant 유지 + 부팅 정상.
        XCTAssertEqual(manager.workspaces.filter { $0.kind == .agentView }.count, 1)
    }

    // MARK: - Helpers

    private func seed(json: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BootMigrationTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("workspaces.json")
        try json.data(using: .utf8)!.write(to: url)
        return url
    }

    private let v1TwoPane = #"""
    {
      "version": 1,
      "lastActiveWorkspaceId": "a1111111-1111-1111-1111-111111111111",
      "workspaces": [
        {
          "id": "a1111111-1111-1111-1111-111111111111",
          "name": "마이그레이션 시연",
          "cwd": "/tmp/migration-demo",
          "panes": [
            { "id": "b2222222-2222-2222-2222-222222222222", "sessionId": "c3333333-3333-3333-3333-333333333333", "kind": "claude", "position": "top", "chatRoomId": null },
            { "id": "d4444444-4444-4444-4444-444444444444", "sessionId": null, "kind": "shell", "position": "bottom", "chatRoomId": null }
          ],
          "createdAt": "2026-05-15T00:00:00Z",
          "kind": "normal",
          "envSnapshot": {},
          "pushChannelHints": null,
          "fetchHintMetadata": null,
          "extraFields": null
        }
      ]
    }
    """#

    private let v2Empty = #"""
    {"version":2,"workspaces":[],"lastActiveWorkspaceId":null}
    """#
}
