import Foundation
import SwiftUI

/// Workspace 집합과 선택 상태를 보유하는 `@MainActor` ViewModel.
///
/// 부팅 시 `WorkspaceStore` 에서 영속 데이터를 로드하고, agent-view invariant 와
/// default normal workspace(MED5) 정착 후 UI 에 publish 한다.
@MainActor
public final class WorkspaceManager: ObservableObject {
    @Published public private(set) var workspaces: [Workspace] = []
    @Published public var selectedID: UUID?

    private let store: WorkspaceStore

    public init(store: WorkspaceStore) {
        self.store = store
        bootstrap()
    }

    /// 부팅 절차:
    /// 1. `WorkspaceStore.load()` — `.tmp` 정리, `.bak` 복구, agent-view invariant guard 적용.
    /// 2. normal workspace 가 0 개이면 MED5 default normal 생성
    ///    (cwd = `CHAT_TERMINAL_WORKSPACE_ROOT` 또는 `$HOME`).
    /// 3. `lastActiveWorkspaceId` 가 유효하면 선택, 아니면 첫 워크스페이스.
    private func bootstrap() {
        var file: WorkspaceFile
        do {
            file = try store.load()
        } catch {
            KoreanLogger.error("워크스페이스 로드 실패: \(error.localizedDescription). 빈 상태로 시작합니다.")
            file = WorkspaceFile(
                workspaces: [Workspace.makeAgentView()],
                lastActiveWorkspaceId: nil
            )
        }

        let normals = file.workspaces.filter { $0.kind == .normal }
        if normals.isEmpty {
            let defaultCwd = Self.defaultWorkspaceRoot()
            let defaultWS = Workspace(
                name: "기본 작업",
                cwd: defaultCwd,
                kind: .normal,
                envSnapshot: SessionSpawnEnv.captureUserEnv()
            )
            file = WorkspaceFile(
                version: file.version,
                workspaces: file.workspaces + [defaultWS],
                lastActiveWorkspaceId: defaultWS.id
            )
            persist(file)
        }

        self.workspaces = file.workspaces
        let activeCandidate = file.lastActiveWorkspaceId
        if let active = activeCandidate, file.workspaces.contains(where: { $0.id == active }) {
            self.selectedID = active
        } else {
            // P3 Recovery: agent-view 가 영구 첫 탭이므로 lastActiveWorkspaceId 가 없거나
            // 유효하지 않으면 agent-view 를 우선 선택한다. agent-view 가 없는 비정상
            // 상태에서만 첫 normal workspace 로 fall back.
            self.selectedID = file.workspaces.first(where: { $0.kind == .agentView })?.id
                ?? file.workspaces.first(where: { $0.kind == .normal })?.id
                ?? file.workspaces.first?.id
        }
    }

    /// 새 normal workspace 를 추가하고 선택. envSnapshot 은 호출 시점 user env 를 캡처 (H6).
    /// 기본으로 shell pane 1개(`position: .left`)를 같이 생성한다(Day 4 acceptance: 선택 시 단일 pane 표시).
    /// pane 안에는 단일 shell Tab 1개가 들어가며 activeTabId 는 그 tab.
    @discardableResult
    public func addWorkspace(cwd: String, name: String) -> Workspace {
        let defaultTab = Tab(kind: .shell, name: Tab.defaultName(for: .shell))
        let defaultPane = Pane(
            position: .left,
            tabs: [defaultTab],
            activeTabId: defaultTab.id
        )
        let ws = Workspace(
            name: name,
            cwd: cwd,
            panes: [defaultPane],
            kind: .normal,
            envSnapshot: SessionSpawnEnv.captureUserEnv()
        )
        workspaces.append(ws)
        selectedID = ws.id
        persistCurrent()
        return ws
    }

