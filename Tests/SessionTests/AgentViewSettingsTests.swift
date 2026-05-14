import XCTest
import Foundation
import AnyCodable

@MainActor
final class AgentViewSettingsTests: XCTestCase {

    // MARK: - 1. default 값

    func test_default_isLastActivityAtDescAndAll() {
        let s = AgentViewSettings()
        XCTAssertEqual(s.sortOrder, .lastActivityAtDesc)
        XCTAssertEqual(s.filter, .all)
    }

    // MARK: - 2. encoded → decode roundtrip

    func test_encodedDecoded_roundtrip() {
        let original = AgentViewSettings(sortOrder: .statusFirst, filter: .needsInput)
        let merged = original.encoded(merging: nil)
        let decoded = AgentViewSettings.decode(from: merged)
        XCTAssertEqual(decoded, original)
    }

    func test_decode_missingKey_returnsDefault() {
        let decoded = AgentViewSettings.decode(from: nil)
        XCTAssertEqual(decoded, AgentViewSettings())
    }

    func test_decode_emptyDict_returnsDefault() {
        let decoded = AgentViewSettings.decode(from: [:])
        XCTAssertEqual(decoded, AgentViewSettings())
    }

    // MARK: - 3. merge 보존

    func test_encoded_mergingExistingKeys_preservesOthers() {
        let existing: [String: AnyCodable] = ["other.key": AnyCodable("keep me")]
        let s = AgentViewSettings(sortOrder: .workspaceName, filter: .claudeOnly)
        let merged = s.encoded(merging: existing)
        XCTAssertNotNil(merged["other.key"])
        XCTAssertNotNil(merged[AgentViewSettings.extraFieldKey])
        // re-decode 가 동일 값 반환
        let decoded = AgentViewSettings.decode(from: merged)
        XCTAssertEqual(decoded, s)
    }

    // MARK: - 4. sort order 4 case 인코딩

    func test_allSortOrders_roundtrip() {
        for order in AgentSortOrder.allCases {
            let s = AgentViewSettings(sortOrder: order, filter: .all)
            let merged = s.encoded(merging: nil)
            let decoded = AgentViewSettings.decode(from: merged)
            XCTAssertEqual(decoded.sortOrder, order, "sort \(order)")
        }
    }

    // MARK: - 5. filter 4 case 인코딩

    func test_allFilterOptions_roundtrip() {
        for filter in AgentFilterOption.allCases {
            let s = AgentViewSettings(sortOrder: .lastActivityAtDesc, filter: filter)
            let merged = s.encoded(merging: nil)
            let decoded = AgentViewSettings.decode(from: merged)
            XCTAssertEqual(decoded.filter, filter, "filter \(filter)")
        }
    }

    // MARK: - 6. extraFieldKey 정확성

    func test_extraFieldKey_isAgentViewSettings() {
        XCTAssertEqual(AgentViewSettings.extraFieldKey, "agentView.settings")
    }
}
