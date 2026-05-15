import XCTest
import Foundation

@MainActor
final class MockSurfaceProvider: AgentViewSurfaceProvider {
    var callCounts: [UUID: Int] = [:]
    var fixedText: String = "viewport-text"
    func readViewportText(paneId: UUID) -> String? {
        callCounts[paneId, default: 0] += 1
        return fixedText
    }
}

@MainActor
final class ViewportPollingTimerTests: XCTestCase {

    private let baseDate = Date(timeIntervalSince1970: 1_778_716_800)

    private struct Bundle {
        let timer: ViewportPollingTimer
        let provider: MockSurfaceProvider
        let store: SessionStatusStore
        let observer: SessionStatusObserver
        let focusedPaneStore: FocusedPaneStore
        let wsId: UUID
        let paneIds: [UUID]
        let sessionIds: [UUID]
    }

    private func makeFixture(focusedIdx: Int = 0, appActive: Bool = true) -> Bundle {
        let provider = MockSurfaceProvider()
        let focusedPaneStore = FocusedPaneStore()
        let observer = SessionStatusObserver(
            policy: NeedsInputPolicyV1(),
            telemetry: NeedsInputTelemetry()
        )
        let store = SessionStatusStore()
        let wsId = UUID()
        var sessionIds: [UUID] = []
        var paneIds: [UUID] = []
        var panes: [Pane] = []
        for i in 0..<20 {
            let sId = UUID()
            let pId = UUID()
            sessionIds.append(sId)
            paneIds.append(pId)
            let tab = Tab(sessionId: sId, kind: .shell, name: Tab.defaultName(for: .shell))
            panes.append(Pane(
                id: pId,
                position: i % 2 == 0 ? .left : .right,
                tabs: [tab],
                activeTabId: tab.id
            ))
            observer.register(sessionId: sId, kind: .shell, at: baseDate)
        }
        let ws = Workspace(
            id: wsId,
            name: "ws",
            cwd: "/tmp",
            panes: panes,
            createdAt: baseDate,
            kind: .normal
        )
        focusedPaneStore.setFocus(workspaceId: wsId, paneId: paneIds[focusedIdx])
        let index = SessionIndex(workspaces: [ws])
        let timer = ViewportPollingTimer(
            selectedWorkspaceIdProvider: { wsId },
            focusedPaneStore: focusedPaneStore,
            provider: provider,
            sessionIndexProvider: { index },
            observer: observer,
            store: store,
            focusedIntervalMs: 250,
            backgroundIntervalMs: 1000,
            isAppActive: { appActive }
        )
        return Bundle(
            timer: timer,
            provider: provider,
            store: store,
            observer: observer,
            focusedPaneStore: focusedPaneStore,
            wsId: wsId,
            paneIds: paneIds,
            sessionIds: sessionIds
        )
    }

    // MARK: - 1. focused 4Hz / background 1Hz 빈도

    func test_focusedPane_polledAt4Hz_when4tickIn1sec() {
        let b = makeFixture(focusedIdx: 0, appActive: true)
        for k in 0..<4 {
            b.timer.tick(now: baseDate.addingTimeInterval(Double(k) * 0.25))
        }
        XCTAssertEqual(b.provider.callCounts[b.paneIds[0]], 4, "focused 4Hz")
        for i in 1..<20 {
            XCTAssertEqual(b.provider.callCounts[b.paneIds[i]] ?? 0, 1, "background pane \(i) 1Hz")
        }
    }

    // MARK: - 2. 1초 평균 23 invocation

    func test_pollingTotal_1sec_equals23() {
        let b = makeFixture(focusedIdx: 0, appActive: true)
        for k in 0..<4 {
            b.timer.tick(now: baseDate.addingTimeInterval(Double(k) * 0.25))
        }
        let total = b.paneIds.reduce(0) { $0 + (b.provider.callCounts[$1] ?? 0) }
        XCTAssertEqual(total, 23, "1 focused × 4Hz + 19 bg × 1Hz")
    }

    // MARK: - 3. app inactive → 모든 surface 1Hz 강등

    func test_appInactive_allBackgroundTier_1Hz() {
        let b = makeFixture(focusedIdx: 0, appActive: false)
        for k in 0..<4 {
            b.timer.tick(now: baseDate.addingTimeInterval(Double(k) * 0.25))
        }
        for i in 0..<20 {
            XCTAssertEqual(b.provider.callCounts[b.paneIds[i]] ?? 0, 1, "pane \(i) 강등 1Hz")
        }
    }

    // MARK: - 4. focused 변경 시 다음 tick (≤250ms) 에 즉시 poll

    func test_focusedPaneChange_nextPollWithin250ms() {
        let b = makeFixture(focusedIdx: 0, appActive: true)
        // t=0 tick: paneIds[0] focused, paneIds[1] background (1Hz) → 둘 다 1회 polled.
        b.timer.tick(now: baseDate)
        XCTAssertEqual(b.provider.callCounts[b.paneIds[0]], 1)
        XCTAssertEqual(b.provider.callCounts[b.paneIds[1]], 1)
        // focused 를 paneIds[1] 로 전환.
        b.focusedPaneStore.setFocus(workspaceId: b.wsId, paneId: b.paneIds[1])
        // t=0.25 tick: 새 focused pane elapsed 250ms == focusedInterval → 즉시 polled.
        b.timer.tick(now: baseDate.addingTimeInterval(0.25))
        XCTAssertEqual(b.provider.callCounts[b.paneIds[1]] ?? 0, 2, "새 focused 가 250ms 안에 polled")
        // 동시에 이전 focused (paneIds[0]) 는 이제 background → 1Hz → 250ms 후엔 미 poll.
        XCTAssertEqual(b.provider.callCounts[b.paneIds[0]], 1, "전 focused 는 background tier 로 강등")
    }

    // MARK: - 5. exited session skip

    func test_exitedSession_isSkipped() {
        let b = makeFixture(focusedIdx: 0, appActive: true)
        b.store.upsert(
            SessionStatusSnapshot.makeInitial(sessionId: b.sessionIds[0])
                .with(agentStatus: .exited)
        )
        b.timer.tick(now: baseDate)
        XCTAssertEqual(b.provider.callCounts[b.paneIds[0]] ?? 0, 0, "exited 미 poll")
    }

    // MARK: - 6. observer wiring — viewportText 가 observer 로 전달

    func test_polling_forwardsViewportTextToObserver() {
        let b = makeFixture(focusedIdx: 0, appActive: true)
        b.provider.fixedText = "polled output"
        b.timer.tick(now: baseDate)
        XCTAssertEqual(b.observer.snapshot(for: b.sessionIds[0])?.latestPreview, "polled output")
    }
}
