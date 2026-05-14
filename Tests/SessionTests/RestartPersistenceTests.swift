import XCTest
import Foundation

/// Day 9 통합 테스트: 앱 종료/재시작 시뮬레이션 (`WorkspaceStore` 를 새로 만들어 동일 fileURL 에서 reload).
final class RestartPersistenceTests: XCTestCase {

    // MARK: - 정상 재시작

    @MainActor
    func test_normalRestart_preservesKoreanWorkspaceName_andCwd() throws {
        let dir = try makeTempDir(prefix: "restart-korean")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("workspaces.json")

        // pre-restart: 한국어 이름 workspace 저장.
        let preStore = try WorkspaceStore(fileURL: url)
        let preMgr = WorkspaceManager(store: preStore)
        _ = preMgr.addWorkspace(cwd: "/tmp/내프로젝트A", name: "내 작업")
        _ = preMgr.addWorkspace(cwd: "/tmp/projB", name: "B")

        // 시뮬레이션: 새 store 인스턴스로 reload (앱 재시작).
        let postStore = try WorkspaceStore(fileURL: url)
        let file = try postStore.load()

        // agent-view + 2 normal = 3.
        XCTAssertGreaterThanOrEqual(file.workspaces.count, 3)
        XCTAssertEqual(
            file.workspaces.filter { $0.kind == .normal && $0.name == "내 작업" }.count, 1,
            "한국어 workspace 이름 '내 작업' 이 깨짐 없이 복원"
        )
        XCTAssertEqual(
            file.workspaces.first(where: { $0.name == "내 작업" })?.cwd, "/tmp/내프로젝트A",
            "cwd (한국어 path 포함) 정확 복원"
        )
    }

    @MainActor
    func test_normalRestart_panesAndSessionIds_persistedAsOrphan() throws {
        let dir = try makeTempDir(prefix: "restart-panes")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("workspaces.json")

        // pre-restart: workspace + pane + pane.sessionId 설정.
        let preStore = try WorkspaceStore(fileURL: url)
        let preMgr = WorkspaceManager(store: preStore)
        let ws = preMgr.addWorkspace(cwd: "/tmp/sx", name: "x")
        guard let pane = ws.panes.first else { XCTFail("default pane 부재"); return }
        let fakeSessionId = UUID()
        preMgr.assignSession(workspaceId: ws.id, paneId: pane.id, sessionId: fakeSessionId)

        // post-restart.
        let postStore = try WorkspaceStore(fileURL: url)
        let file = try postStore.load()
        let restored = file.workspaces.first(where: { $0.id == ws.id })

        XCTAssertNotNil(restored)
        XCTAssertEqual(restored?.panes.count, 1)
        XCTAssertEqual(restored?.panes.first?.sessionId, fakeSessionId,
                       "pane.sessionId 가 영속화 (orphan 형태로 보존 — Day 1 결정)")
        // SessionManager 입장에서는 해당 sessionId 가 존재하지 않음 — UI 가 'session 없음' 으로 처리.
    }

    // MARK: - 비정상 종료 복구 (.bak)

    @MainActor
    func test_kill9Simulation_recoversFromBak() throws {
        let dir = try makeTempDir(prefix: "restart-kill9")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("workspaces.json")

        // 두 번 저장 → .bak 생성.
        let store = try WorkspaceStore(fileURL: url)
        let mgr = WorkspaceManager(store: store)
        _ = mgr.addWorkspace(cwd: "/a", name: "첫번째")
        _ = mgr.addWorkspace(cwd: "/b", name: "두번째")

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.appendingPathExtension("bak").path),
            "두 번째 save 가 직전 정상본을 .bak 으로 회전"
        )

        // kill -9 시뮬레이션: 주 파일 강제 삭제.
        try FileManager.default.removeItem(at: url)

        // 새 store 로 reload → .bak 에서 복구.
        let postStore = try WorkspaceStore(fileURL: url)
        let recovered = try postStore.load()
        XCTAssertTrue(
            recovered.workspaces.contains(where: { $0.name == "첫번째" }),
            ".bak 에 보존된 직전 정상본을 통해 '첫번째' workspace 복구"
        )
    }

    // MARK: - M2 stale claude-config cleanup

    func test_cleanupStaleConfigDirs_keepsRecent_keepsReferenced_removesOldUnreferenced() throws {
        let root = try makeTempDir(prefix: "cleanup-test")
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        let oldThreshold = now.addingTimeInterval(-7 * 86400)

        // 3 디렉터리 케이스:
        // 1. 오래된 + unreferenced → 삭제 대상
        let oldUnref = UUID()
        let oldUnrefDir = root.appendingPathComponent(oldUnref.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: oldUnrefDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-10 * 86400)],
            ofItemAtPath: oldUnrefDir.path
        )

        // 2. 오래된 + referenced (live) → 보존
        let oldLive = UUID()
        let oldLiveDir = root.appendingPathComponent(oldLive.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: oldLiveDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-10 * 86400)],
            ofItemAtPath: oldLiveDir.path
        )

        // 3. 최근 + unreferenced → 보존
        let recentUnref = UUID()
        let recentUnrefDir = root.appendingPathComponent(recentUnref.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: recentUnrefDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-1 * 86400)],
            ofItemAtPath: recentUnrefDir.path
        )

        try SessionSpawnEnv.cleanupStaleConfigDirs(
            rootDir: root,
            liveSessionIds: [oldLive],
            olderThan: oldThreshold
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldUnrefDir.path),
                       "오래된 unreferenced 디렉터리는 제거")
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldLiveDir.path),
                      "live session 의 디렉터리는 오래되어도 보존")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentUnrefDir.path),
                      "최근 디렉터리는 unreferenced 여도 보존(threshold 통과)")
    }

    // MARK: - M6 forward-compat across save → load → save → load

    @MainActor
    func test_forwardCompat_unknownField_survivesAcrossRestart() throws {
        let dir = try makeTempDir(prefix: "fwd-compat")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("workspaces.json")

        // pre-restart: workspace JSON 에 unknown field 를 직접 주입한 형태로 작성.
        let json = """
        {
          "version": 1,
          "lastActiveWorkspaceId": null,
          "workspaces": [
            {
              "id": "33333333-3333-3333-3333-333333333333",
              "name": "fwd",
              "cwd": "/tmp",
              "panes": [],
              "createdAt": "2026-05-13T09:00:00Z",
              "kind": "normal",
              "envSnapshot": {},
              "pushChannelHints": null,
              "fetchHintMetadata": null,
              "extraFields": null,
              "futurePushSetting": "wsA-only-tag"
            }
          ]
        }
        """
        try json.data(using: .utf8)!.write(to: url)

        // load → save → reload.
        let storeA = try WorkspaceStore(fileURL: url)
        let loadedA = try storeA.load()
        try storeA.save(loadedA)

        let storeB = try WorkspaceStore(fileURL: url)
        let loadedB = try storeB.load()

        let ws = loadedB.workspaces.first(where: { $0.name == "fwd" })
        XCTAssertEqual(ws?.extraFields?["futurePushSetting"]?.value as? String, "wsA-only-tag",
                       "unknown top-level field 가 extraFields 로 catch 되어 save→reload round-trip 후에도 보존됨 (M6)")
    }

    // MARK: - Helpers

    private func makeTempDir(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
