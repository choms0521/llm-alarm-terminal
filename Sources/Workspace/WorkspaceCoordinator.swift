import Foundation

/// Workspace UI 와 SessionManager 사이의 lifecycle 중재자.
///
/// 책임:
/// - pane 생성/제거 시 `SessionManager.createInternal` / `terminate` 호출 + Pane.sessionId 부착
/// - workspace 제거 시 내부 모든 session terminate + workspace 제거
/// - `claudeSessionId` 보존은 SessionManager 의 기존 정책에 위임 (P1 인터페이스 재사용)
///
/// 모든 메서드는 `@MainActor` 경계에서 호출되며 SessionManager actor 와의 await 만 actor hop.
@MainActor
public final class WorkspaceCoordinator {
    public let manager: WorkspaceManager
    public let sessionManager: SessionManager
    public let surfaceRegistry: SurfaceRegistry

    public init(
        manager: WorkspaceManager,
        sessionManager: SessionManager,
        surfaceRegistry: SurfaceRegistry = SurfaceRegistry()
    ) {
        self.manager = manager
        self.sessionManager = sessionManager
        self.surfaceRegistry = surfaceRegistry
    }

    // MARK: - Bootstrap session attachment

    /// 부팅 후 1회 호출: 영속화로 복원된 모든 pane 에 대해 새 session 을 생성.
    /// (P2 결정: 부팅 직후 sessionId 는 nil 로 시작 → 첫 진입 시 새 session 부착.)
    public func attachSessionsForPersistedWorkspaces() async {
        let snapshot = manager.workspaces
        for ws in snapshot where ws.kind == .normal {
            for pane in ws.panes {
                // Day 2 transitional: 단일 Tab 가정. Day 3 에서 tab 별 attach 로 확장.
                guard let activeTab = pane.activeTab else { continue }
                let paneKind = paneKindFromSession(activeTab.kind)
                do {
                    let session = try await sessionManager.createInternal(
                        workspace: ws, paneId: pane.id, kind: paneKind
                    )
                    manager.assignSession(workspaceId: ws.id, paneId: pane.id, sessionId: session.id)
                } catch {
                    KoreanLogger.error("초기 pane session 생성 실패 (paneId=\(pane.id)): \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - addWorkspace / addPane

    /// workspace + default shell pane 을 만들고 session 부착까지 완료.
    @discardableResult
    public func addWorkspace(cwd: String, name: String) async -> Workspace {
        let ws = manager.addWorkspace(cwd: cwd, name: name)
        for pane in ws.panes {
            await attachSession(workspace: ws, pane: pane)
        }
        // session attach 후 반환할 최신 스냅샷.
        return manager.workspaces.first(where: { $0.id == ws.id }) ?? ws
    }

    /// pane 추가 + session 부착. 추가가 거부되면 nil.
    @discardableResult
    public func addPane(
        workspaceId: UUID,
        kind: PaneKind,
        position: PanePosition? = nil
    ) async -> Pane? {
        guard let pane = manager.addPane(workspaceId: workspaceId, kind: kind, position: position) else {
            return nil
        }
        guard let ws = manager.workspaces.first(where: { $0.id == workspaceId }) else { return pane }
        await attachSession(workspace: ws, pane: pane)
        return manager.workspaces
            .first(where: { $0.id == workspaceId })?
            .panes.first(where: { $0.id == pane.id })
    }

    // MARK: - closePane / closeWorkspace

    /// pane close: 세션 terminate + remove → surface release → workspace 모델에서 pane 제거.
    /// surfaceRegistry.release 가 마지막 strong reference 를 해제하면 NSView dealloc 가
    /// `ghostty_surface_free` 를 호출해 child PTY 까지 정리한다.
    public func closePane(workspaceId: UUID, paneId: UUID) async {
        guard let ws = manager.workspaces.first(where: { $0.id == workspaceId }),
              let pane = ws.panes.first(where: { $0.id == paneId }) else { return }

        // Day 2 transitional: pane 의 모든 tab 의 session 을 종료. Day 3 에서 closeTab cascade 와 분리.
        for tab in pane.tabs {
            if let sessionId = tab.sessionId {
                try? await sessionManager.terminate(id: sessionId)
                await sessionManager.remove(id: sessionId)
            }
        }
        surfaceRegistry.release(paneId: paneId)
        manager.removePane(workspaceId: workspaceId, paneId: paneId)
    }

    /// workspace close: 내부 모든 session terminateAll → 각 pane surface release → workspace 제거.
    /// agent-view 워크스페이스는 `WorkspaceManager.removeWorkspace` 가 무시(invariant 보존).
    public func closeWorkspace(id: UUID) async {
        await sessionManager.terminateAll(inWorkspace: id)
        let toRemove = await sessionManager.sessionIds(inWorkspace: id)
        for sid in toRemove {
            await sessionManager.remove(id: sid)
        }
        if let ws = manager.workspaces.first(where: { $0.id == id }) {
            for pane in ws.panes {
                surfaceRegistry.release(paneId: pane.id)
            }
        }
        manager.removeWorkspace(id: id)
    }

    // MARK: - Helpers

    private func attachSession(workspace: Workspace, pane: Pane) async {
        // Day 2 transitional: pane.activeTab 의 kind 를 사용. Day 3 에서 tab 별 attach 로 확장.
        guard let activeTab = pane.activeTab else {
            KoreanLogger.warn("attachSession: pane 에 active tab 이 없습니다 (paneId=\(pane.id))")
            return
        }
        let kind = paneKindFromSession(activeTab.kind)
        do {
            let session = try await sessionManager.createInternal(
                workspace: workspace, paneId: pane.id, kind: kind
            )
            manager.assignSession(workspaceId: workspace.id, paneId: pane.id, sessionId: session.id)
        } catch {
            KoreanLogger.error("pane session 부착 실패: \(error.localizedDescription)")
        }
    }

    /// `Tab.kind` 가 `PaneKind` 이므로 그대로 반환. 명시적 conversion 인터페이스를
    /// 추후 변경 가능성에 대비해 단일 helper 로 둔다.
    private func paneKindFromSession(_ kind: PaneKind) -> PaneKind { kind }
}