    /// workspace 에 새 pane 추가. panes.count >= 2 면 무시(invariant: pane 최대 2개).
    /// position 미지정 시 첫 pane 은 `.left`, 두 번째는 `.right` 으로 자동 할당.
    /// pane 안에는 인자 kind 의 단일 Tab 1개가 자동 생성된다(Day 3 에서 멀티탭 API 확장 예정).
    /// 추가된 Pane 을 반환하거나, 거부 시 nil 반환.
    @discardableResult
    public func addPane(workspaceId: UUID, kind: PaneKind, position: PanePosition? = nil) -> Pane? {
        guard let idx = workspaces.firstIndex(where: { $0.id == workspaceId }) else { return nil }
        let current = workspaces[idx]
        guard current.kind == .normal else {
            KoreanLogger.warn("agent-view 워크스페이스에는 pane 을 추가할 수 없습니다.")
            return nil
        }
        guard current.panes.count < 2 else {
            KoreanLogger.warn("pane 은 최대 2개까지 허용됩니다.")
            return nil
        }
        let pos: PanePosition
        if let position = position {
            pos = position
        } else {
            pos = current.panes.isEmpty ? .left : .right
        }
        guard !current.panes.contains(where: { $0.position == pos }) else {
            KoreanLogger.warn("이미 \(pos.rawValue) 위치에 pane 이 존재합니다.")
            return nil
        }
        let tab = Tab(kind: kind, name: Tab.defaultName(for: kind))
        let pane = Pane(
            position: pos,
            tabs: [tab],
            activeTabId: tab.id
        )
        workspaces[idx] = current.with(panes: current.panes + [pane])
        persistCurrent()
        return pane
    }

    /// 특정 pane 의 active tab 에 session id 를 부착(또는 clear). lifecycle coordinator 가 호출한다.
    /// Day 2 transitional: Day 3 의 멀티탭 API 가 들어오기 전까지는 pane 당 1개 tab 가정.
    public func assignSession(workspaceId: UUID, paneId: UUID, sessionId: UUID?) {
        guard let wsIdx = workspaces.firstIndex(where: { $0.id == workspaceId }) else { return }
        let ws = workspaces[wsIdx]
        guard let paneIdx = ws.panes.firstIndex(where: { $0.id == paneId }) else { return }
        let pane = ws.panes[paneIdx]
        let targetTabId = pane.activeTabId ?? pane.tabs.first?.id
        guard let targetTabId = targetTabId,
              let tabIdx = pane.tabs.firstIndex(where: { $0.id == targetTabId }) else { return }
        var newTabs = pane.tabs
        newTabs[tabIdx] = pane.tabs[tabIdx].with(sessionId: .some(sessionId))
        let newPane = pane.with(tabs: newTabs)
        var newPanes = ws.panes
        newPanes[paneIdx] = newPane
        workspaces[wsIdx] = ws.with(panes: newPanes)
        persistCurrent()
    }

    /// pane 제거. 첫 번째 pane(.left) 제거 시 두 번째 pane(.right) 이 `.left` 으로 승격.
    public func removePane(workspaceId: UUID, paneId: UUID) {
        guard let idx = workspaces.firstIndex(where: { $0.id == workspaceId }) else { return }
        let current = workspaces[idx]
        var newPanes = current.panes
        guard let paneIdx = newPanes.firstIndex(where: { $0.id == paneId }) else { return }
        let removed = newPanes.remove(at: paneIdx)
        // 첫 pane(.left) 이 제거되었고 .right 이 남아있으면 .left 으로 승격.
        if removed.position == .left,
           let rightIdx = newPanes.firstIndex(where: { $0.position == .right }) {
            let rightPane = newPanes[rightIdx]
            newPanes[rightIdx] = Pane(
                id: rightPane.id,
                position: .left,
                tabs: rightPane.tabs,
                activeTabId: rightPane.activeTabId,
                chatRoomId: rightPane.chatRoomId,
                extraFields: rightPane.extraFields
            )
        }
        workspaces[idx] = current.with(panes: newPanes)
        persistCurrent()
    }

