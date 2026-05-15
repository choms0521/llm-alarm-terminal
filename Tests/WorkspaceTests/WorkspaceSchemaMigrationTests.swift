import XCTest
import Foundation

/// P3.5 Day 2 — schema v1 → v2 migration 단위 테스트.
final class WorkspaceSchemaMigrationTests: XCTestCase {

    private let fixedDate = Date(timeIntervalSince1970: 1_778_716_800)

    // MARK: - v1 detection

    func test_isV1_versionField1_returnsTrue() throws {
        let data = #"""
        {"version":1,"workspaces":[],"lastActiveWorkspaceId":null}
        """#.data(using: .utf8)!
        XCTAssertTrue(WorkspaceSchemaV1.isV1(data: data))
    }

    func test_isV1_versionField2_returnsFalse() throws {
        let data = #"""
        {"version":2,"workspaces":[],"lastActiveWorkspaceId":null}
        """#.data(using: .utf8)!
        XCTAssertFalse(WorkspaceSchemaV1.isV1(data: data))
    }

    func test_isV1_missingVersionField_returnsTrue() throws {
        let data = #"""
        {"workspaces":[],"lastActiveWorkspaceId":null}
        """#.data(using: .utf8)!
        XCTAssertTrue(WorkspaceSchemaV1.isV1(data: data), "pre-stamp 파일은 v1 으로 본다")
    }

    // MARK: - migrateIfNeeded — 기본 사용

    func test_migrateIfNeeded_v2File_returnsNoMigrationNeeded() throws {
        let (dir, url) = try makeTempFile(content: #"""
        {"version":2,"workspaces":[],"lastActiveWorkspaceId":null}
        """#)
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = try WorkspaceSchemaMigration.migrateIfNeeded(at: url, now: fixedDate)
        if case .noMigrationNeeded = result {
            // ok
        } else {
            XCTFail("v2 파일은 noMigrationNeeded 여야 함. 실제: \(result)")
        }

        // 파일 변경 없음 확인.
        let after = try Data(contentsOf: url)
        XCTAssertTrue(String(data: after, encoding: .utf8)!.contains("\"version\":2"))
    }

    func test_migrateIfNeeded_missingFile_returnsNoMigrationNeeded() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("workspaces.json")  // 존재하지 않음.

        let result = try WorkspaceSchemaMigration.migrateIfNeeded(at: url, now: fixedDate)
        if case .noMigrationNeeded = result {
            // ok
        } else {
            XCTFail("부재 파일은 noMigrationNeeded 여야 함. 실제: \(result)")
        }
    }

    // MARK: - migrateIfNeeded — v1 → v2 변환

    func test_migrateIfNeeded_v1File_convertsToV2_andCreatesBackup() throws {
        let (dir, url) = try makeTempFile(content: v1FixtureSingleNormal())
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = try WorkspaceSchemaMigration.migrateIfNeeded(at: url, now: fixedDate)
        guard case .migrated(let backupURL) = result else {
            XCTFail("v1 파일이 .migrated 여야 함. 실제: \(result)"); return
        }

        // 1. backup 파일이 생성됨.
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path),
                      "backup 파일이 생성되어야 함")
        XCTAssertTrue(backupURL.lastPathComponent.hasPrefix("workspaces.json.v1-pre-migration-"),
                      "backup 파일명이 규약을 따라야 함. 실제: \(backupURL.lastPathComponent)")

        // 2. main 파일이 v2 schema 로 overwrite 됨.
        let v2Data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(WorkspaceFile.self, from: v2Data)
        XCTAssertEqual(file.version, 2)
        XCTAssertEqual(file.workspaces.count, 1)
        let ws = file.workspaces[0]
        XCTAssertEqual(ws.name, "ws1")
        XCTAssertEqual(ws.panes.count, 1)
        let pane = ws.panes[0]
        XCTAssertEqual(pane.position, .left, "v1 \"top\" → v2 .left 변환")
        XCTAssertEqual(pane.tabs.count, 1, "v1 의 단일 sessionId 가 단일 Tab 으로 wrap")
        XCTAssertEqual(pane.tabs[0].kind, .claude, "v1 Pane.kind → v2 Tab.kind 이동")
        XCTAssertNotNil(pane.tabs[0].sessionId)
        XCTAssertEqual(pane.activeTabId, pane.tabs[0].id)
    }

    func test_migrateIfNeeded_v1File_positionBottom_convertsToRight() throws {
        let (dir, url) = try makeTempFile(content: v1FixtureSingleNormalBottom())
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = try WorkspaceSchemaMigration.migrateIfNeeded(at: url, now: fixedDate)
        guard case .migrated = result else {
            XCTFail("expected .migrated, got \(result)"); return
        }

        let v2Data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(WorkspaceFile.self, from: v2Data)
        XCTAssertEqual(file.workspaces[0].panes[0].position, .right,
                       "v1 \"bottom\" → v2 .right 변환")
    }

    // MARK: - idempotent

    func test_migrateIfNeeded_runTwice_secondRunIsNoOp() throws {
        let (dir, url) = try makeTempFile(content: v1FixtureSingleNormal())
        defer { try? FileManager.default.removeItem(at: dir) }

        // 1차: 실제 migration.
        let first = try WorkspaceSchemaMigration.migrateIfNeeded(at: url, now: fixedDate)
        guard case .migrated = first else {
            XCTFail("first call expected .migrated"); return
        }

        // 2차: idempotent — no-op 이어야 함.
        let second = try WorkspaceSchemaMigration.migrateIfNeeded(at: url, now: fixedDate)
        if case .noMigrationNeeded = second {
            // ok
        } else {
            XCTFail("두 번째 호출은 noMigrationNeeded 여야 함. 실제: \(second)")
        }
    }

    // MARK: - PanePosition migration 1:1 매핑

    func test_convert_topMapsToLeft_bottomMapsToRight() throws {
        let v1Panes: [WorkspaceSchemaV1.V1Pane] = [
            try makeV1Pane(position: "top", kind: .claude),
            try makeV1Pane(position: "bottom", kind: .shell)
        ]
        let v1Ws = try makeV1Workspace(panes: v1Panes)
        let v2 = WorkspaceSchemaMigration.convert(v1Workspaces: [v1Ws], now: fixedDate)
        XCTAssertEqual(v2.count, 1)
        XCTAssertEqual(v2[0].panes.count, 2)
        XCTAssertEqual(v2[0].panes[0].position, .left)
        XCTAssertEqual(v2[0].panes[1].position, .right)
    }

    // MARK: - Helpers

    private func v1FixtureSingleNormal() -> String {
        return #"""
        {
          "version": 1,
          "lastActiveWorkspaceId": null,
          "workspaces": [
            {
              "id": "11111111-1111-1111-1111-111111111111",
              "name": "ws1",
              "cwd": "/tmp/ws1",
              "panes": [
                {
                  "id": "22222222-2222-2222-2222-222222222222",
                  "sessionId": "33333333-3333-3333-3333-333333333333",
                  "kind": "claude",
                  "position": "top",
                  "chatRoomId": null
                }
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
    }

    private func v1FixtureSingleNormalBottom() -> String {
        return #"""
        {
          "version": 1,
          "lastActiveWorkspaceId": null,
          "workspaces": [
            {
              "id": "11111111-1111-1111-1111-111111111111",
              "name": "ws1",
              "cwd": "/tmp/ws1",
              "panes": [
                {
                  "id": "22222222-2222-2222-2222-222222222222",
                  "sessionId": null,
                  "kind": "shell",
                  "position": "bottom",
                  "chatRoomId": null
                }
              ],
              "createdAt": "2026-05-15T00:00:00Z",
              "kind": "normal",
              "envSnapshot": {}
            }
          ]
        }
        """#
    }

    private func makeV1Pane(position: String, kind: PaneKind) throws -> WorkspaceSchemaV1.V1Pane {
        let json = """
        {"id":"\(UUID().uuidString)","sessionId":"\(UUID().uuidString)","kind":"\(kind.rawValue)","position":"\(position)","chatRoomId":null}
        """.data(using: .utf8)!
        return try JSONDecoder().decode(WorkspaceSchemaV1.V1Pane.self, from: json)
    }

    private func makeV1Workspace(panes: [WorkspaceSchemaV1.V1Pane]) throws -> WorkspaceSchemaV1.V1Workspace {
        let panesJSON = try panes.map { p -> String in
            let data = try JSONEncoder().encode(StubV1PaneEncoder(pane: p))
            return String(data: data, encoding: .utf8)!
        }.joined(separator: ",")
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "name": "test-ws",
          "cwd": "/tmp",
          "panes": [\(panesJSON)],
          "createdAt": "2026-05-15T00:00:00Z",
          "kind": "normal",
          "envSnapshot": {}
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WorkspaceSchemaV1.V1Workspace.self, from: json)
    }

    /// V1Pane 은 Decodable only — 테스트용 stub encoder 로 re-encode 한 뒤
    /// V1Workspace JSON 안에 끼워 넣는다.
    private struct StubV1PaneEncoder: Encodable {
        let pane: WorkspaceSchemaV1.V1Pane
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: K.self)
            try c.encode(pane.id, forKey: .id)
            try c.encodeIfPresent(pane.sessionId, forKey: .sessionId)
            try c.encode(pane.kind, forKey: .kind)
            try c.encode(pane.position, forKey: .position)
            try c.encodeIfPresent(pane.chatRoomId, forKey: .chatRoomId)
        }
        enum K: String, CodingKey {
            case id, sessionId, kind, position, chatRoomId
        }
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MigrationTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeTempFile(content: String) throws -> (URL, URL) {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("workspaces.json")
        try content.data(using: .utf8)!.write(to: url)
        return (dir, url)
    }
}
