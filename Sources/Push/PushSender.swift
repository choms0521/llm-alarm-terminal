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
    /// revoked 디바이스 push 발신 제외 seam(P6b §5.6). nil이면 제외 필터를 적용하지 않는다
    /// (기존 호출부 무변경 — sendIfNotRevoked를 쓰지 않는 경로는 기존 send 그대로 동작).
    private let revocationSink: (any PushRevocationSink)?

    /// Testable reject surface: the last reject code and a running count, set
    /// alongside the `PushLog.error` emission so the reject path is assertable
    /// without capturing os_log.
    public private(set) var rejectedCount = 0
    public private(set) var lastRejectCode: String?
    /// revoked 디바이스로의 발신이 필터에서 제외된 누적 횟수(P6b §5.6 — transport 미호출 측정용).
    public private(set) var excludedCount = 0

    public init(
        transport: any PushTransport,
        attachment: any AttachmentQuerying,
        config: PushPolicyConfig,
        revocationSink: (any PushRevocationSink)? = nil
    ) {
        self.transport = transport
        self.attachment = attachment
        self.config = config
        self.revocationSink = revocationSink
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

    /// 발신 필터(P6b §5.6): revoked 디바이스 target은 transport에 넘기지 않는다. 미래 push 발신
    /// 호출자가 쓸 seam이며, 현재는 LifecycleE2ETests가 직접 호출해 "revoked는 발신 제외"를 측정한다
    /// (transport 미호출 + excludedCount +1). revocationSink가 nil이면 제외 없이 send로 폴백한다.
    public func sendIfNotRevoked(_ env: PushEnvelope, target: PushTarget, deviceId: UUID) async {
        if let revocationSink, await revocationSink.isRevoked(deviceId: deviceId) {
            excludedCount += 1   // 거부 카운터 — transport 미호출(revoked 디바이스에 push 전송 안 함)
            return
        }
        await send(env, target: target)   // 기존 send 경로(WS-attached skip + 4KB + transport)
    }
}