    /// 추가 pane 을 생성할 수 있는지(panes.count < 2). agent-view 워크스페이스는 항상 false.
    public func canSplit(workspaceId: UUID) -> Bool {
        guard let ws = workspaces.first(where: { $0.id == workspaceId }) else { return false }
        guard ws.kind == .normal else { return false }
        return ws.panes.count < 2
    }

    /// workspace 제거. `canClose == false` 인(즉, agent-view 인) 워크스페이스는 무시.
    /// 세션 정리는 Day 5 lifecycle wiring 에서 수행.
    public func removeWorkspace(id: UUID) {
        guard let idx = workspaces.firstIndex(where: { $0.id == id }) else { return }
        guard workspaces[idx].canClose else {
            KoreanLogger.warn("agent-view 워크스페이스는 닫을 수 없습니다.")
            return
        }
        workspaces.remove(at: idx)
        if selectedID == id {
            selectedID = workspaces.first(where: { $0.kind == .normal })?.id
                ?? workspaces.first?.id
        }
        persistCurrent()
    }

    public func select(id: UUID) {
        guard workspaces.contains(where: { $0.id == id }) else { return }
        selectedID = id
        persistCurrent()
    }

    /// 현재 in-memory 상태를 디스크에 저장.
    private func persistCurrent() {
        let file = WorkspaceFile(
            workspaces: workspaces,
            lastActiveWorkspaceId: selectedID
        )
        persist(file)
    }

    private func persist(_ file: WorkspaceFile) {
        do {
            try store.save(file)
        } catch {
            KoreanLogger.error("워크스페이스 저장 실패: \(error.localizedDescription)")
        }
    }

    /// MED5: default normal workspace 의 cwd 결정. 부록 A 환경 변수.
    /// 순수 함수이므로 actor 격리 없이 호출 가능.
    public nonisolated static func defaultWorkspaceRoot() -> String {
        if let env = ProcessInfo.processInfo.environment["CHAT_TERMINAL_WORKSPACE_ROOT"],
           !env.isEmpty {
            return env
        }
        return NSHomeDirectory()
    }
}

// MARK: - Tab API + 자동 정리 cascade (P3.5 Day 3, REQ-2/REQ-4)

extension WorkspaceManager {

    /// pane 에 새 Tab 을 추가하고 activeTabId 를 새 tab 으로 갱신한다(REQ-2).
    ///
    /// 순수 모델 변경만 수행한다. session 부착은 `WorkspaceCoordinator.addTab` 이
    /// 담당한다(Manager=순수 모델 / Coordinator=세션 lifecycle 분리 유지).
    /// agent-view 워크스페이스나 미존재 pane 에 대해서는 nil 을 반환한다.
    @discardableResult
    public func addTab(workspaceId: UUID, paneId: UUID, kind: PaneKind, name: String? = nil) -> Tab? {
        guard let wsIdx = workspaces.firstIndex(where: { $0.id == workspaceId }) else { return nil }
        let ws = workspaces[wsIdx]
        guard ws.kind == .normal else {
            KoreanLogger.warn("agent-view 워크스페이스에는 탭을 추가할 수 없습니다.")
            return nil
        }
        guard let paneIdx = ws.panes.firstIndex(where: { $0.id == paneId }) else { return nil }
        let pane = ws.panes[paneIdx]
        let tab = Tab(kind: kind, name: name ?? Tab.defaultName(for: kind))
        let newPane = pane.with(tabs: pane.tabs + [tab], activeTabId: .some(tab.id))
        var newPanes = ws.panes
        newPanes[paneIdx] = newPane
        workspaces[wsIdx] = ws.with(panes: newPanes)
        persistCurrent()
        return tab
    }

