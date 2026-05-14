import XCTest
import Foundation
import Combine

@MainActor
final class SessionStatusObserverTests: XCTestCase {

    private let fixedDate = Date(timeIntervalSince1970: 1_778_716_800)
    private var cancellables: Set<AnyCancellable> = []

    private func makeObserver() -> (SessionStatusObserver, NeedsInputTelemetry) {
        let telemetry = NeedsInputTelemetry()
        let observer = SessionStatusObserver(
            policy: NeedsInputPolicyV1(),
            telemetry: telemetry,
            idleThresholdMs: 500
        )
        return (observer, telemetry)
    }

    // MARK: - 1. 등록 / 초기 상태

    func test_register_initialSnapshotIsIdle() {
        let (obs, _) = makeObserver()
        let sid = UUID()
        obs.register(sessionId: sid, kind: .claude, at: fixedDate)
        let snap = obs.snapshot(for: sid)
        XCTAssertEqual(snap?.agentStatus, .idle)
        XCTAssertEqual(snap?.latestPreview, "")
        XCTAssertEqual(snap?.lastActivityAt, fixedDate)
    }

    // MARK: - 2. claude needsInput 감지

    func test_claude_viewportWithSGRPrompt_yieldsNeedsInput() {
        let (obs, telemetry) = makeObserver()
        let sid = UUID()
        obs.register(sessionId: sid, kind: .claude, at: fixedDate)
        obs.observe(sessionId: sid, viewportText: "\u{1b}[0m❯ ", at: fixedDate.addingTimeInterval(1))
        XCTAssertEqual(obs.snapshot(for: sid)?.agentStatus, .needsInput)
        XCTAssertEqual(telemetry.triggerCountThisMonth, 1)
    }

    // MARK: - 3. claude FN 차단

    func test_claude_plainKoreanFinish_doesNotTriggerNeedsInput() {
        let (obs, _) = makeObserver()
        let sid = UUID()
        obs.register(sessionId: sid, kind: .claude, at: fixedDate)
        obs.observe(sessionId: sid, viewportText: "분석을 마쳤습니다.", at: fixedDate.addingTimeInterval(1))
        XCTAssertNotEqual(obs.snapshot(for: sid)?.agentStatus, .needsInput)
    }

    // MARK: - 4. shell working / idle 전이

    func test_shell_viewportObserve_transitionsToWorking() {
        let (obs, _) = makeObserver()
        let sid = UUID()
        obs.register(sessionId: sid, kind: .shell, at: fixedDate)
        obs.observe(sessionId: sid, viewportText: "abc", at: fixedDate)
        XCTAssertEqual(obs.snapshot(for: sid)?.agentStatus, .working)
    }

    func test_shell_evaluateIdle_at400ms_staysWorking() {
        let (obs, _) = makeObserver()
        let sid = UUID()
        obs.register(sessionId: sid, kind: .shell, at: fixedDate)
        obs.observe(sessionId: sid, viewportText: "abc", at: fixedDate)
        obs.evaluateIdle(at: fixedDate.addingTimeInterval(0.4))
        XCTAssertEqual(obs.snapshot(for: sid)?.agentStatus, .working)
    }

    func test_shell_evaluateIdle_at600ms_transitionsToIdle() {
        let (obs, _) = makeObserver()
        let sid = UUID()
        obs.register(sessionId: sid, kind: .shell, at: fixedDate)
        obs.observe(sessionId: sid, viewportText: "abc", at: fixedDate)
        obs.evaluateIdle(at: fixedDate.addingTimeInterval(0.6))
        XCTAssertEqual(obs.snapshot(for: sid)?.agentStatus, .idle)
    }

    // MARK: - 5. action 처리

