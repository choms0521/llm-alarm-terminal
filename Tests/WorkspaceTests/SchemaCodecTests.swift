import XCTest
import Foundation
import AnyCodable

final class SchemaCodecTests: XCTestCase {

    // MARK: - Round-trip (4 cases, 한국어 포함)

    func test_roundTrip_emptyNormalWorkspace_preservesAllFields() throws {
        // ISO8601 직렬화는 sub-second precision 을 보존하지 않으므로 결정적 whole-second
        // timestamp 로 round-trip equality 를 명시적으로 검증한다 (스키마 정책: whole-second).
        let ws = Workspace(name: "empty", cwd: "/tmp", createdAt: fixedDate, kind: .normal)
        XCTAssertEqual(try roundTrip(ws), ws)
    }

    func test_roundTrip_koreanName_preservesUnicode() throws {
        let ws = Workspace(
            name: "내 프로젝트",
            cwd: "/Users/x/projA",
            createdAt: fixedDate,
            kind: .normal,
            envSnapshot: ["LANG": "ko_KR.UTF-8", "PATH": "/usr/bin"]
        )
        let restored = try roundTrip(ws)
        XCTAssertEqual(restored, ws)
        XCTAssertEqual(restored.name, "내 프로젝트")
        XCTAssertEqual(restored.envSnapshot["LANG"], "ko_KR.UTF-8")
    }

    func test_roundTrip_twoPanesTopBottom_preservesOrderAndPosition() throws {
        let top = Pane(kind: .claude, position: .top)
        let bottom = Pane(kind: .shell, position: .bottom)
        let ws = Workspace(name: "양분할", cwd: "/work", panes: [top, bottom], kind: .normal)
        let restored = try roundTrip(ws)
        XCTAssertEqual(restored.panes.count, 2)
        XCTAssertEqual(restored.panes[0].position, .top)
        XCTAssertEqual(restored.panes[0].kind, .claude)
        XCTAssertEqual(restored.panes[1].position, .bottom)
        XCTAssertEqual(restored.panes[1].kind, .shell)
    }

    func test_roundTrip_agentView_emptyCwdAndPanes() throws {
        let ws = Workspace.makeAgentView()
        let restored = try roundTrip(ws)
        XCTAssertEqual(restored.kind, .agentView)
        XCTAssertEqual(restored.cwd, "")
        XCTAssertTrue(restored.panes.isEmpty)
        XCTAssertFalse(restored.canClose)
        XCTAssertEqual(restored.name, "에이전트 뷰")
    }

    // MARK: - Reserved field preservation (P5 / P6a / P10b)

    func test_reservedField_pushChannelHints_onWorkspace_preserved() throws {
        let hints: [String: String] = ["fcmDeviceId": "fcm-abc", "apnsDeviceToken": "apns-def"]
        let ws = Workspace(
            name: "p5",
            cwd: "/tmp",
            kind: .normal,
            pushChannelHints: hints
        )
        let restored = try roundTrip(ws)
        XCTAssertEqual(restored.pushChannelHints, hints)
    }

    func test_reservedField_chatRoomId_onPane_preserved() throws {
        let pane = Pane(kind: .claude, position: .top, chatRoomId: "room-uuid-1234")
        let ws = Workspace(name: "p9", cwd: "/tmp", panes: [pane], kind: .normal)
        let restored = try roundTrip(ws)
        XCTAssertEqual(restored.panes.first?.chatRoomId, "room-uuid-1234")
    }

    func test_reservedField_fetchHintMetadata_onWorkspace_preserved() throws {
        let meta: [String: AnyCodable] = [
            "lastSeqOnDevice": AnyCodable("seq-42"),
            "fetchEndpoint": AnyCodable("https://x/y")
        ]
        let ws = Workspace(
            name: "p10b",
            cwd: "/tmp",
            kind: .normal,
            fetchHintMetadata: meta
        )
        let restored = try roundTrip(ws)
        XCTAssertEqual(restored.fetchHintMetadata?["lastSeqOnDevice"]?.value as? String, "seq-42")
        XCTAssertEqual(restored.fetchHintMetadata?["fetchEndpoint"]?.value as? String, "https://x/y")
    }

    // MARK: - Forward-compat unknown field (M6)

