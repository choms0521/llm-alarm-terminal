import XCTest
import Foundation
import Combine

@MainActor
final class SessionStatusCoordinatorTests: XCTestCase {

    private let fixedSid = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private var cancellables: Set<AnyCancellable> = []

    // MARK: - 1. 초기 상태

    func test_init_emptySnapshots() {
        let c = SessionStatusCoordinator()
        XCTAssertTrue(c.snapshots.isEmpty)
    }

    // MARK: - 2. status subject — 즉시 적용

    func test_statusSubject_appliesStatus() {
        let c = SessionStatusCoordinator()
        c.sendStatusForTesting(sessionId: fixedSid, status: .working)
        // statusSubject는 .receive(on: .main) 으로 비동기 dispatch.
        let exp = expectation(description: "status applied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(c.snapshots[fixedSid]?.agentStatus, .working)
    }

    func test_statusSubject_removeDuplicates_sameValueOnce() {
        let c = SessionStatusCoordinator()
        c.sendStatusForTesting(sessionId: fixedSid, status: .working)
        c.sendStatusForTesting(sessionId: fixedSid, status: .working)
        let exp = expectation(description: "applied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(c.snapshots[fixedSid]?.agentStatus, .working)
    }

    // MARK: - 3. needsInput fast-lane (throttle bypass)

    func test_needsInputSubject_fastLane_appliesImmediately() {
        let c = SessionStatusCoordinator()
        c.sendNeedsInputForTesting(sessionId: fixedSid)
        let exp = expectation(description: "needsInput applied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(c.snapshots[fixedSid]?.agentStatus, .needsInput)
    }

    func test_needsInputSubject_removeDuplicates_sameIdOnce() {
        let c = SessionStatusCoordinator()
        var count = 0
        c.$snapshots.dropFirst().sink { _ in count += 1 }.store(in: &cancellables)
        c.sendNeedsInputForTesting(sessionId: fixedSid)
        c.sendNeedsInputForTesting(sessionId: fixedSid)
        let exp = expectation(description: "applied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        // 중복 제거: snapshots 갱신 1회만.
        XCTAssertEqual(count, 1)
    }

    // MARK: - 4. preview throttle 100ms

    func test_previewSubject_throttle100ms_latestWins() {
        let c = SessionStatusCoordinator()
        c.sendPreviewForTesting(sessionId: fixedSid, preview: "p1")
        c.sendPreviewForTesting(sessionId: fixedSid, preview: "p2")
        c.sendPreviewForTesting(sessionId: fixedSid, preview: "p3")
        let exp = expectation(description: "throttle settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        // throttle latest:true → 마지막 값 p3 가 적용
        XCTAssertEqual(c.snapshots[fixedSid]?.latestPreview, "p3")
    }

    func test_previewSubject_burstSend100times_appliedAtMost12() {
        let c = SessionStatusCoordinator()
        var applyCount = 0
        c.$snapshots.dropFirst().sink { _ in applyCount += 1 }.store(in: &cancellables)
        for i in 0..<100 {
            c.sendPreviewForTesting(sessionId: fixedSid, preview: "p\(i)")
        }
        let exp = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.05) { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)
        // 1초 동안 100건 burst → throttle 100ms → 최대 ~12회 apply
        XCTAssertLessThanOrEqual(applyCount, 12)
    }

    // MARK: - 5. attach observer forward

    func test_attachObserver_forwardsPublishers() {
        let c = SessionStatusCoordinator()
        let obs = SessionStatusObserver(
            policy: NeedsInputPolicyV1(),
            telemetry: NeedsInputTelemetry()
        )
        c.attach(observer: obs)
        let sid = UUID()
        obs.register(sessionId: sid, kind: .claude)
        obs.observe(sessionId: sid, action: .ringBell)
        let exp = expectation(description: "forwarded")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(c.snapshots[sid]?.agentStatus, .needsInput)
    }

    // MARK: - 6. lifecycleHooks attach — terminated → exited

    func test_attachLifecycleHooks_onSessionTerminated_setsExited() {
        let c = SessionStatusCoordinator()
        let hooks = SessionLifecycleHooks()
        c.attach(lifecycleHooks: hooks)
        hooks.onSessionTerminated.send(fixedSid)
        let exp = expectation(description: "exited")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(c.snapshots[fixedSid]?.agentStatus, .exited)
    }

    func test_attachLifecycleHooks_onSessionCreated_createsIdleSnapshot() {
        let c = SessionStatusCoordinator()
        let hooks = SessionLifecycleHooks()
        c.attach(lifecycleHooks: hooks)
        let session = Session(kind: .claude, ptyHandle: nil, cwd: "/tmp")
        hooks.onSessionCreated.send(session)
        let exp = expectation(description: "created")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(c.snapshots[session.id]?.agentStatus, .idle)
    }

    // MARK: - 7. snapshot lookup

    func test_snapshot_for_unknownSessionId_isNil() {
        let c = SessionStatusCoordinator()
        XCTAssertNil(c.snapshot(for: UUID()))
    }
}
