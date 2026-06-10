import XCTest
import Foundation

/// Day 6 acceptance: the push settings toggle drives `PushPolicyConfig`.
@MainActor
final class PushSettingsTests: XCTestCase {

    /// Toggle off → the derived config has `skipWhenAttached == false`.
    func testToggleOffProducesSkipFalseConfig() {
        let model = PushSettingsModel(config: PushPolicyConfig(skipWhenAttached: true))
        XCTAssertTrue(model.config.skipWhenAttached)

        model.skipWhenAttached = false   // simulate the toggle turning off
        XCTAssertFalse(model.config.skipWhenAttached)
    }

    /// Toggle on → the derived config has `skipWhenAttached == true`.
    func testToggleOnProducesSkipTrueConfig() {
        let model = PushSettingsModel(config: PushPolicyConfig(skipWhenAttached: false))
        model.skipWhenAttached = true
        XCTAssertTrue(model.config.skipWhenAttached)
    }
}
