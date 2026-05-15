import AppKit
import Foundation
import SwiftUI
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private static let logger = Logger(subsystem: "com.choms0521.ClaudeAlarmTerminal", category: "AppDelegate")

    private var mainWindow: NSWindow?
    private var ghosttyApp: GhosttyApp?
    private var workspaceManager: WorkspaceManager?
    private var coordinator: WorkspaceCoordinator?
    private var debugRenderStats: DebugRenderStats?
    private let sessionManager = SessionManager()

    // P3 Day 5 wiring: agent-view dashboard 데이터 흐름.
    private let statusObserver = SessionStatusObserver(
        policy: NeedsInputPolicyV1(),
        telemetry: NeedsInputTelemetry()
    )
    private let statusCoordinator = SessionStatusCoordinator()
    private let focusedPaneStore = FocusedPaneStore()
    private var agentJumpAction: AgentJumpAction?
    private var sessionActionRouter: SessionActionRouter?
    private var viewportPollingTimer: ViewportPollingTimer?

    /// Day 7 lifecycle hook. P1 keeps the body of the will-sleep / did-wake
    /// handlers empty (logs only). P4 will invalidate WS-attached state and
    /// arm push fallback here. See `docs/lifecycle-policy.md`.
    private let powerObserver = PowerEventObserver()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // P2 Day 3: replace P1 single-surface window with a SwiftUI sidebar +
        // workspace content split. libghostty is instantiated up-front because
        // Day 4 normal-workspace pane terminals will request surfaces from it.
        self.ghosttyApp = GhosttyApp()

        let store: WorkspaceStore
        do {
            store = try WorkspaceStore()
        } catch {
            Self.logger.error("WorkspaceStore 초기화 실패: \(error.localizedDescription, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = "워크스페이스 저장소를 초기화하지 못했습니다."
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "종료")
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        let manager = WorkspaceManager(store: store)
        self.workspaceManager = manager
        let registry = SurfaceRegistry()
        let coordinator = WorkspaceCoordinator(
            manager: manager,
            sessionManager: sessionManager,
            surfaceRegistry: registry
        )
        self.coordinator = coordinator
        // env 미설정 시 nil → zero overhead.
        self.debugRenderStats = DebugRenderStats(registry: registry)

        // P3 Day 5 wiring: SessionStatusCoordinator 가 observer publisher 와 lifecycle
        // hook 을 단방향 소비하도록 attach. AgentJumpAction 으로 카드 click 점프 가능.
        let jumpAction = AgentJumpAction(
            manager: manager,
            focusedPaneStore: focusedPaneStore,
            surfaceRegistry: registry
        )
        self.agentJumpAction = jumpAction
        statusCoordinator.attach(observer: statusObserver)
        Task { @MainActor [statusCoordinator, sessionManager] in
            await statusCoordinator.attach(lifecycleHooks: sessionManager.hooks)
        }

        // SessionActionRouter: action_cb → main hop → observer.observe(action:).
        let router = SessionActionRouter(
            observer: statusObserver,
            resolvePaneId: { ud in
                guard let p = ud else { return nil }
                let view = Unmanaged<GhosttyTerminalView>.fromOpaque(p).takeUnretainedValue()
                return view.paneId
            },
            resolveSessionId: { [weak self] paneId in
                guard let mgr = self?.workspaceManager else { return nil }
                for ws in mgr.workspaces {
                    if let pane = ws.panes.first(where: { $0.id == paneId }) {
                        return pane.sessionId
                    }
                }
                return nil
            }
        )
        SessionActionRouter.shared = router
        self.sessionActionRouter = router

        // ViewportPollingTimer: 동적 빈도 viewport read_text + observer.observe(viewportText:).
        let store2 = SessionStatusStore()
        let pollingTimer = ViewportPollingTimer(
            selectedWorkspaceIdProvider: { [weak manager] in manager?.selectedID },
            focusedPaneStore: focusedPaneStore,
            provider: GhosttyViewportProvider(surfaceRegistry: registry),
            sessionIndexProvider: { [weak manager] in
                SessionIndex(workspaces: manager?.workspaces ?? [])
            },
            observer: statusObserver,
            store: store2
        )
        pollingTimer.start()
        self.viewportPollingTimer = pollingTimer

        Task { @MainActor in
            await coordinator.attachSessionsForPersistedWorkspaces()
        }
        // P3.5 REQ-3: CLAUDE_CONFIG_DIR 격리 폐지. 부팅 시 stale 격리 디렉터리 청소
        // hook 은 제거됐다. 기존 격리 디렉터리 정리는 1회용 스크립트
        // (scripts/cleanup-legacy-claude-config-dirs.sh) 가 담당.

        let contentRect = NSRect(x: 0, y: 0, width: 1024, height: 640)
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = "Claude Alarm Terminal"
        window.minSize = NSSize(width: 720, height: 480)
        window.center()

        let app = self.ghosttyApp
        let rootView = RootView(
            manager: manager,
            coordinator: statusCoordinator,
            jumpAction: jumpAction,
            onCloseWorkspace: { id in
                Task { @MainActor in
                    await coordinator.closeWorkspace(id: id)
                }
            },
            onAddWorkspace: { cwd, name in
                Task { @MainActor in
                    await coordinator.addWorkspace(cwd: cwd, name: name)
                }
            }
        ) { workspace in
            if let app = app {
                WorkspacePaneContentView(
                    workspace: workspace,
                    ghosttyApp: app,
                    coordinator: coordinator
                )
            } else {
                Text("libghostty 가 초기화되지 않았습니다.")
            }
        }
        let hosting = NSHostingView(rootView: rootView)
        window.contentView = hosting

        window.makeKeyAndOrderFront(nil)
        self.mainWindow = window

        configureMainMenu()
        powerObserver.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { [sessionManager] in
            _ = await sessionManager.count()
        }
    }

    // MARK: - Menu wiring (Day 8: keyboard shortcuts)

    private func configureMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let appName = ProcessInfo.processInfo.processName
        appMenu.addItem(
            withTitle: "About \(appName)",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            withTitle: "Hide \(appName)",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        appMenu.addItem(
            withTitle: "Quit \(appName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit menu (Cmd+C / Cmd+V / Cmd+A). Items use nil target so AppKit
        // dispatches the action through the responder chain — GhosttyTerminalView
        // implements paste(_:) / copy(_:) / selectAll(_:) as @IBAction.
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "편집")
        let copyItem = NSMenuItem(
            title: "복사",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        )
        copyItem.keyEquivalentModifierMask = [.command]
        editMenu.addItem(copyItem)

        let pasteItem = NSMenuItem(
            title: "붙여넣기",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        )
        pasteItem.keyEquivalentModifierMask = [.command]
        editMenu.addItem(pasteItem)

        let selectAllItem = NSMenuItem(
            title: "모두 선택",
            action: #selector(NSResponder.selectAll(_:)),
            keyEquivalent: "a"
        )
        selectAllItem.keyEquivalentModifierMask = [.command]
        editMenu.addItem(selectAllItem)

        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // Workspace menu (Cmd+N, Cmd+W, Cmd+1~9, Cmd+Opt+Up/Down)
        let wsMenuItem = NSMenuItem()
        let wsMenu = NSMenu(title: "워크스페이스")

        let newWS = NSMenuItem(
            title: "새 워크스페이스",
            action: #selector(newWorkspaceFromMenu(_:)),
            keyEquivalent: "n"
        )
        newWS.keyEquivalentModifierMask = [.command]
        newWS.target = self
        wsMenu.addItem(newWS)

        let closeWS = NSMenuItem(
            title: "워크스페이스 닫기",
            action: #selector(closeCurrentWorkspaceFromMenu(_:)),
            keyEquivalent: "w"
        )
        closeWS.keyEquivalentModifierMask = [.command]
        closeWS.target = self
        wsMenu.addItem(closeWS)

        wsMenu.addItem(NSMenuItem.separator())

        // Cmd+1..9
        for i in 1...9 {
            let item = NSMenuItem(
                title: "워크스페이스 \(i)",
                action: #selector(jumpToWorkspaceByIndex(_:)),
                keyEquivalent: "\(i)"
            )
            item.keyEquivalentModifierMask = [.command]
            item.tag = i
            item.target = self
            wsMenu.addItem(item)
        }

        wsMenu.addItem(NSMenuItem.separator())

        // Cmd+Opt+Down / Up
        let nextWS = NSMenuItem(
            title: "다음 워크스페이스",
            action: #selector(cycleWorkspaceNext(_:)),
            keyEquivalent: String(UnicodeScalar(NSDownArrowFunctionKey)!)
        )
        nextWS.keyEquivalentModifierMask = [.command, .option]
        nextWS.target = self
        wsMenu.addItem(nextWS)

        let prevWS = NSMenuItem(
            title: "이전 워크스페이스",
            action: #selector(cycleWorkspacePrev(_:)),
            keyEquivalent: String(UnicodeScalar(NSUpArrowFunctionKey)!)
        )
        prevWS.keyEquivalentModifierMask = [.command, .option]
        prevWS.target = self
        wsMenu.addItem(prevWS)

        wsMenuItem.submenu = wsMenu
        mainMenu.addItem(wsMenuItem)

        // Pane menu (Cmd+D, Cmd+Shift+W)
        let paneMenuItem = NSMenuItem()
        let paneMenu = NSMenu(title: "Pane")

        let splitPane = NSMenuItem(
            title: "Pane 분할",
            action: #selector(splitCurrentPane(_:)),
            keyEquivalent: "d"
        )
        splitPane.keyEquivalentModifierMask = [.command]
        splitPane.target = self
        paneMenu.addItem(splitPane)

        let closePane = NSMenuItem(
            title: "Pane 닫기",
            action: #selector(closeCurrentPane(_:)),
            keyEquivalent: "w"
        )
        closePane.keyEquivalentModifierMask = [.command, .shift]
        closePane.target = self
        paneMenu.addItem(closePane)

        paneMenuItem.submenu = paneMenu
        mainMenu.addItem(paneMenuItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Menu item validation (Cmd+W blocked on agent-view)

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        MainActor.assumeIsolated {
            guard let manager = workspaceManager else { return false }
            switch menuItem.action {
            case #selector(closeCurrentWorkspaceFromMenu(_:)):
                // agent-view 는 Cmd+W 차단 (canClose invariant).
                guard let id = manager.selectedID,
                      let ws = manager.workspaces.first(where: { $0.id == id }) else {
                    return false
                }
                return ws.canClose
            case #selector(splitCurrentPane(_:)):
                // 두 pane 이미 있으면 분할 disabled (3rd pane block).
                guard let id = manager.selectedID else { return false }
                return manager.canSplit(workspaceId: id)
            case #selector(jumpToWorkspaceByIndex(_:)):
                return menuItem.tag - 1 < manager.workspaces.count
            default:
                return true
            }
        }
    }

    // MARK: - Workspace shortcut handlers

    @objc private func newWorkspaceFromMenu(_ sender: Any?) {
        Task { @MainActor [weak self] in
            guard let self, let coordinator = self.coordinator else { return }
            let count = coordinator.manager.workspaces.count
            await coordinator.addWorkspace(
                cwd: WorkspaceManager.defaultWorkspaceRoot(),
                name: "새 워크스페이스 \(count)"
            )
        }
    }

    @objc private func closeCurrentWorkspaceFromMenu(_ sender: Any?) {
        Task { @MainActor [weak self] in
            guard let self,
                  let coordinator = self.coordinator,
                  let id = coordinator.manager.selectedID,
                  let ws = coordinator.manager.workspaces.first(where: { $0.id == id }),
                  ws.canClose else { return }
            await coordinator.closeWorkspace(id: id)
        }
    }

    @objc private func jumpToWorkspaceByIndex(_ sender: NSMenuItem) {
        let tag = sender.tag
        MainActor.assumeIsolated {
            guard let manager = workspaceManager else { return }
            let idx = tag - 1
            guard idx >= 0, idx < manager.workspaces.count else { return }
            manager.select(id: manager.workspaces[idx].id)
        }
    }

    @objc private func cycleWorkspaceNext(_ sender: Any?) {
        MainActor.assumeIsolated { cycleSelection(by: +1) }
    }

    @objc private func cycleWorkspacePrev(_ sender: Any?) {
        MainActor.assumeIsolated { cycleSelection(by: -1) }
    }

    @MainActor
    private func cycleSelection(by delta: Int) {
        guard let manager = workspaceManager,
              let current = manager.selectedID,
              let idx = manager.workspaces.firstIndex(where: { $0.id == current }) else { return }
        let count = manager.workspaces.count
        guard count > 0 else { return }
        let next = (idx + delta + count) % count
        manager.select(id: manager.workspaces[next].id)
    }

    // MARK: - Pane shortcut handlers

    @objc private func splitCurrentPane(_ sender: Any?) {
        Task { @MainActor [weak self] in
            guard let self,
                  let coordinator = self.coordinator,
                  let id = coordinator.manager.selectedID,
                  coordinator.manager.canSplit(workspaceId: id) else { return }
            // P2 결정: 단축키 기본 split kind = .shell. UI sheet 는 Day 4 의 split 버튼 경로에서 사용.
            await coordinator.addPane(workspaceId: id, kind: .shell)
        }
    }

    @objc private func closeCurrentPane(_ sender: Any?) {
        Task { @MainActor [weak self] in
            guard let self,
                  let coordinator = self.coordinator,
                  let id = coordinator.manager.selectedID,
                  let ws = coordinator.manager.workspaces.first(where: { $0.id == id }),
                  let pane = ws.panes.last else { return }
            // Day 8 단축키 기본: 마지막 pane 을 닫음. Day 9 가 focus 기반 close 로 확장 가능.
            await coordinator.closePane(workspaceId: id, paneId: pane.id)
        }
    }
}
