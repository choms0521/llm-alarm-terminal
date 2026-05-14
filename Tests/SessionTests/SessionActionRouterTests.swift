import XCTest
import Foundation
import Combine

@MainActor
final class SessionActionRouterTests: XCTestCase {

    private var cancellables: Set<AnyCancellable> = []

    private func makeFixture() -> (
        router: SessionActionRouter,
        observer: SessionStatusObserver,
        paneId: UUID,
        sessionId: UUID,
        userdata: UnsafeMutableRawPointer
    ) {
        let observer = SessionStatusObserver(
            policy: NeedsInputPolicyV1(),
            telemetry: NeedsInputTelemetry()
        )
        let paneId = UUID()
        let sessionId = UUID()
        observer.register(sessionId: sessionId, kind: .claude)
        let dummy = UnsafeMutableRawPointer(bitPattern: 0xC0FFEE)!
        let router = SessionActionRouter(
            observer: observer,
            resolvePaneId: { ud in ud == dummy ? paneId : nil },
            resolveSessionId: { pid in pid == paneId ? sessionId : nil }
        )
        return (router, observer, paneId, sessionId, dummy)
    }

    // MARK: - 1. 4 known tag 변환

    func test_dispatch_ringBell_transitionsToNeedsInput() {
        let fix = makeFixture()
        fix.router.dispatch(tag: .ringBell, surfaceUserdata: fix.userdata, payload: ActionPayload())
        XCTAssertEqual(fix.observer.snapshot(for: fix.sessionId)?.agentStatus, .needsInput)
    }

    func test_dispatch_commandFinished_transitionsToIdle() {
        let fix = makeFixture()
        // working 으로 먼저 보낸 뒤 commandFinished 로 idle.
        fix.observer.observe(sessionId: fix.sessionId, viewportText: "abc")
        fix.router.dispatch(tag: .commandFinished, surfaceUserdata: fix.userdata, payload: ActionPayload())
        XCTAssertEqual(fix.observer.snapshot(for: fix.sessionId)?.agentStatus, .idle)
    }

    func test_dispatch_promptTitle_updatesPreview() {
        let fix = makeFixture()
        fix.router.dispatch(
            tag: .promptTitle,
            surfaceUserdata: fix.userdata,
            payload: ActionPayload(promptTitle: "새 작업")
        )
        XCTAssertEqual(fix.observer.snapshot(for: fix.sessionId)?.latestPreview, "새 작업")
    }

    func test_dispatch_progressReport_transitionsToWorking() {
        let fix = makeFixture()
        fix.router.dispatch(tag: .progressReport, surfaceUserdata: fix.userdata, payload: ActionPayload())
        XCTAssertEqual(fix.observer.snapshot(for: fix.sessionId)?.agentStatus, .working)
    }

    // MARK: - 2. unknown tag pass-through

    func test_dispatch_unknownTag_incrementsCountAndNoObserve() {
        let fix = makeFixture()
        let initialSnap = fix.observer.snapshot(for: fix.sessionId)
        fix.router.dispatch(
            tag: .unknown(rawValue: 9999),
            surfaceUserdata: fix.userdata,
            payload: ActionPayload()
        )
        XCTAssertEqual(fix.router.unknownActionCount, 1)
        XCTAssertEqual(fix.observer.snapshot(for: fix.sessionId), initialSnap)
    }

    func test_dispatch_unknownTag_multipleIncrements() {
        let fix = makeFixture()
        for raw in [1000, 1001, 1002] {
            fix.router.dispatch(
                tag: .unknown(rawValue: UInt32(raw)),
                surfaceUserdata: fix.userdata,
                payload: ActionPayload()
            )
        }
        XCTAssertEqual(fix.router.unknownActionCount, 3)
    }

    // MARK: - 3. paneId / sessionId resolve 실패

    func test_dispatch_unknownSurfaceUserdata_silentlyDropped() {
        let fix = makeFixture()
        let initialSnap = fix.observer.snapshot(for: fix.sessionId)
        let unknownUd = UnsafeMutableRawPointer(bitPattern: 0xDEADBEEF)!
        fix.router.dispatch(tag: .ringBell, surfaceUserdata: unknownUd, payload: ActionPayload())
        XCTAssertEqual(fix.observer.snapshot(for: fix.sessionId), initialSnap)
        XCTAssertEqual(fix.router.unknownActionCount, 0)
    }

    func test_dispatch_nilUserdata_silentlyDropped() {
        let fix = makeFixture()
        let initialSnap = fix.observer.snapshot(for: fix.sessionId)
        fix.router.dispatch(tag: .ringBell, surfaceUserdata: nil, payload: ActionPayload())
        XCTAssertEqual(fix.observer.snapshot(for: fix.sessionId), initialSnap)
    }

    // MARK: - 4. resetUnknownActionCount

    func test_resetUnknownActionCount() {
        let fix = makeFixture()
        fix.router.dispatch(tag: .unknown(rawValue: 1), surfaceUserdata: fix.userdata, payload: ActionPayload())
        XCTAssertEqual(fix.router.unknownActionCount, 1)
        fix.router.resetUnknownActionCount()
        XCTAssertEqual(fix.router.unknownActionCount, 0)
    }
}
