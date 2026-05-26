import AppKit
import Foundation
import os

/// 동적 빈도 viewport polling — focused pane 4Hz / background pane 1Hz.
///
/// 평균 호출량 (1 focused + 19 background): 23Hz. 정적 80Hz (20 surface × 4Hz)
/// 대비 71% 절감. NSApp.isActive == false 인 경우 모든 surface 가 1Hz 로 강등된다.
///
/// CRITICAL invariant: `ghostty_surface_read_text` 호출은 반드시 `defer`
/// 블록으로 `ghostty_surface_free_text` 와 1:1 짝지어진다. 본 timer 는 그 호출을
/// `AgentViewSurfaceProvider` 에 위임하며, 실제 GhosttyKit 호출 코드는
/// `GhosttyViewportProvider.swift` 에 격리되어 SessionTests target 의 단위 테스트가
/// timer 의 빈도 결정 로직을 mock provider 로 검증할 수 있게 한다.
@MainActor
public final class ViewportPollingTimer {
    public let focusedIntervalMs: Int
    public let backgroundIntervalMs: Int

    private var timer: Timer?
    private var lastPolledAt: [UUID: Date] = [:]

    private let selectedWorkspaceIdProvider: () -> UUID?
    private weak var focusedPaneStore: FocusedPaneStore?
    private let provider: AgentViewSurfaceProvider
    private let sessionIndexProvider: () -> SessionIndex
    private weak var observer: SessionStatusObserver?
    private weak var store: SessionStatusStore?
    private let isAppActive: () -> Bool

    public init(
        selectedWorkspaceIdProvider: @escaping () -> UUID?,
        focusedPaneStore: FocusedPaneStore,
        provider: AgentViewSurfaceProvider,
        sessionIndexProvider: @escaping () -> SessionIndex,
        observer: SessionStatusObserver,
        store: SessionStatusStore,
        focusedIntervalMs: Int = 250,
        backgroundIntervalMs: Int = 1000,
        isAppActive: @escaping () -> Bool = { NSApp.isActive }
    ) {
        self.selectedWorkspaceIdProvider = selectedWorkspaceIdProvider
        self.focusedPaneStore = focusedPaneStore
        self.provider = provider
        self.sessionIndexProvider = sessionIndexProvider
        self.observer = observer
        self.store = store
        self.focusedIntervalMs = focusedIntervalMs
        self.backgroundIntervalMs = backgroundIntervalMs
        self.isAppActive = isAppActive
    }

    /// 250ms 간격 main queue timer. `CHAT_TERMINAL_AGENT_POLL_INTERVAL_MS=0` 일 때
    /// 비활성 (action_cb only) — 테스트 환경 timer 부담 회피용.
    public func start() {
        guard timer == nil else { return }
        let envInterval = ProcessInfo.processInfo.environment["CHAT_TERMINAL_AGENT_POLL_INTERVAL_MS"]
        if let s = envInterval, let v = Int(s), v == 0 { return }
        let t = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer = t
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// polling tick — 각 등록된 entry 의 focused 여부에 따라 interval 결정.
    /// `app inactive` 일 때 focusedPaneId 는 nil 로 강등되어 모든 surface 가 1Hz.
    public func tick(now: Date = Date()) {
        let appActive = isAppActive()
        let focusedPaneId: UUID? = {
            guard appActive,
                  let wsId = selectedWorkspaceIdProvider(),
                  let store = focusedPaneStore else { return nil }
            return store.focused[wsId]
        }()
        let index = sessionIndexProvider()
        for entry in index.entries {
            if store?.snapshot(for: entry.sessionId)?.agentStatus == .exited { continue }
            let intervalMs = (entry.paneId == focusedPaneId) ? focusedIntervalMs : backgroundIntervalMs
            if shouldPoll(sessionId: entry.sessionId, intervalMs: intervalMs, now: now) {
                poll(entry: entry, now: now)
            }
        }
    }

    private func shouldPoll(sessionId: UUID, intervalMs: Int, now: Date) -> Bool {
        guard let last = lastPolledAt[sessionId] else { return true }
        let elapsedMs = now.timeIntervalSince(last) * 1000
        return elapsedMs >= Double(intervalMs)
    }

    private func poll(entry: SessionIndexEntry, now: Date) {
        // P3.5 Day 3: SurfaceRegistry key 가 tabId 로 전환됨. polling 시 surface 식별자는
        // tabId 를 전달한다. focused 판정은 여전히 paneId 기준 (Day 5 에서 tabId 단위로 확장 예정).
        if let viewport = provider.readViewportText(id: entry.tabId) {
            observer?.observe(sessionId: entry.sessionId, viewportText: viewport, at: now)
        }
        lastPolledAt[entry.sessionId] = now
    }
}

/// `ViewportPollingTimer` 가 의존하는 surface text 읽기 계약. 실제 production 구현은
/// `GhosttyViewportProvider.swift` 가 `ghostty_surface_read_text` +
/// `defer { ghostty_surface_free_text(...) }` 패턴으로 alloc/free 1:1 을 강제한다.
/// 테스트 mock 은 미리 준비한 텍스트를 반환하여 polling 빈도/focused 전환/app 백그라운드
/// 강등 시나리오를 검증한다.
@MainActor
public protocol AgentViewSurfaceProvider: AnyObject {
    func readViewportText(id: UUID) -> String?
}
