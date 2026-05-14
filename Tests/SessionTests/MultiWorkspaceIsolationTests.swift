import XCTest
import Foundation
import Darwin

/// Day 6 통합 테스트. P2 § 5 sub-invariant 5건을 검증한다.
///
/// 1. envSnapshot 은 workspace 생성 시점에 결정되어 이후 외부 변경에 영향받지 않음 (H6)
/// 2. cd 비전파 (POSIX child env)
/// 3. workspace 간 env 누설 차단
/// 4. claude config dir 격리 (workspace 단위)
/// 5. HISTFILE 격리 (pane 단위) — M3
final class MultiWorkspaceIsolationTests: XCTestCase {

    // MARK: - Invariant 1: envSnapshot capture-at-creation

    func test_invariant1_envSnapshot_immutableAfterCreation() throws {
        // Pre-condition: 환경 변수 미존재.
        unsetenv("CHAT_TERMINAL_DAY6_INV1")

        let snapshot = SessionSpawnEnv.captureUserEnv()
        let workspace = Workspace(
            id: UUID(),
            name: "inv1",
            cwd: "/tmp",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            kind: .normal,
            envSnapshot: snapshot
        )

        // 외부에서 env 변경.
        setenv("CHAT_TERMINAL_DAY6_INV1", "after-creation", 1)
        defer { unsetenv("CHAT_TERMINAL_DAY6_INV1") }

        // workspace 의 envSnapshot 은 capture 시점 값만 보유.
        XCTAssertNil(workspace.envSnapshot["CHAT_TERMINAL_DAY6_INV1"],
                     "workspace 생성 후 set 된 env 가 envSnapshot 에 반영되지 않음 (H6)")
    }

    // MARK: - Invariant 2: cd 비전파 — 새 pane 의 cwd = workspace.cwd (실 PTY)

    func test_invariant2_cdNonPropagation_newPaneUsesWorkspaceCwd() async throws {
        let manager = SessionManager(maxSessionsOverride: 5)
        let tmpRoot = try PtyTestHarness.makeTempDir(prefix: "projA-inv2")
        defer { try? FileManager.default.removeItem(at: tmpRoot) }
        let realPath = tmpRoot.resolvingSymlinksInPath().path

        let shellEnv = try PtyTestHarness.minimalShellEnv(zdotdirParent: tmpRoot)
        let workspace = Workspace(
            id: UUID(),
            name: "a",
            cwd: realPath,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            kind: .normal,
            envSnapshot: shellEnv
        )

        // pane1 → cd /tmp
        let pane1 = try await manager.create(
            workspace: workspace, paneId: UUID(), kind: .shell, rows: 24, cols: 80
        )
        guard let h1 = pane1.ptyHandle else { XCTFail("pane1 PTY"); return }
        _ = PtyTestHarness.readUntilQuiet(fd: h1.masterFD, timeout: 0.8)
        try PtyTestHarness.writeCmd(h1.masterFD, "cd /tmp")
        _ = PtyTestHarness.readUntilQuiet(fd: h1.masterFD, timeout: 0.3)

        // pane2: workspace.cwd 가 cwd 로 적용되어야 함.
        let pane2 = try await manager.create(
            workspace: workspace, paneId: UUID(), kind: .shell, rows: 24, cols: 80
        )
        guard let h2 = pane2.ptyHandle else { XCTFail("pane2 PTY"); return }
        _ = PtyTestHarness.readUntilQuiet(fd: h2.masterFD, timeout: 0.8)
        try PtyTestHarness.writeCmd(h2.masterFD, "pwd")
        let out = PtyTestHarness.readUntilQuiet(fd: h2.masterFD, timeout: 0.8)
        let plain = PtyTestHarness.stripANSI(out)

        XCTAssertTrue(
            plain.contains(realPath),
            "pane2 의 pwd 가 workspace.cwd (= \(realPath)) 와 일치해야 함 (cd 비전파). 실제: \(plain)"
        )
        XCTAssertFalse(
            plain.contains("/tmp\n") && !realPath.hasPrefix("/tmp/"),
            "pane2 의 pwd 가 pane1 의 cd 결과(/tmp) 를 상속하지 않아야 함"
        )

        await manager.terminateAll(inWorkspace: workspace.id)
        for id in await manager.sessionIds(inWorkspace: workspace.id) {
            await manager.remove(id: id)
        }
    }

    // MARK: - Invariant 3: workspace 간 env 누설 차단 (실 PTY)

