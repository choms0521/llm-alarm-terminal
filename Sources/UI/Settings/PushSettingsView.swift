import SwiftUI
import Combine

/// Holds the push policy behind the settings toggle. P5 ships a single toggle as
/// the entry point; the full settings IA arrives with the P6 pairing UI.
@MainActor
final class PushSettingsModel: ObservableObject {
    @Published var skipWhenAttached: Bool

    init(config: PushPolicyConfig = PushPolicyConfig()) {
        self.skipWhenAttached = config.skipWhenAttached
    }

    /// The policy derived from the toggle state — what `PushSender` reads.
    var config: PushPolicyConfig {
        PushPolicyConfig(skipWhenAttached: skipWhenAttached)
    }
}

/// Minimal push settings entry point: one toggle bound to
/// `PushPolicyConfig.skipWhenAttached`.
struct PushSettingsView: View {
    @ObservedObject var model: PushSettingsModel

    var body: some View {
        Form {
            Toggle("연결 중일 때 푸시 건너뛰기", isOn: $model.skipWhenAttached)
        }
        .padding()
    }
}
