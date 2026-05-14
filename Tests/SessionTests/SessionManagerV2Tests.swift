import XCTest
import Foundation
import Combine

final class SessionManagerV2Tests: XCTestCase {

    // MARK: - 1. Max sessions / concurrency

    func test_concurrentCreate_enforcesMaxSessions_NPlus1() async throws {
        let manager = SessionManager(maxSessionsOverride: 3)
        let workspace = makeTestWorkspace()

        actor Counter {
            var success = 0
            var reject = 0
            var other = 0
            var ids: [UUID] = []
            func ok(_ id: UUID) { success += 1; ids.append(id) }
            func nope() { reject += 1 }
            func bad() { other += 1 }
        }
        let counter = Counter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    do {
                        let s = try await manager.create(
                            workspace: workspace,
                            paneId: UUID(),
                            kind: .shell,
                            rows: 24, cols: 80
                        )
                        await counter.ok(s.id)
                    } catch ManagerError.maxSessionsReached {
                        await counter.nope()
                    } catch {
                        FileHandle.standardError.write(
                            Data("unexpected error: \(error)\n".utf8))
                        await counter.bad()
                    }
                }
            }
        }

        let s = await counter.success
        let r = await counter.reject
        let o = await counter.other
        XCTAssertEqual(s, 3, "정확히 3개 성공")
        XCTAssertEqual(r, 1, "정확히 1개 maxSessionsReached")
        XCTAssertEqual(o, 0, "예상치 못한 에러 0건")

        // Cleanup
        await manager.terminateAll(inWorkspace: workspace.id)
        for id in await counter.ids { await manager.remove(id: id) }
    }

    func test_maxSessionsReached_emitsKoreanMessage() {
        let err = ManagerError.maxSessionsReached(currentMax: 20)
        XCTAssertEqual(
            err.description,
            "최대 세션 개수에 도달했습니다 (N=20). 기존 세션을 종료하세요."
        )
    }

    func test_defaultMaxSessions_is20() async {
        let manager = SessionManager()
        let max = await manager.currentMaxSessions()
        XCTAssertEqual(max, 20)
    }

    // MARK: - 2. SessionSpawnEnv

    func test_buildSpawnEnv_claude_addsClaudeConfigDir_overWorkspaceEnvBase() throws {
        let ws = Workspace(
            name: "ws",
            cwd: "/tmp",
            createdAt: fixedDate,
            kind: .normal,
            envSnapshot: ["PATH": "/usr/bin", "LANG": "ko_KR.UTF-8"]
        )
        let env = try SessionSpawnEnv.buildSpawnEnv(
            workspace: ws, paneId: UUID(), sessionId: UUID(), kind: .claude
        )
        XCTAssertEqual(env["PATH"], "/usr/bin", "workspace.envSnapshot 의 PATH 가 base 로 유지")
        XCTAssertEqual(env["LANG"], "ko_KR.UTF-8")
        XCTAssertNotNil(env["CLAUDE_CONFIG_DIR"])
        XCTAssertTrue(env["CLAUDE_CONFIG_DIR"]!.contains("claude-config"))
        XCTAssertNil(env["HISTFILE"])
    }

    func test_buildSpawnEnv_shell_addsHistFile_overWorkspaceEnvBase() throws {
        let ws = Workspace(
            name: "ws",
            cwd: "/tmp",
            createdAt: fixedDate,
            kind: .normal,
            envSnapshot: ["PATH": "/usr/bin"]
        )
        let env = try SessionSpawnEnv.buildSpawnEnv(
            workspace: ws, paneId: UUID(), sessionId: UUID(), kind: .shell
        )
        XCTAssertEqual(env["PATH"], "/usr/bin")
        XCTAssertNotNil(env["HISTFILE"])
        XCTAssertTrue(env["HISTFILE"]!.hasSuffix("/history"))
        XCTAssertNil(env["CLAUDE_CONFIG_DIR"])
    }

    func test_claudeConfigDir_perSession_distinctPaths() throws {
        let id1 = UUID(); let id2 = UUID()
        let d1 = try SessionSpawnEnv.claudeConfigDir(forSession: id1)
        let d2 = try SessionSpawnEnv.claudeConfigDir(forSession: id2)
        XCTAssertNotEqual(d1, d2)
        XCTAssertTrue(d1.contains(id1.uuidString))
        XCTAssertTrue(d2.contains(id2.uuidString))
        XCTAssertTrue(FileManager.default.fileExists(atPath: d1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: d2))
    }

    func test_zshHistoryDir_perPane_distinctPaths() throws {
        let wsId = UUID()
        let p1 = UUID(); let p2 = UUID()
        let d1 = try SessionSpawnEnv.zshHistoryDir(workspaceId: wsId, paneId: p1)
        let d2 = try SessionSpawnEnv.zshHistoryDir(workspaceId: wsId, paneId: p2)
        XCTAssertNotEqual(d1, d2)
        XCTAssertTrue(d1.contains(p1.uuidString))
        XCTAssertTrue(d2.contains(p2.uuidString))
    }

    // MARK: - 3. Lifecycle hooks (Combine)

    func test_lifecycleHooks_onSessionCreated_publishesOnCreate() async throws {
        let hooks = SessionLifecycleHooks()
        let manager = SessionManager(maxSessionsOverride: 3, hooks: hooks)

        let ws = makeTestWorkspace()
        let captured = TestActor<UUID>()
        let exp = expectation(description: "onSessionCreated")
        let c = hooks.onSessionCreated.sink { s in
            Task { await captured.append(s.id); await MainActor.run { exp.fulfill() } }
        }
        defer { c.cancel() }

        let session = try await manager.create(
            workspace: ws, paneId: UUID(), kind: .shell, rows: 24, cols: 80
        )
        await fulfillment(of: [exp], timeout: 3)
        let ids = await captured.snapshot()
        XCTAssertEqual(ids, [session.id])

        try? await manager.terminate(id: session.id)
        await manager.remove(id: session.id)
    }

    func test_lifecycleHooks_onSessionTerminated_publishesOnTerminate() async throws {
        let hooks = SessionLifecycleHooks()
        let manager = SessionManager(maxSessionsOverride: 3, hooks: hooks)

        let ws = makeTestWorkspace()
        let captured = TestActor<UUID>()
        let exp = expectation(description: "onSessionTerminated")
        let c = hooks.onSessionTerminated.sink { id in
            Task { await captured.append(id); await MainActor.run { exp.fulfill() } }
        }
        defer { c.cancel() }

        let session = try await manager.create(
            workspace: ws, paneId: UUID(), kind: .shell, rows: 24, cols: 80
        )
        try await manager.terminate(id: session.id)
        await fulfillment(of: [exp], timeout: 5)
        let ids = await captured.snapshot()
        XCTAssertEqual(ids, [session.id])

        await manager.remove(id: session.id)
    }

    // MARK: - 4. terminateAll fairness (M1) + activityScope invariant (N2)

    func test_terminateAll_completes_under5s_fairnessParallel() async throws {
        let manager = SessionManager(maxSessionsOverride: 10)
        let ws = makeTestWorkspace()
        var ids: [UUID] = []
        for _ in 0..<5 {
            let s = try await manager.create(
                workspace: ws, paneId: UUID(), kind: .shell, rows: 24, cols: 80
            )
            ids.append(s.id)
        }

        let start = Date()
        await manager.terminateAll(inWorkspace: ws.id)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 5.0,
                          "5개 셸 terminateAll 은 병렬 처리로 5초 이내 완료 (M1)")

        for id in ids {
            let s = await manager.get(id: id)
            XCTAssertEqual(s?.status, .exited, "모든 세션 .exited")
            await manager.remove(id: id)
        }
    }

    func test_activityScope_releasesAfter_terminateAll_invariant() async throws {
        let manager = SessionManager(maxSessionsOverride: 5)
        let ws = makeTestWorkspace()
        var ids: [UUID] = []
        for _ in 0..<2 {
            let s = try await manager.create(
                workspace: ws, paneId: UUID(), kind: .shell, rows: 24, cols: 80
            )
            ids.append(s.id)
        }

        let activeBefore = await manager.activityScopeIsActive()
        XCTAssertTrue(activeBefore, "running 세션 존재 시 activityScope 활성")

        await manager.terminateAll(inWorkspace: ws.id)

        let activeAfter = await manager.activityScopeIsActive()
        XCTAssertFalse(activeAfter,
                       "terminateAll 종료 후 invariant: 모든 세션 .exited 이면 activityScope == nil (N2)")

        for id in ids { await manager.remove(id: id) }
    }

    func test_terminateAll_doesNotStall_concurrentCreate_M1() async throws {
        let manager = SessionManager(maxSessionsOverride: 10)
        let wsA = makeTestWorkspace()
        let wsB = makeTestWorkspace()  // 다른 workspace — terminateAll(inWorkspace: wsA) 영향 없음
        var idsA: [UUID] = []
        for _ in 0..<3 {
            let s = try await manager.create(
                workspace: wsA, paneId: UUID(), kind: .shell, rows: 24, cols: 80
            )
            idsA.append(s.id)
        }

        // terminateAll(wsA) 와 동시에 wsB 의 create() 시도. 두 작업이 직렬 누적이 아니어야 함.
        async let terminateTask: Void = manager.terminateAll(inWorkspace: wsA.id)
        let createStart = Date()
        let bSession = try await manager.create(
            workspace: wsB, paneId: UUID(), kind: .shell, rows: 24, cols: 80
        )
        let createElapsed = Date().timeIntervalSince(createStart)
        await terminateTask

        // M1: terminateAll 의 1초 SIGTERM grace 가 create() 를 head-of-line stall 시키지 않아야 함.
        // 즉시는 아니어도 (PTY spawn 자체 latency), terminateAll 전체 시간(~1.2s) 보다는 빨라야 함.
        XCTAssertLessThan(createElapsed, 1.0,
                          "다른 workspace 의 create() 가 terminateAll grace 에 head-of-line stall 되지 않음 (M1)")

        try? await manager.terminate(id: bSession.id)
        await manager.remove(id: bSession.id)
        for id in idsA { await manager.remove(id: id) }
    }

    // MARK: - 5. grep invariant (MED7)

    func test_grepInvariant_allMutatingMethodsAreAsync_andNoNonisolated() throws {
        let source = try sessionManagerSource()

        // 모든 public 메서드 매칭 라인이 async 키워드를 포함하는지 검증.
        let pattern = #"(public\s+)?func\s+(create|terminate|get|terminateAll|updateClaudeSessionId)\s*\("#
        let regex = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        let nsrange = NSRange(source.startIndex..., in: source)
        let matches = regex.matches(in: source, options: [], range: nsrange)
        XCTAssertGreaterThanOrEqual(matches.count, 5,
                                    "5개 이상 메서드 매칭 (create x3, terminate, get, terminateAll, updateClaudeSessionId)")

        for m in matches {
            guard let range = Range(m.range, in: source) else { continue }
            // 함수 시작 ~ '{' 직전까지(시그니처 라인 전체) 에 async 가 등장해야 함.
            // updateClaudeSessionId 는 async 가 아님 → 예외 처리.
            let lineEnd = source[range.lowerBound...].firstIndex(where: { $0 == "{" }) ?? source.endIndex
            let signature = String(source[range.lowerBound..<lineEnd])
            if signature.contains("updateClaudeSessionId") {
                continue // sync (actor isolated 자체로 충분)
            }
            XCTAssertTrue(signature.contains("async"),
                          "func 시그니처에 async 누락: \(signature)")
        }

        // nonisolated 키워드 0건 (P1 invariant 유지).
        XCTAssertFalse(source.contains("nonisolated"),
                       "SessionManager.swift 에 nonisolated 키워드 발견 — P1 actor isolation invariant 위반")
    }

    // MARK: - Helpers

    /// 결정적 whole-second 타임스탬프 (2026-05-14T00:00:00Z).
    private let fixedDate = Date(timeIntervalSince1970: 1_778_716_800)

    private func makeTestWorkspace() -> Workspace {
        // shell pane spawn 이 안전하게 zsh 를 찾도록 ProcessInfo env 를 base 로 사용.
        Workspace(
            id: UUID(),
            name: "test-ws",
            cwd: NSTemporaryDirectory(),
            createdAt: fixedDate,
            kind: .normal,
            envSnapshot: ProcessInfo.processInfo.environment
        )
    }

    private func sessionManagerSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Session/SessionManager.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }
}

/// Combine sink 콜백이 외부에서 동기 mutation 을 못 하므로 isolated 컨테이너 사용.
private actor TestActor<T: Sendable> {
    private var items: [T] = []
    func append(_ value: T) { items.append(value) }
    func snapshot() -> [T] { items }
}
