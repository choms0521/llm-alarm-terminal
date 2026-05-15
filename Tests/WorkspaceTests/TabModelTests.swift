import XCTest
import Foundation
import AnyCodable

/// P3.5 Day 2 — Tab 모델 단위 테스트.
final class TabModelTests: XCTestCase {

    private let fixedDate = Date(timeIntervalSince1970: 1_778_716_800)

    // MARK: - Codable round-trip

    func test_roundTrip_basic_preservesAllFields() throws {
        let tab = Tab(
            id: UUID(),
            sessionId: UUID(),
            kind: .claude,
            name: "Claude",
            createdAt: fixedDate
        )
        let restored = try roundTrip(tab)
        XCTAssertEqual(restored, tab)
    }

    func test_roundTrip_nilSessionId_preserved() throws {
        let tab = Tab(sessionId: nil, kind: .shell, name: "셸", createdAt: fixedDate)
        let restored = try roundTrip(tab)
        XCTAssertNil(restored.sessionId)
        XCTAssertEqual(restored.kind, .shell)
        XCTAssertEqual(restored.name, "셸")
    }

    // MARK: - extraFields forward-compat

    func test_forwardCompat_unknownField_preservedToExtraFields() throws {
        let json = """
        {
            "id": "44444444-4444-4444-4444-444444444444",
            "sessionId": null,
            "kind": "claude",
            "name": "Claude",
            "createdAt": "2026-05-15T00:00:00Z",
            "experimentalFlag": true,
            "futureScore": 7
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let tab = try decoder.decode(Tab.self, from: json)

        XCTAssertEqual(tab.extraFields?["experimentalFlag"]?.value as? Bool, true)
        XCTAssertEqual(tab.extraFields?["futureScore"]?.value as? Int, 7)

        let restored = try roundTrip(tab)
        XCTAssertEqual(restored.extraFields?["experimentalFlag"]?.value as? Bool, true)
        XCTAssertEqual(restored.extraFields?["futureScore"]?.value as? Int, 7)
    }

    // MARK: - with(...) immutable builder

    func test_with_sessionIdSomeNil_explicitlyClears() {
        let tab = Tab(sessionId: UUID(), kind: .claude, name: "Claude", createdAt: fixedDate)
        let cleared = tab.with(sessionId: .some(nil))
        XCTAssertNil(cleared.sessionId)
        XCTAssertEqual(cleared.id, tab.id, "다른 필드 보존")
        XCTAssertEqual(cleared.kind, .claude)
    }

    func test_with_nilArgument_preservesExistingSessionId() {
        let existing = UUID()
        let tab = Tab(sessionId: existing, kind: .claude, name: "Claude", createdAt: fixedDate)
        let same = tab.with()
        XCTAssertEqual(same.sessionId, existing, "nil 인자는 기존 값 유지")
    }

    func test_with_name_updatesOnlyName() {
        let tab = Tab(kind: .shell, name: "셸", createdAt: fixedDate)
        let renamed = tab.with(name: "내 셸")
        XCTAssertEqual(renamed.name, "내 셸")
        XCTAssertEqual(renamed.id, tab.id)
        XCTAssertEqual(renamed.kind, .shell)
    }

    // MARK: - defaultName

    func test_defaultName_claude_isClaude() {
        XCTAssertEqual(Tab.defaultName(for: .claude), "Claude")
    }

    func test_defaultName_shell_isKoreanShell() {
        XCTAssertEqual(Tab.defaultName(for: .shell), "셸")
    }

    // MARK: - Helpers

    private func roundTrip(_ tab: Tab) throws -> Tab {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(tab)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Tab.self, from: data)
    }
}
