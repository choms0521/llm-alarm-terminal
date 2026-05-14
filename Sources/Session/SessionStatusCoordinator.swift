import Foundation
import Combine

/// SessionStatusObserver 가 발행한 publisher 3 종을 main thread 에서 소비하여
/// snapshots dict 를 갱신한다. preview 는 throttle 100ms (high-frequency 대응),
/// needsInput 은 fast-lane (throttle bypass, strong signal 즉시 전파),
/// status 는 removeDuplicates 만 적용한다.
///
/// 단방향 invariant: 본 coordinator 는 SessionLifecycleHooks 와 SessionStatusObserver
/// 둘 다의 단일 소비자이며, 반대 방향(coordinator → manager) 의 push 는 없다.
/// lifecycle hook 의 `onSessionTerminated` 도 본 coordinator 가 wire 하여
/// snapshot.agentStatus = .exited 전이를 처리한다.
@MainActor
public final class SessionStatusCoordinator: ObservableObject {
    @Published public private(set) var snapshots: [UUID: SessionStatusSnapshot] = [:]

    private let previewSubject = PassthroughSubject<(UUID, String), Never>()
    private let needsInputSubject = PassthroughSubject<UUID, Never>()
    private let statusSubject = PassthroughSubject<(UUID, AgentStatus), Never>()
    private var cancellables: Set<AnyCancellable> = []

    public init() {
        // (a) preview throttle 100ms (high-frequency 대응)
        previewSubject
            .throttle(for: .milliseconds(100), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] (id, preview) in
                self?.applyPreview(sessionId: id, preview: preview)
            }
            .store(in: &cancellables)

        // (b) needsInput fast-lane: throttle bypass, removeDuplicates 만
        needsInputSubject
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in
                self?.markNeedsInput(sessionId: id)
            }
            .store(in: &cancellables)

        // (c) status: throttle 없음 (저빈도). 동일 (id, status) 중복 제거.
        statusSubject
            .removeDuplicates(by: { $0 == $1 })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (id, status) in
                self?.applyStatus(sessionId: id, status: status)
            }
            .store(in: &cancellables)
    }

    /// SessionStatusObserver 의 3 publisher 를 본 coordinator 의 subject 로 forward.
    /// observer 가 emit 한 (id, preview) / id / (id, status) 가 throttle/fast-lane 을
    /// 거쳐 snapshots dict 에 반영된다.
    public func attach(observer: SessionStatusObserver) {
        observer.previewPublisher
            .sink { [weak self] (id, preview) in self?.previewSubject.send((id, preview)) }
            .store(in: &cancellables)
        observer.needsInputPublisher
            .sink { [weak self] id in self?.needsInputSubject.send(id) }
            .store(in: &cancellables)
        observer.statusPublisher
            .sink { [weak self] (id, status) in self?.statusSubject.send((id, status)) }
            .store(in: &cancellables)
    }

    /// SessionLifecycleHooks 의 onSessionTerminated 를 wire. session 종료 시
    /// .exited 전이 + observer 는 별도로 unregister 호출이 필요.
    public func attach(lifecycleHooks: SessionLifecycleHooks) {
        lifecycleHooks.onSessionTerminated
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in
                self?.statusSubject.send((id, .exited))
            }
            .store(in: &cancellables)
        lifecycleHooks.onSessionCreated
            .receive(on: DispatchQueue.main)
            .sink { [weak self] session in
                self?.upsertInitial(sessionId: session.id)
            }
            .store(in: &cancellables)
    }

    public func snapshot(for sessionId: UUID) -> SessionStatusSnapshot? {
        snapshots[sessionId]
    }

    /// 테스트 anchor: subject 에 직접 send 하여 throttle/fast-lane 동작 검증.
    public func sendPreviewForTesting(sessionId: UUID, preview: String) {
        previewSubject.send((sessionId, preview))
    }

    public func sendNeedsInputForTesting(sessionId: UUID) {
        needsInputSubject.send(sessionId)
    }

    public func sendStatusForTesting(sessionId: UUID, status: AgentStatus) {
        statusSubject.send((sessionId, status))
    }

    // MARK: - Private apply

    private func applyPreview(sessionId: UUID, preview: String) {
        if let existing = snapshots[sessionId] {
            snapshots[sessionId] = existing.with(latestPreview: preview, lastActivityAt: Date())
        } else {
            snapshots[sessionId] = SessionStatusSnapshot(
                sessionId: sessionId,
                agentStatus: .idle,
                latestPreview: preview,
                lastActivityAt: Date()
            )
        }
    }

    private func markNeedsInput(sessionId: UUID) {
        if let existing = snapshots[sessionId] {
            snapshots[sessionId] = existing.with(agentStatus: .needsInput, lastActivityAt: Date())
        } else {
            snapshots[sessionId] = SessionStatusSnapshot(
                sessionId: sessionId,
                agentStatus: .needsInput,
                latestPreview: "",
                lastActivityAt: Date()
            )
        }
    }

    private func applyStatus(sessionId: UUID, status: AgentStatus) {
        if let existing = snapshots[sessionId] {
            snapshots[sessionId] = existing.with(agentStatus: status, lastActivityAt: Date())
        } else {
            snapshots[sessionId] = SessionStatusSnapshot(
                sessionId: sessionId,
                agentStatus: status,
                latestPreview: "",
                lastActivityAt: Date()
            )
        }
    }

    private func upsertInitial(sessionId: UUID) {
        if snapshots[sessionId] == nil {
            snapshots[sessionId] = SessionStatusSnapshot.makeInitial(sessionId: sessionId)
        }
    }
}
