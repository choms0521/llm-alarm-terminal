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
            // 기본 선택: 첫 normal workspace, 없으면 첫 워크스페이스.
            self.selectedID = file.workspaces.first(where: { $0.kind == .normal })?.id
                ?? file.workspaces.first?.id
        }
    }

    /// 새 normal workspace 를 추가하고 선택. envSnapshot 은 호출 시점 user env 를 캡처 (H6).
    @discardableResult
    public func addWorkspace(cwd: String, name: String) -> Workspace {
        let ws = Workspace(
            name: name,
            cwd: cwd,
            kind: .normal,
            envSnapshot: SessionSpawnEnv.captureUserEnv()
        )
        workspaces.append(ws)
        selectedID = ws.id
        persistCurrent()
        return ws
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