    func test_invariant3_envIsolation_betweenWorkspaces() async throws {
        let manager = SessionManager(maxSessionsOverride: 5)
        let tmpRoot = try PtyTestHarness.makeTempDir(prefix: "inv3")
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let shellEnv = try PtyTestHarness.minimalShellEnv(zdotdirParent: tmpRoot)
        let cwdA = try PtyTestHarness.makeTempDir(prefix: "wsA-cwd")
        let cwdB = try PtyTestHarness.makeTempDir(prefix: "wsB-cwd")
        defer {
            try? FileManager.default.removeItem(at: cwdA)
            try? FileManager.default.removeItem(at: cwdB)
        }

        let wsA = Workspace(
            id: UUID(), name: "A",
            cwd: cwdA.resolvingSymlinksInPath().path,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            kind: .normal, envSnapshot: shellEnv
        )
        let wsB = Workspace(
            id: UUID(), name: "B",
            cwd: cwdB.resolvingSymlinksInPath().path,
            createdAt: Date(timeIntervalSince1970: 1_700_000_001),
            kind: .normal, envSnapshot: shellEnv
        )

        // wsA pane1 → export FOO_DAY6_INV3=wsA-only
        let paneA = try await manager.create(
            workspace: wsA, paneId: UUID(), kind: .shell, rows: 24, cols: 80
        )
        guard let hA = paneA.ptyHandle else { XCTFail(); return }
        _ = PtyTestHarness.readUntilQuiet(fd: hA.masterFD, timeout: 0.8)
        try PtyTestHarness.writeCmd(hA.masterFD, "export FOO_DAY6_INV3=wsA-only")
        _ = PtyTestHarness.readUntilQuiet(fd: hA.masterFD, timeout: 0.3)

        // wsB pane → echo $FOO_DAY6_INV3 → 빈 출력
        let paneB = try await manager.create(
            workspace: wsB, paneId: UUID(), kind: .shell, rows: 24, cols: 80
        )
        guard let hB = paneB.ptyHandle else { XCTFail(); return }
        _ = PtyTestHarness.readUntilQuiet(fd: hB.masterFD, timeout: 0.8)
        try PtyTestHarness.writeCmd(hB.masterFD, "echo \"FOO=[$FOO_DAY6_INV3]\"")
        let out = PtyTestHarness.readUntilQuiet(fd: hB.masterFD, timeout: 0.8)
        let plain = PtyTestHarness.stripANSI(out)

        XCTAssertTrue(
            plain.contains("FOO=[]"),
            "wsB pane 에 wsA 의 export 가 누설되지 않아야 함. 실제: \(plain)"
        )

        await manager.terminateAll(inWorkspace: wsA.id)
        await manager.terminateAll(inWorkspace: wsB.id)
        for id in await manager.sessionIds(inWorkspace: wsA.id) { await manager.remove(id: id) }
        for id in await manager.sessionIds(inWorkspace: wsB.id) { await manager.remove(id: id) }
    }

    // MARK: - Invariant 4: claude config dir per session

    func test_invariant4_claudeConfigDir_perSession_distinct() throws {
        let wsA_session = UUID()
        let wsB_session = UUID()
        let aDir = try SessionSpawnEnv.claudeConfigDir(forSession: wsA_session)
        let bDir = try SessionSpawnEnv.claudeConfigDir(forSession: wsB_session)
        XCTAssertNotEqual(aDir, bDir)
        XCTAssertTrue(aDir.contains(wsA_session.uuidString))
        XCTAssertTrue(bDir.contains(wsB_session.uuidString))

        // buildSpawnEnv 도 동일하게 분리.
        let wsA = Workspace(name: "a", cwd: "/tmp", createdAt: Date(timeIntervalSince1970: 1_700_000_000), kind: .normal, envSnapshot: [:])
        let wsB = Workspace(name: "b", cwd: "/tmp", createdAt: Date(timeIntervalSince1970: 1_700_000_001), kind: .normal, envSnapshot: [:])
        let envA = try SessionSpawnEnv.buildSpawnEnv(workspace: wsA, paneId: UUID(), sessionId: wsA_session, kind: .claude)
        let envB = try SessionSpawnEnv.buildSpawnEnv(workspace: wsB, paneId: UUID(), sessionId: wsB_session, kind: .claude)
        XCTAssertNotEqual(envA["CLAUDE_CONFIG_DIR"], envB["CLAUDE_CONFIG_DIR"])
    }

    // MARK: - Invariant 5 (M3): HISTFILE per pane

    func test_invariant5_histFile_perPane_distinct_andUnderCachesDir() throws {
        let wsId = UUID()
        let p1 = UUID(); let p2 = UUID()
        let d1 = try SessionSpawnEnv.zshHistoryDir(workspaceId: wsId, paneId: p1)
        let d2 = try SessionSpawnEnv.zshHistoryDir(workspaceId: wsId, paneId: p2)
        XCTAssertNotEqual(d1, d2)
        XCTAssertTrue(d1.contains(p1.uuidString))
        XCTAssertTrue(d2.contains(p2.uuidString))
        XCTAssertTrue(d1.contains("zsh_history"),
                      "HISTFILE 경로가 Caches/ClaudeAlarmTerminal/zsh_history 하위에 위치")

        // buildSpawnEnv 결과의 HISTFILE 도 분리.
        let ws = Workspace(name: "w", cwd: "/tmp", createdAt: Date(timeIntervalSince1970: 1_700_000_000), kind: .normal, envSnapshot: [:])
        let env1 = try SessionSpawnEnv.buildSpawnEnv(workspace: ws, paneId: p1, sessionId: UUID(), kind: .shell)
        let env2 = try SessionSpawnEnv.buildSpawnEnv(workspace: ws, paneId: p2, sessionId: UUID(), kind: .shell)
        XCTAssertNotEqual(env1["HISTFILE"], env2["HISTFILE"])
        XCTAssertTrue(env1["HISTFILE"]?.hasSuffix("/history") ?? false)
    }
}
