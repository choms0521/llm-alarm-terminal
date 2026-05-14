import Foundation
import Combine

/// libghostty action_cb 가 발행하는 high-level 시그널을 정규화한 enum.
/// 4 known tag (RING_BELL / COMMAND_FINISHED / PROMPT_TITLE / PROGRESS_REPORT)
/// 만 매핑한다. unknown tag 는 SessionActionRouter 가 pass-through 정책으로
/// 처리하므로 observer 까지 전달되지 않는다.
public enum ObservedAction: Sendable, Equatable {
    case ringBell
    case commandFinished
    case promptTitle(String)
    case progressReport
}

/// viewport text + action callback 을 받아 SessionStatusSnapshot 을 파생한다.
/// 멀티 세션을 한 인스턴스가 관리하며, 각 세션의 마지막 snapshot 과 lastViewportAt
/// 을 보관한다. 외부 콜러는 publisher 3종 (preview / needsInput / status) 을
/// 구독하여 SessionStatusCoordinator 의 throttle + fast-lane 으로 전달한다.
///
/// shell 의 working/idle 판정: viewport 갱신 시 즉시 .working 전이. 이후 별도
/// `evaluateIdle(at:)` tick 이 idleThreshold(500ms) 초과를 detect 하면 .idle 전이.
@MainActor
public final class SessionStatusObserver {
    public let previewPublisher = PassthroughSubject<(UUID, String), Never>()
    public let needsInputPublisher = PassthroughSubject<UUID, Never>()
    public let statusPublisher = PassthroughSubject<(UUID, AgentStatus), Never>()

    private let policy: NeedsInputPolicy
    private let telemetry: NeedsInputTelemetry
    private let idleThresholdMs: Int

    private struct State {
        var kind: SessionKind
        var ringBuffer: String
        var lastViewportAt: Date?
        var lastSnapshot: SessionStatusSnapshot
    }
    private var states: [UUID: State] = [:]

    public init(
        policy: NeedsInputPolicy,
        telemetry: NeedsInputTelemetry,
        idleThresholdMs: Int = 500
    ) {
        self.policy = policy
        self.telemetry = telemetry
        self.idleThresholdMs = idleThresholdMs
    }

    public func register(sessionId: UUID, kind: SessionKind, at now: Date = Date()) {
        states[sessionId] = State(
            kind: kind,
            ringBuffer: "",
            lastViewportAt: nil,
            lastSnapshot: SessionStatusSnapshot.makeInitial(sessionId: sessionId, at: now)
        )
    }

    public func unregister(sessionId: UUID, at now: Date = Date()) {
        guard var state = states[sessionId] else { return }
        let oldSnap = state.lastSnapshot
        let newSnap = oldSnap.with(agentStatus: .exited, lastActivityAt: now)
        state.lastSnapshot = newSnap
        states[sessionId] = state
        if oldSnap.agentStatus != .exited {
            statusPublisher.send((sessionId, .exited))
        }
    }

    public func snapshot(for sessionId: UUID) -> SessionStatusSnapshot? {
        states[sessionId]?.lastSnapshot
    }

    public var registeredSessionIds: [UUID] { Array(states.keys) }

    /// viewport polling tick 마다 호출. 새 viewport text 를 4 KiB ring buffer 의
    /// 최신 영역으로 교체하고, claude 세션은 NeedsInputPolicy.detect 를 적용한다.
    /// shell 세션은 viewport 갱신 자체로 .working 전이.
    public func observe(sessionId: UUID, viewportText: String, at now: Date = Date()) {
        guard var state = states[sessionId] else { return }
        if state.lastSnapshot.agentStatus == .exited { return }

        Self.replaceRing(&state.ringBuffer, with: viewportText, cap: 4096)
        state.lastViewportAt = now

        let oldSnap = state.lastSnapshot
        var newStatus = oldSnap.agentStatus

        switch state.kind {
        case .claude:
            if policy.detect(in: state.ringBuffer) {
                newStatus = .needsInput
            } else {
                newStatus = .working
            }
        case .shell:
            newStatus = .working
        }

        let newSnap = oldSnap.with(
            agentStatus: newStatus,
            latestPreview: viewportText,
            lastActivityAt: now
        )
        state.lastSnapshot = newSnap
        states[sessionId] = state

        previewPublisher.send((sessionId, newSnap.latestPreview))
        if newStatus == .needsInput, oldSnap.agentStatus != .needsInput {
            telemetry.record(now: now)
            needsInputPublisher.send(sessionId)
        }
        if newStatus != oldSnap.agentStatus {
            statusPublisher.send((sessionId, newStatus))
        }
    }

    /// action_cb 가 발행한 high-level 시그널을 SessionStatusSnapshot 으로 환원.
    /// RING_BELL → needsInput 강신호 (telemetry.record),
    /// COMMAND_FINISHED → idle 전이,
    /// PROMPT_TITLE → preview 만 갱신,
    /// PROGRESS_REPORT → working 전이.
    public func observe(sessionId: UUID, action: ObservedAction, at now: Date = Date()) {
        guard var state = states[sessionId] else { return }
        if state.lastSnapshot.agentStatus == .exited { return }

        let oldSnap = state.lastSnapshot
        var newStatus = oldSnap.agentStatus
        var newPreview = oldSnap.latestPreview
        var needsInputFired = false

        switch action {
        case .ringBell:
            newStatus = .needsInput
            needsInputFired = (oldSnap.agentStatus != .needsInput)
        case .commandFinished:
            newStatus = .idle
        case .promptTitle(let title):
            newPreview = title
        case .progressReport:
            newStatus = .working
            state.lastViewportAt = now
        }

        let newSnap = oldSnap.with(
            agentStatus: newStatus,
            latestPreview: newPreview,
            lastActivityAt: now
        )
        state.lastSnapshot = newSnap
        states[sessionId] = state

        if newPreview != oldSnap.latestPreview {
            previewPublisher.send((sessionId, newPreview))
        }
        if needsInputFired {
            telemetry.record(now: now)
            needsInputPublisher.send(sessionId)
        }
        if newStatus != oldSnap.agentStatus {
            statusPublisher.send((sessionId, newStatus))
        }
    }

    /// shell 세션에 한해 idleThreshold 초과 시 working → idle 전이.
    /// claude 의 needsInput 은 사용자 응답 전까지 보존되므로 본 메서드가 건드리지 않는다.
    public func evaluateIdle(at now: Date = Date()) {
        for (id, state) in states {
            guard state.kind == .shell,
                  state.lastSnapshot.agentStatus == .working,
                  let last = state.lastViewportAt else { continue }
            let elapsed = now.timeIntervalSince(last) * 1000
            if elapsed >= Double(idleThresholdMs) {
                var s = state
                let newSnap = s.lastSnapshot.with(agentStatus: .idle, lastActivityAt: now)
                s.lastSnapshot = newSnap
                states[id] = s
                statusPublisher.send((id, .idle))
            }
        }
    }

    /// ring buffer 교체 전략: viewport snapshot 은 항상 마지막 화면 전체이므로
    /// 누적이 아니라 replace. 4 KiB 초과분은 tail 만 보존하여 policy.detect 의
    /// 마지막 80 bytes scan 윈도우가 항상 viewport 최하단 영역에 위치하게 한다.
    private static func replaceRing(_ buffer: inout String, with newText: String, cap: Int) {
        if newText.utf8.count <= cap {
            buffer = newText
            return
        }
        let bytes = Array(newText.utf8)
        let tail = bytes.suffix(cap)
        buffer = String(decoding: tail, as: UTF8.self)
    }
}
