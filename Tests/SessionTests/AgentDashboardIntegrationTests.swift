import XCTest
import Foundation
import Combine

@MainActor
final class AgentDashboardIntegrationTests: XCTestCase {

    private let baseDate = Date(timeIntervalSince1970: 1_778_716_800)
    private var cancellables: Set<AnyCancellable> = []

    private func makeFixture() -> (
        workspaces: [Workspace],
        sessionIds: [UUID],
        snapshots: [UUID: SessionStatusSnapshot]
    ) {
        var workspaces: [Workspace] = []
        var sessionIds: [UUID] = []
        var snapshots: [UUID: SessionStatusSnapshot] = [:]
        for wIdx in 0..<3 {
            var panes: [Pane] = []
            for pIdx in 0..<2 {
                let sId = UUID()
                sessionIds.append(sId)
                let kind: PaneKind = pIdx == 0 ? .claude : .shell
                let tab = Tab(sessionId: sId, kind: kind, name: Tab.defaultName(for: kind))
                panes.append(Pane(
                    position: pIdx == 0 ? .left : .right,
                    tabs: [tab],
                    activeTabId: tab.id
                ))
                let total = wIdx * 2 + pIdx
                snapshots[sId] = SessionStatusSnapshot(
                    sessionId: sId,
                    agentStatus: total == 0 ? .needsInput : .working,
                    latestPreview: "preview-\(total)",
                    lastActivityAt: baseDate.addingTimeInterval(TimeInterval(total))
                )
            }
            workspaces.append(Workspace(
                name: "ws-\(wIdx)",
                cwd: "/tmp",
                panes: panes,
                createdAt: baseDate,
                kind: .normal
            ))
        }
        return (workspaces, sessionIds, snapshots)
    }

    // MARK: - 1. SessionStatusObserver → Coordinator → snapshots 통합

    func test_observerPublishers_forwardedThroughCoordinatorToSnapshotsDict() {
        let coordinator = SessionStatusCoordinator()
        let observer = SessionStatusObserver(
            policy: NeedsInputPolicyV1(),
            telemetry: NeedsInputTelemetry()
        )
        coordinator.attach(observer: observer)

        let sid = UUID()
        observer.register(sessionId: sid, kind: .claude, at: baseDate)
        observer.observe(sessionId: sid, action: .ringBell, at: baseDate)

        let exp = expectation(description: "needsInput propagates")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertEqual(coordinator.snapshots[sid]?.agentStatus, .needsInput)
    }

    // MARK: - 2. ViewModel × Coordinator × Manager workspaces 통합

    func test_viewModel_joinsCoordinatorSnapshotsAndWorkspaces() {
        let (workspaces, sessionIds, snapshots) = makeFixture()
        let coordinator = SessionStatusCoordinator()
        for sid in sessionIds {
            coordinator.sendStatusForTesting(sessionId: sid, status: snapshots[sid]!.agentStatus)
            coordinator.sendPreviewForTesting(sessionId: sid, preview: snapshots[sid]!.latestPreview)
        }
        let vm = AgentDashboardViewModel()
        let exp = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        let index = SessionIndex(workspaces: workspaces)
        vm.refresh(
            snapshots: coordinator.snapshots,
            workspaces: workspaces,
            sessionIndex: index
        )
        XCTAssertEqual(vm.cards.count, 6, "6 sessions all rendered")
    }

    // MARK: - 3. filter=needsInput 통합

    func test_viewModel_filterNeedsInput_yieldsOnlyMatching() {
        let (workspaces, _, snapshots) = makeFixture()
        let vm = AgentDashboardViewModel()
        vm.filter = .needsInput
        let index = SessionIndex(workspaces: workspaces)
        vm.refresh(snapshots: snapshots, workspaces: workspaces, sessionIndex: index)
        XCTAssertTrue(vm.cards.allSatisfy { $0.snapshot.agentStatus == .needsInput })
        XCTAssertEqual(vm.cards.count, 1)
    }

    // MARK: - 4. claudeOnly 필터 통합

    func test_viewModel_filterClaudeOnly_excludesShellPanes() {
        let (workspaces, _, snapshots) = makeFixture()
        let vm = AgentDashboardViewModel()
        vm.filter = .claudeOnly
        let index = SessionIndex(workspaces: workspaces)
        vm.refresh(snapshots: snapshots, workspaces: workspaces, sessionIndex: index)
        XCTAssertEqual(vm.cards.count, 3, "3 claude panes (top of each workspace)")
        XCTAssertTrue(vm.cards.allSatisfy { $0.paneKind == .claude })
    }

    // MARK: - 5. sort statusFirst 통합

    func test_viewModel_sortStatusFirst_yieldsNeedsInputThenWorking() {
        let (workspaces, _, snapshots) = makeFixture()
        let vm = AgentDashboardViewModel()
        vm.sortOrder = .statusFirst
        let index = SessionIndex(workspaces: workspaces)
        vm.refresh(snapshots: snapshots, workspaces: workspaces, sessionIndex: index)
        XCTAssertEqual(vm.cards.first?.snapshot.agentStatus, .needsInput)
    }

    // MARK: - 6. lifecycle hook → exited 전이 통합

    func test_lifecycleHooks_terminated_propagatesToSnapshots() {
        let coordinator = SessionStatusCoordinator()
        let hooks = SessionLifecycleHooks()
        coordinator.attach(lifecycleHooks: hooks)
        let sid = UUID()
        hooks.onSessionCreated.send(Session(kind: .claude, ptyHandle: nil, cwd: "/tmp", workspaceId: nil, paneId: nil, env: [:]))
        hooks.onSessionTerminated.send(sid)
        let exp = expectation(description: "terminated propagated")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(coordinator.snapshots[sid]?.agentStatus, .exited)
    }
}
