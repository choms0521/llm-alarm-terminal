import Foundation

/// Predicate seam for "is a WS client attached to this session?". `PushSender`
/// sees only this predicate, never the underlying registry, so the skip policy is
/// unit-testable with a mock predicate (no live server required).
public protocol AttachmentQuerying: Sendable {
    func isAttached(_ sessionId: UUID) async -> Bool
}

/// Authoritative adapter: delegates straight to
/// `SessionBindRegistry.boundClient(forSession:) != nil` — a bound client is the
/// definition of "attached". The policy never inspects the source directly.
public struct BindRegistryAttachment: AttachmentQuerying {
    private let registry: SessionBindRegistry

    public init(registry: SessionBindRegistry) {
        self.registry = registry
    }

    public func isAttached(_ sessionId: UUID) async -> Bool {
        await registry.boundClient(forSession: sessionId) != nil
    }
}
