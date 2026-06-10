import Foundation

/// Sleep / lid-close hook: drops all WS attachments so push delivery resumes
/// while the machine is asleep. The real `NSWorkspace.willSleep` subscription
/// lives in the app (`PowerEventObserver`); this struct holds the testable
/// invalidation so `DaemonTests` can drive it directly without a real sleep
/// notification.
public struct AttachmentInvalidator: Sendable {
    private let registry: SessionBindRegistry

    public init(registry: SessionBindRegistry) {
        self.registry = registry
    }

    /// Drops all attachments (bindings-only; `lastSeq` preserved). Afterward
    /// `boundClient(forSession:)` is nil, so the WS-attached skip policy evaluates
    /// "not attached" and push is sent.
    public func invalidateAllAttached() async {
        await registry.invalidateAllBindings()
    }
}