    func test_forwardCompat_unknownField_onWorkspace_preservedToExtraFields() throws {
        let json = """
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "name": "fwd",
            "cwd": "/tmp",
            "panes": [],
            "createdAt": "2026-05-13T09:00:00Z",
            "kind": "normal",
            "envSnapshot": {},
            "foo": "bar",
            "futurePushFlag": 42
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let ws = try decoder.decode(Workspace.self, from: json)

        XCTAssertEqual(ws.extraFields?["foo"]?.value as? String, "bar")
        XCTAssertEqual(ws.extraFields?["futurePushFlag"]?.value as? Int, 42)

        // encode → decode 후에도 보존되는지 확인 (M6 round-trip 핵심).
        let restored = try roundTrip(ws)
        XCTAssertEqual(restored.extraFields?["foo"]?.value as? String, "bar")
        XCTAssertEqual(restored.extraFields?["futurePushFlag"]?.value as? Int, 42)
    }

    func test_forwardCompat_unknownField_onPane_preservedToExtraFields() throws {
        let json = """
        {
            "id": "22222222-2222-2222-2222-222222222222",
            "sessionId": null,
            "kind": "shell",
            "position": "bottom",
            "chatRoomId": null,
            "experimentalFlag": true
        }
        """.data(using: .utf8)!
        let pane = try JSONDecoder().decode(Pane.self, from: json)
        XCTAssertEqual(pane.extraFields?["experimentalFlag"]?.value as? Bool, true)
    }

    // MARK: - Atomic write (M4)

    func test_atomicWrite_staleTmpCleanedUpOnLoad() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("workspaces.json")
        let store = try WorkspaceStore(fileURL: url)

        // 정상 1회 저장 후, 잔존 .tmp 를 인위적으로 만든다 (kill -9 시뮬레이션).
        let initial = WorkspaceFile(
            workspaces: [Workspace.makeAgentView()]
        )
        try store.save(initial)

        let tmp = url.appendingPathExtension("tmp")
        try Data("garbage".utf8).write(to: tmp)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.path))

        _ = try store.load()
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.path),
                       "load() 가 진입부에서 stale .tmp 를 정리해야 한다 (M4)")
    }

    func test_atomicWrite_bakRecoveryWhenMainMissing() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("workspaces.json")
        let store = try WorkspaceStore(fileURL: url)

        // 두 번 저장: 두 번째 save 가 첫 번째 내용을 .bak 로 회전시킨다.
        let firstNormal = Workspace(name: "first", cwd: "/a", kind: .normal)
        try store.save(WorkspaceFile(workspaces: [Workspace.makeAgentView(), firstNormal]))

        let secondNormal = Workspace(name: "second", cwd: "/b", kind: .normal)
        try store.save(WorkspaceFile(workspaces: [Workspace.makeAgentView(), secondNormal]))

        // 주 파일 강제 삭제 후 load → .bak 으로 복구 시도.
        try FileManager.default.removeItem(at: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("bak").path))

        let recovered = try store.load()
        let normals = recovered.workspaces.filter { $0.kind == .normal }
        XCTAssertEqual(normals.first?.name, "first",
                       ".bak 에 보존된 직전 정상본(첫 번째 save 내용)을 로드해야 한다")
    }

    // MARK: - H2 save() error surface

    func test_save_throws_andSurfacesKoreanMessage_onReadOnlyDir() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("workspaces.json")
        let store = try WorkspaceStore(fileURL: url)

        // 디렉터리를 read+exec only 로 변경 → 그 안에 write 불가.
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o500)],
            ofItemAtPath: dir.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: dir.path
            )
            try? FileManager.default.removeItem(at: dir)
        }

        let file = WorkspaceFile(workspaces: [Workspace.makeAgentView()])

        var captured: Error?
        XCTAssertThrowsError(try store.save(file)) { error in
            captured = error
        }
        guard let captured = captured else {
            XCTFail("save() 가 throw 해야 한다 (read-only 디렉터리에서)")
            return
        }
        let desc = String(describing: captured)
        XCTAssertTrue(
            desc.contains("워크스페이스 저장에 실패"),
            "에러 메시지가 한국어로 surface 되어야 한다 (H2). 실제: \(desc)"
        )
    }

    // MARK: - L1 AnyCodable dependency

    func test_anyCodable_dependencyLoaded_smokeTest() {
        // 외부 의존 Flight-School/AnyCodable 가 빌드 시점에 링크됨을 직접 확인.
        let value = AnyCodable("안녕")
        XCTAssertEqual(value.value as? String, "안녕")
    }

    // MARK: - Helpers

    private func roundTrip(_ ws: Workspace) throws -> Workspace {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(ws)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Workspace.self, from: data)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceStoreTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 결정적 whole-second 타임스탬프 (2026-05-14T00:00:00Z).
    /// ISO8601 직렬화의 whole-second precision 정책과 부합.
    private let fixedDate = Date(timeIntervalSince1970: 1_778_716_800)
}
