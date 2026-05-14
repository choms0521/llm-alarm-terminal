import XCTest
import Foundation

@MainActor
final class NeedsInputTelemetryTests: XCTestCase {

    private func makeDate(year: Int, month: Int, day: Int = 15) -> Date {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day; c.hour = 12
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    // MARK: - 1. 초기 상태

    func test_initial_triggerCountIsZero() {
        let t = NeedsInputTelemetry()
        XCTAssertEqual(t.triggerCountThisMonth, 0)
        XCTAssertNil(t.lastTriggeredAt)
    }

    // MARK: - 2. record 가산

    func test_record_increments() {
        let t = NeedsInputTelemetry()
        t.record(now: makeDate(year: 2026, month: 5))
        XCTAssertEqual(t.triggerCountThisMonth, 1)
        XCTAssertNotNil(t.lastTriggeredAt)
    }

    func test_record_threeTimes_sameMonth_countsThree() {
        let t = NeedsInputTelemetry()
        let d = makeDate(year: 2026, month: 5)
        t.record(now: d); t.record(now: d); t.record(now: d)
        XCTAssertEqual(t.triggerCountThisMonth, 3)
    }

    // MARK: - 3. 월 경계 cross 리셋

    func test_record_monthBoundaryCross_resetsCounter() {
        let t = NeedsInputTelemetry()
        let may = makeDate(year: 2026, month: 5)
        t.record(now: may); t.record(now: may); t.record(now: may)
        XCTAssertEqual(t.triggerCountThisMonth, 3)
        let june = makeDate(year: 2026, month: 6)
        t.record(now: june)
        XCTAssertEqual(t.triggerCountThisMonth, 1)
    }

    // MARK: - 4. lastTriggeredAt 갱신

    func test_lastTriggeredAt_reflectsLatestRecord() {
        let t = NeedsInputTelemetry()
        let first = makeDate(year: 2026, month: 5)
        let second = first.addingTimeInterval(120)
        t.record(now: first); t.record(now: second)
        XCTAssertEqual(t.lastTriggeredAt, second)
    }
}