    func test_observeAction_ringBell_transitionsToNeedsInput() {
        let (obs, telemetry) = makeObserver()
        let sid = UUID()
        obs.register(sessionId: sid, kind: .claude, at: fixedDate)
        obs.observe(sessionId: sid, action: .ringBell, at: fixedDate)
        XCTAssertEqual(obs.snapshot(for: sid)?.agentStatus, .needsInput)
        XCTAssertEqual(telemetry.triggerCountThisMonth, 1)
    }

    func test_observeAction_commandFinished_transitionsToIdle() {
        let (obs, _) = makeObserver()
        let sid = UUID()
        obs.register(sessionId: sid, kind: .shell, at: fixedDate)
        obs.observe(sessionId: sid, viewportText: "running", at: fixedDate)
        obs.observe(sessionId: sid, action: .commandFinished, at: fixedDate.addingTimeInterval(1))
        XCTAssertEqual(obs.snapshot(for: sid)?.agentStatus, .idle)
    }

    func test_observeAction_promptTitle_updatesPreview() {
        let (obs, _) = makeObserver()
        let sid = UUID()
        obs.register(sessionId: sid, kind: .claude, at: fixedDate)
        obs.observe(sessionId: sid, action: .promptTitle("새 작업"), at: fixedDate)
        XCTAssertEqual(obs.snapshot(for: sid)?.latestPreview, "새 작업")
    }

    // MARK: - 6. publisher emit

    func test_needsInputPublisher_emitsOnTransition() {
        let (obs, _) = makeObserver()
        let sid = UUID()
        obs.register(sessionId: sid, kind: .claude, at: fixedDate)
        var emitted: [UUID] = []
        obs.needsInputPublisher.sink { emitted.append($0) }.store(in: &cancellables)
        obs.observe(sessionId: sid, viewportText: "\u{1b}[0m❯ ", at: fixedDate)
        XCTAssertEqual(emitted, [sid])
    }

    func test_statusPublisher_emitsOnStatusChange() {
        let (obs, _) = makeObserver()
        let sid = UUID()
        obs.register(sessionId: sid, kind: .shell, at: fixedDate)
        var statuses: [AgentStatus] = []
        obs.statusPublisher.sink { statuses.append($0.1) }.store(in: &cancellables)
        obs.observe(sessionId: sid, viewportText: "abc", at: fixedDate)
        obs.evaluateIdle(at: fixedDate.addingTimeInterval(0.6))
        XCTAssertEqual(statuses, [.working, .idle])
    }

    // MARK: - 7. unregister → exited

    func test_unregister_transitionsToExited() {
        let (obs, _) = makeObserver()
        let sid = UUID()
        obs.register(sessionId: sid, kind: .claude, at: fixedDate)
        obs.unregister(sessionId: sid, at: fixedDate.addingTimeInterval(1))
        XCTAssertEqual(obs.snapshot(for: sid)?.agentStatus, .exited)
    }

    // MARK: - 8. corpus 100건 UTF-8 검증

    func test_corpus_100lines_allPreviewsAreValidUtf8_andRawEscFree() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/korean-emoji-corpus.txt")
        let raw = try String(contentsOf: fixtureURL, encoding: .utf8)
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true).map { String($0) }
        XCTAssertEqual(lines.count, 100, "corpus must contain exactly 100 lines")
        let (obs, _) = makeObserver()
        for (idx, line) in lines.enumerated() {
            let sid = UUID()
            obs.register(sessionId: sid, kind: .shell, at: fixedDate)
            obs.observe(sessionId: sid, viewportText: line, at: fixedDate.addingTimeInterval(TimeInterval(idx)))
            let snap = obs.snapshot(for: sid)
            XCTAssertNotNil(snap, "snapshot \(idx)")
            let preview = snap!.latestPreview
            XCTAssertTrue(preview.utf8.allSatisfy { _ in true })
            XCTAssertFalse(preview.contains("\u{1b}"), "preview \(idx) contains raw ESC")
            XCTAssertGreaterThanOrEqual(preview.count, 1, "preview \(idx) is empty")
        }
    }
}
