import Foundation

/// Decides whether to push and delegates delivery to a `PushTransport`.
///
/// The WS-attached skip policy is evaluated behind an injected
/// `AttachmentQuerying` predicate (the foreground user already reads the live WS
/// stream, so push is skipped while attached unless the toggle is off). The 4KB
/// ceiling is enforced inside the codec; on an oversized payload the sender
/// rejects (logs PUSH_PAYLOAD_TOO_LARGE) and never calls the transport.
public actor PushSender {
    private let transport: any PushTransport
    private let attachment: any AttachmentQuerying
    private let config: PushPolicyConfig

    /// Testable reject surface: the last reject code and a running count, set
    /// alongside the `PushLog.error` emission so the reject path is assertable
    /// without capturing os_log.
    public private(set) var rejectedCount = 0
    public private(set) var lastRejectCode: String?

    public init(
        transport: any PushTransport,
        attachment: any AttachmentQuerying,
        config: PushPolicyConfig
    ) {
        self.transport = transport
        self.attachment = attachment
        self.config = config
    }

    public func send(_ env: PushEnvelope, target: PushTarget) async {
        // 1) WS-attached skip: foreground user reads the live WS stream.
        if config.skipWhenAttached, await attachment.isAttached(env.sessionId) {
            return
        }
        // 2) encode + 4KB reject (validator lives inside the codec).
        let data: Data
        do {
            data = try PushEnvelopeCodec.encode(env)
        } catch {
            let code = (error as? PushError)?.code ?? "PUSH_ENCODE_FAILED"
            PushLog.error(code)
            rejectedCount += 1
            lastRejectCode = code
            return   // reject: transport is never called
        }
        // 3) delegate to transport (P5: mock; P6/S1: real FCM/APNs swap-in).
        await transport.send(data, target: target, sessionId: env.sessionId)
    }
}
