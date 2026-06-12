import Foundation
import Network

/// 6자리 코드 페어링의 claim 측 경량 loopback WS 클라이언트(§5.5). 토큰이 아직 없는
/// 디바이스가 pre-auth pairing.claim 연결을 열어 코드를 제출하고 PairingPayload(secret 포함)를
/// 받는다.
///
/// 인증 클라이언트(WSClient)와의 차이: Bearer/nonce를 보내지 않고 claim 식별 헤더
/// `X-Pair-Claim: 1`만 첨부한다. 서버 게이트 ①은 이 시그니처를 claim 의도로 인식해 accept하되
/// 연결을 carry/승격하지 않는다. claim은 secret만 받고 연결을 닫는다 — 운영 envelope을 보내려면
/// 받은 secret으로 별도 인증 connect(WSClient)를 새로 맺어야 한다(claim 채널과 운영 채널 분리).
public final class PairingClaimClient {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.choms0521.ClaudeAlarmTerminal.pairing-claim-client")

    public init(host: String = "127.0.0.1", port: UInt16) {
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        // claim 전용 식별 헤더만 첨부한다(Bearer/nonce 없음 — 토큰 미보유 pre-auth 연결).
        ws.setAdditionalHeaders([(name: "X-Pair-Claim", value: "1")])
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        let url = URL(string: "ws://\(host):\(port)/")!
        connection = NWConnection(to: .url(url), using: params)
    }

    /// claim 교환의 결과. 성공 시 PairingPayload, 실패 시 서버가 보낸 PAIRING_CODE_* 에러 코드.
    public enum ClaimOutcome: Sendable, Equatable {
        case success(PairingPayload)
        case rejected(code: String)
        case failed(String)
    }

    /// 6자리 코드를 제출하고 응답(pairing.response 또는 error)을 기다린다. 연결 수립 →
    /// pairing.claim 송신 → 첫 응답 envelope 1개를 수신해 결과로 변환한 뒤 연결을 닫는다.
    public func claim(code: String, timeout: TimeInterval = 5) async -> ClaimOutcome {
        do {
            try await connectReady(timeout: timeout)
        } catch {
            return .failed("connect failed: \(error)")
        }
        let payload = #"{"code":"\#(code)"}"#
        let claimEnv = WSEnvelope(seq: 1, actor: EnvelopeActor(deviceId: "pairing-claim-client"),
                                  kind: .pairingClaim, text: payload)
        let outcome = await withCheckedContinuation { (cont: CheckedContinuation<ClaimOutcome, Never>) in
            let resumed = ClaimOnce()
            receiveFirstResponse { result in
                if resumed.fire() { cont.resume(returning: result) }
            }
            send(claimEnv)
            queue.asyncAfter(deadline: .now() + timeout) {
                if resumed.fire() { cont.resume(returning: .failed("claim response timeout")) }
            }
        }
        connection.cancel()
        return outcome
    }

    private func connectReady(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let resumed = ClaimOnce()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.fire() { cont.resume() }
                case .failed(let error), .waiting(let error):
                    if resumed.fire() { cont.resume(throwing: error) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                if resumed.fire() { cont.resume(throwing: URLError(.timedOut)) }
            }
        }
    }

    /// 첫 응답 envelope 1개를 수신해 ClaimOutcome으로 변환한다. pairing.response면 payload를
    /// 디코드하고, error면 code를 rejected로 옮긴다.
    private func receiveFirstResponse(_ onOutcome: @escaping (ClaimOutcome) -> Void) {
        connection.receiveMessage { content, _, _, error in
            if let error {
                onOutcome(.failed("receive error: \(error)"))
                return
            }
            guard let content, let env = try? EnvelopeCodec.decode(content) else {
                onOutcome(.failed("undecodable response"))
                return
            }
            switch env.kind {
            case .pairingResponse:
                guard let payload = try? PairingCodec.decodeJSON(env.payload) else {
                    onOutcome(.failed("pairing response payload undecodable"))
                    return
                }
                onOutcome(.success(payload))
            case .error:
                onOutcome(.rejected(code: env.code ?? "UNKNOWN"))
            default:
                onOutcome(.failed("unexpected response kind: \(env.kind.rawValue)"))
            }
        }
    }

    private func send(_ envelope: WSEnvelope) {
        guard let data = try? EnvelopeCodec.encode(envelope) else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "send", metadata: [meta])
        connection.send(content: data, contentContext: context, isComplete: true,
                        completion: .contentProcessed { _ in })
    }
}

/// 연속 콜백에서 continuation을 정확히 1회만 resume하기 위한 one-shot 가드.
private final class ClaimOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