    /// pane 의 activeTabId 를 지정한 tab 으로 전환한다(REQ-2 탭 선택).
    /// 존재하지 않는 tab 이거나 이미 활성인 경우 noop.
    public func selectTab(workspaceId: UUID, paneId: UUID, tabId: UUID) {
        guard let wsIdx = workspaces.firstIndex(where: { $0.id == workspaceId }) else { return }
        let ws = workspaces[wsIdx]
        guard let paneIdx = ws.panes.firstIndex(where: { $0.id == paneId }) else { return }
        let pane = ws.panes[paneIdx]
        guard pane.tabs.contains(where: { $0.id == tabId }), pane.activeTabId != tabId else { return }
        let newPane = pane.with(activeTabId: .some(tabId))
        var newPanes = ws.panes
        newPanes[paneIdx] = newPane
        workspaces[wsIdx] = ws.with(panes: newPanes)
        persistCurrent()
    }

    /// tab 을 닫고 비어지는 컨테이너를 cascade 로 정리한다(REQ-4).
    ///
    /// 순수 모델 cascade: tab 제거 → `pane.tabs.isEmpty` 시 pane 제거(`.left` 승격 포함)
    /// → `workspace.panes.isEmpty && canClose` 시 workspace 제거. session terminate /
    /// surface release 는 `WorkspaceCoordinator.closeTab` 이 본 메서드 호출 전에 수행한다.
    /// `canClose == false`(agent-view)는 `removeWorkspace` 가 자연 보호하므로 추가 분기 불필요.
    public func closeTab(workspaceId: UUID, paneId: UUID, tabId: UUID) {
        guard let wsIdx = workspaces.firstIndex(where: { $0.id == workspaceId }) else { return }
        let ws = workspaces[wsIdx]
        guard let paneIdx = ws.panes.firstIndex(where: { $0.id == paneId }) else { return }
        let pane = ws.panes[paneIdx]
        guard pane.tabs.contains(where: { $0.id == tabId }) else { return }

        var newTabs = pane.tabs
        newTabs.removeAll { $0.id == tabId }

        if newTabs.isEmpty {
            // cascade 1: 마지막 tab → pane 제거(.left 승격 + persist 는 removePane 이 수행).
            removePane(workspaceId: workspaceId, paneId: paneId)
            // cascade 2: 마지막 pane → workspace 제거. canClose 는 removeWorkspace 가 가드.
            if let after = workspaces.first(where: { $0.id == workspaceId }),
               after.panes.isEmpty, after.canClose {
                removeWorkspace(id: workspaceId)
            }
            return
        }

        // 닫은 tab 이 활성이었으면 남은 첫 tab 으로 active 이전.
        let newActiveId: UUID? = (pane.activeTabId == tabId) ? newTabs.first?.id : pane.activeTabId
        let newPane = pane.with(tabs: newTabs, activeTabId: .some(newActiveId))
        var newPanes = ws.panes
        newPanes[paneIdx] = newPane
        workspaces[wsIdx] = ws.with(panes: newPanes)
        persistCurrent()
    }

    /// 특정 tabId 의 session 을 부착(또는 clear)한다. `addTab` 후 coordinator 가
    /// 생성한 session 을 정확한 tab 에 바인딩할 때 사용한다. active tab 기준의
    /// `assignSession(workspaceId:paneId:sessionId:)` 와 구분되는 tab 타깃 버전.
    public func assignSession(workspaceId: UUID, paneId: UUID, tabId: UUID, sessionId: UUID?) {
        guard let wsIdx = workspaces.firstIndex(where: { $0.id == workspaceId }) else { return }
        let ws = workspaces[wsIdx]
        guard let paneIdx = ws.panes.firstIndex(where: { $0.id == paneId }) else { return }
        let pane = ws.panes[paneIdx]
        guard let tabIdx = pane.tabs.firstIndex(where: { $0.id == tabId }) else { return }
        var newTabs = pane.tabs
        newTabs[tabIdx] = pane.tabs[tabIdx].with(sessionId: .some(sessionId))
        let newPane = pane.with(tabs: newTabs)
        var newPanes = ws.panes
        newPanes[paneIdx] = newPane
        workspaces[wsIdx] = ws.with(panes: newPanes)
        persistCurrent()
    }
}
