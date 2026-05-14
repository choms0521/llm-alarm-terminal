import XCTest
import Foundation

final class SessionStatusSnapshotTests: XCTestCase {

    private let fixedDate = Date(timeIntervalSince1970: 1_778_716_800)
    private let sid = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    // MARK: - 1. init / 필드 보존

    func test_init_preservesAllFields() {
        let snap = SessionStatusSnapshot(
            sessionId: sid,
            agentStatus: .working,
            latestPreview: "안녕하세요",
            lastActivityAt: fixedDate
        )
        XCTAssertEqual(snap.sessionId, sid)
        XCTAssertEqual(snap.agentStatus, .working)
        XCTAssertEqual(snap.latestPreview, "안녕하세요")
        XCTAssertEqual(snap.lastActivityAt, fixedDate)
    }

    // MARK: - 2. with(...) 빌더

    func test_withAgentStatus_changesOnlyStatus() {
        let snap = SessionStatusSnapshot(
            sessionId: sid,
            agentStatus: .idle,
            latestPreview: "preview",
            lastActivityAt: fixedDate
        )
        let updated = snap.with(agentStatus: .needsInput)
        XCTAssertEqual(updated.agentStatus, .needsInput)
        XCTAssertEqual(updated.sessionId, sid)
        XCTAssertEqual(updated.latestPreview, "preview")
        XCTAssertEqual(updated.lastActivityAt, fixedDate)
    }

    func test_withLatestPreview_changesOnlyPreview() {
        let snap = SessionStatusSnapshot(
            sessionId: sid,
            agentStatus: .working,
            latestPreview: "old",
            lastActivityAt: fixedDate
        )
        let updated = snap.with(latestPreview: "new preview 한국어")
        XCTAssertEqual(updated.latestPreview, "new preview 한국어")
        XCTAssertEqual(updated.agentStatus, .working)
    }

    func test_withLastActivityAt_changesOnlyDate() {
        let snap = SessionStatusSnapshot(
            sessionId: sid,
            agentStatus: .working,
            latestPreview: "preview",
            lastActivityAt: fixedDate
        )
        let later = fixedDate.addingTimeInterval(60)
        let updated = snap.with(lastActivityAt: later)
        XCTAssertEqual(updated.lastActivityAt, later)
        XCTAssertEqual(updated.agentStatus, .working)
        XCTAssertEqual(updated.latestPreview, "preview")
    }

    func test_withMultipleFields_appliesAllChanges() {
        let snap = SessionStatusSnapshot(
            sessionId: sid,
            agentStatus: .idle,
            latestPreview: "",
            lastActivityAt: fixedDate
        )
        let later = fixedDate.addingTimeInterval(120)
        let updated = snap.with(
            agentStatus: .needsInput,
            latestPreview: "input needed",
            lastActivityAt: later
        )
        XCTAssertEqual(updated.agentStatus, .needsInput)
        XCTAssertEqual(updated.latestPreview, "input needed")
        XCTAssertEqual(updated.lastActivityAt, later)
        XCTAssertEqual(updated.sessionId, sid)
    }

    // MARK: - 3. makeInitial

    func test_makeInitial_returnsIdleEmptyPreview() {
        let snap = SessionStatusSnapshot.makeInitial(sessionId: sid, at: fixedDate)
        XCTAssertEqual(snap.sessionId, sid)
        XCTAssertEqual(snap.agentStatus, .idle)
        XCTAssertEqual(snap.latestPreview, "")
        XCTAssertEqual(snap.lastActivityAt, fixedDate)
    }

    // MARK: - 4. Equatable

    func test_equatable_equalForIdenticalValues() {
        let a = SessionStatusSnapshot(
            sessionId: sid,
            agentStatus: .working,
            latestPreview: "p",
            lastActivityAt: fixedDate
        )
        let b = SessionStatusSnapshot(
            sessionId: sid,
            agentStatus: .working,
            latestPreview: "p",
            lastActivityAt: fixedDate
        )
        XCTAssertEqual(a, b)
    }

    func test_equatable_differentSessionId_notEqual() {
        let a = SessionStatusSnapshot(
            sessionId: sid,
            agentStatus: .idle,
            latestPreview: "",
            lastActivityAt: fixedDate
        )
        let b = SessionStatusSnapshot(
            sessionId: UUID(),
            agentStatus: .idle,
            latestPreview: "",
            lastActivityAt: fixedDate
        )
        XCTAssertNotEqual(a, b)
    }

    // MARK: - 5. AgentStatus rawValue 4 cases

    func test_agentStatus_rawValueMapping() {
        XCTAssertEqual(AgentStatus.idle.rawValue, "idle")
        XCTAssertEqual(AgentStatus.working.rawValue, "working")
        XCTAssertEqual(AgentStatus.needsInput.rawValue, "needsInput")
        XCTAssertEqual(AgentStatus.exited.rawValue, "exited")
    }

    // MARK: - 6. SessionStatusStore upsert (Day 1 종료 조건 6번)

    @MainActor
    func test_sessionStatusStore_upsertOneKey() {
        let store = SessionStatusStore()
        XCTAssertEqual(store.snapshots.count, 0)
        let snap = SessionStatusSnapshot.makeInitial(sessionId: sid, at: fixedDate)
        store.upsert(snap)
        XCTAssertEqual(store.snapshots.count, 1)
        XCTAssertEqual(store.snapshot(for: sid), snap)
    }

    @MainActor
    func test_sessionStatusStore_upsertReplacesSameSessionId() {
        let store = SessionStatusStore()
        let initial = SessionStatusSnapshot.makeInitial(sessionId: sid, at: fixedDate)
        store.upsert(initial)
        let updated = initial.with(agentStatus: .working, latestPreview: "abc")
        store.upsert(updated)
        XCTAssertEqual(store.snapshots.count, 1)
        XCTAssertEqual(store.snapshot(for: sid)?.agentStatus, .working)
        XCTAssertEqual(store.snapshot(for: sid)?.latestPreview, "abc")
    }

    @MainActor
    func test_sessionStatusStore_remove() {
        let store = SessionStatusStore()
        store.upsert(SessionStatusSnapshot.makeInitial(sessionId: sid, at: fixedDate))
        XCTAssertEqual(store.snapshots.count, 1)
        store.remove(sessionId: sid)
        XCTAssertEqual(store.snapshots.count, 0)
        XCTAssertNil(store.snapshot(for: sid))
    }
}
