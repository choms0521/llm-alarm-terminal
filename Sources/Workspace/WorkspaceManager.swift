import Foundation
import SwiftUI
import AnyCodable

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
            // 기본 선택: 첫 normal workspace, 없으면 첫 워크스페이스.
            self.selectedID = file.workspaces.first(where: { $0.kind == .normal })?.id
                ?? file.workspaces.first?.id
        }
    }

    /// 새 normal workspace 를 추가하고 선택. envSnapshot 은 호출 시점 user env 를 캡처 (H6).
    /// 기본으로 shell pane 1개(`position: .top`)를 같이 생성한다(Day 4 acceptance: 선택 시 단일 pane 표시).
    @discardableResult
    public func addWorkspace(cwd: String, name: String) -> Workspace {
        let defaultPane = Pane(kind: .shell, position: .top)
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
    /// position 미지정 시 첫 pane 은 `.top`, 두 번째는 `.bottom` 으로 자동 할당.
    /// 추가된 Pane 을 반환하거나, 거부 시 nil 반환 (호출부가 후속 작업 분기 가능).
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
            pos = current.panes.isEmpty ? .top : .bottom
        }
        guard !current.panes.contains(where: { $0.position == pos }) else {
            KoreanLogger.warn("이미 \(pos.rawValue) 위치에 pane 이 존재합니다.")
            return nil
        }
        let pane = Pane(kind: kind, position: pos)
        workspaces[idx] = current.with(panes: current.panes + [pane])
        persistCurrent()
        return pane
    }

    /// 특정 pane 에 session id 를 부착(또는 clear). lifecycle coordinator 가 호출한다.
    public func assignSession(workspaceId: UUID, paneId: UUID, sessionId: UUID?) {
        guard let wsIdx = workspaces.firstIndex(where: { $0.id == workspaceId }) else { return }
        let ws = workspaces[wsIdx]
        guard let paneIdx = ws.panes.firstIndex(where: { $0.id == paneId }) else { return }
        let updated = ws.panes[paneIdx].with(sessionId: .some(sessionId))
        var newPanes = ws.panes
        newPanes[paneIdx] = updated
        workspaces[wsIdx] = ws.with(panes: newPanes)
        persistCurrent()
    }

    /// pane 제거. 첫 번째 pane(.top) 제거 시 두 번째 pane(.bottom) 이 `.top` 으로 승격.
    public func removePane(workspaceId: UUID, paneId: UUID) {
        guard let idx = workspaces.firstIndex(where: { $0.id == workspaceId }) else { return }
        let current = workspaces[idx]
        var newPanes = current.panes
        guard let paneIdx = newPanes.firstIndex(where: { $0.id == paneId }) else { return }
        let removed = newPanes.remove(at: paneIdx)
        // 첫 pane(.top) 이 제거되었고 .bottom 이 남아있으면 .top 으로 승격.
        if removed.position == .top,
           let bottomIdx = newPanes.firstIndex(where: { $0.position == .bottom }) {
            let bottom = newPanes[bottomIdx]
            newPanes[bottomIdx] = Pane(
                id: bottom.id,
                sessionId: bottom.sessionId,
                kind: bottom.kind,
                position: .top,
                chatRoomId: bottom.chatRoomId,
                extraFields: bottom.extraFields
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

    /// agent-view workspace 의 extraFields 를 갱신하여 sort/filter 설정을 영속화.
    /// agent-view 자체가 없으면 silently noop (load 직후엔 항상 존재).
    public func updateAgentViewExtraFields(_ extraFields: [String: AnyCodable]?) {
        guard let idx = workspaces.firstIndex(where: { $0.kind == .agentView }) else { return }
        let ws = workspaces[idx]
        let newWs = Workspace(
            id: ws.id,
            name: ws.name,
            cwd: ws.cwd,
            panes: ws.panes,
            createdAt: ws.createdAt,
            kind: ws.kind,
            envSnapshot: ws.envSnapshot,
            pushChannelHints: ws.pushChannelHints,
            fetchHintMetadata: ws.fetchHintMetadata,
            extraFields: extraFields
        )
        workspaces[idx] = newWs
        persistCurrent()
    }

    /// 영속화된 agent-view extraFields 를 반환 (없으면 nil).
    public func agentViewExtraFields() -> [String: AnyCodable]? {
        workspaces.first(where: { $0.kind == .agentView })?.extraFields
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
