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
    private var sessionActionRouter: SessionActionRouter?
    private var viewportPollingTimer: ViewportPollingTimer?

    /// Day 7 lifecycle hook. P1 keeps the body of the will-sleep / did-wake
    /// handlers empty (logs only). P5 Day 5 reconstructs this with an
    /// `AttachmentInvalidator` so sleep arms the push fallback. `var` because the
    /// reconstruction needs the registry, which only exists after `DaemonBootstrap`.
    private var powerObserver = PowerEventObserver()

    /// P5 Day 3 (g): in-process WebSocket daemon launched at startup by
    /// `DaemonBootstrap`. Before P5 only the dev CLI / tests started the daemon;
    /// the app now boots it.
    private var daemonHandle: DaemonHandle?

    /// P5 Day 4 (h): drives live internal-input attachment once the daemon is up.
    private var internalInputCoordinator: InternalInputCoordinator?

    /// P6a Day 3: 신뢰 디바이스를 실 Keychain에 보관하는 store. DaemonBootstrap에 주입해
    /// 데몬 토큰 인증이 실 Keychain을 보게 하고, 페어링 UI도 같은 store를 공유한다.
    private let deviceStore: any DeviceStore = KeychainDeviceStore()

    /// P6a Day 3: 6자리 코드 발급 세션. 페어링 UI가 코드/QR을 발급하는 데 쓴다.
    private let pairingSession = PairingSession()

    /// P6a Day 3: 페어링 화면 모델. 데몬 port를 알아야 wsEndpoint를 구성할 수 있어
    /// DaemonBootstrap 완료 후 생성한다.
    private var pairingModel: PairingModel?

    /// 푸시 알림 설정 모델. 설정 창의 "푸시 알림" 탭에 임베드한다.
    private let pushSettingsModel = PushSettingsModel()

    /// 설정 페이지 전환 상태. RootView 가 ObservedObject 로 관찰하며, isShowingSettings 가
    /// true 이면 본 창 내에서 SettingsPageView 로 전환된다. NSWindow 팝업 방식을 대체한다.
    private let appSettingsState = AppSettingsState()

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

        // P3.5 Day 3 (종료조건 #7): v1 → v2 schema migration 을 부팅 시 1회 실행.
        // load() 안이 아니라 manager 생성 전에 orchestrate 하는 이유 — migrateIfNeeded 의
        // `.aborted` 분기는 backup 실패 시 원본 v1 을 보존한다. 만약 load() 안에서 migration
        // 후 곧바로 decode 하면, abort 가 보존한 v1 을 bootstrap 의 decode-실패 catch 가
        // default workspace 로 overwrite 하여 사용자 데이터를 소실시킨다. 따라서 migration 을
        // 분리 실행하고 abort 시 halt 하여 원본을 지킨다.
        let migrationResult: WorkspaceSchemaMigration.Result
        do {
            migrationResult = try WorkspaceSchemaMigration.migrateIfNeeded(at: store.fileURL)
        } catch {
            Self.logger.error("schema 변환 실패: \(error.localizedDescription, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = "워크스페이스 스키마 변환에 실패했습니다."
            alert.informativeText = "원본 파일은 변경되지 않았습니다.\n\n\(error.localizedDescription)"
            alert.addButton(withTitle: "종료")
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        if case .aborted(let reason) = migrationResult {
            // backup 생성 실패 → 원본 v1 보존됨. overwrite 방지 위해 halt (manager 미생성).
            SchemaMigrationDialogs.presentBackupFailure(reason: reason)
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
        // hook 을 단방향 소비하도록 attach.
        statusCoordinator.attach(observer: statusObserver)
        Task { @MainActor [statusCoordinator, sessionManager] in
            await statusCoordinator.attach(lifecycleHooks: sessionManager.hooks)
        }

        // SessionActionRouter: action_cb → main hop → observer.observe(action:).
        // P3.5 Day 1.5: SurfaceRegistry key 가 tabId 로 전환됨에 따라 anchor 도 tabId.
        let router = SessionActionRouter(
            observer: statusObserver,
            resolveTabId: { ud in
                guard let p = ud else { return nil }
                let view = Unmanaged<GhosttyTerminalView>.fromOpaque(p).takeUnretainedValue()
                return view.tabId
            },
            resolveSessionId: { [weak self] tabId in
                guard let mgr = self?.workspaceManager else { return nil }
                for ws in mgr.workspaces {
                    for pane in ws.panes {
                        if let tab = pane.tabs.first(where: { $0.id == tabId }) {
                            return tab.sessionId
                        }
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
        // agentContent closure 가 캡처할 수 있도록 인스턴스 프로퍼티를 지역 상수화
        // (normalContent 가 coordinator/app 을 지역 캡처하는 패턴과 동일).
        let statusCoordinator = self.statusCoordinator
        // P5.5: 트리 선택/펼침 상태를 뷰 밖에서 단일 소유 — agent-view 를
        // 떠났다 돌아와도(뷰 재생성) 선택과 펼침이 보존된다.
        let agentTreeSelection = AgentTreeSelection()
        let settingsState = appSettingsState
        let rootView = SettingsObservingHost(settingsState: settingsState) {
            RootView(
            manager: manager,
            coordinator: statusCoordinator,
            onCloseWorkspace: { id in
                Task { @MainActor in
                    await coordinator.closeWorkspace(id: id)
                }
            },
            onAddWorkspace: { cwd, name in
                Task { @MainActor in
                    await coordinator.addWorkspace(cwd: cwd, name: name)
                }
            },
            isShowingSettings: Binding(
                get: { settingsState.isShowingSettings },
                set: { settingsState.isShowingSettings = $0 }
            ),
            onOpenSettings: { settingsState.open() },
            settingsContent: {
                SettingsPageView(
                    settingsState: settingsState,
                    pushSettingsModel: self.pushSettingsModel
                )
            },
            normalContent: { workspace in
                if let app = app {
                    WorkspacePaneContentView(
                        workspace: workspace,
                        ghosttyApp: app,
                        coordinator: coordinator
                    )
                } else {
                    Text("libghostty 가 초기화되지 않았습니다.")
                }
            },
            agentContent: {
                // P5.5: agent-view 좌우 스플릿(좌측 트리 + 우측 라이브 터미널 호스트).
                // GhosttyApp/SurfaceRegistry 의존이라 closure 로 격리 주입.
                if let app = app {
                    AgentSplitView(
                        manager: manager,
                        coordinator: statusCoordinator,
                        registry: registry,
                        ghosttyApp: app,
                        selection: agentTreeSelection
                    )
                } else {
                    Text("libghostty 가 초기화되지 않았습니다.")
                }
            }
            )
        }
        let hosting = NSHostingView(rootView: rootView)
        window.contentView = hosting

        window.makeKeyAndOrderFront(nil)
        self.mainWindow = window

        configureMainMenu()
        powerObserver.start()

        // P5 Day 3 (g): launch the in-process WebSocket daemon at startup.
        // WSServer.start() is async, so hop onto a main-actor Task.
        Task { @MainActor in
            do {
                // P6a Day 3: 실 Keychain store를 주입해 데몬 토큰 인증이 디스크의 신뢰 목록을
                // 보게 한다. 페어링 UI도 같은 store를 공유한다.
                // P6b Day 1: 데몬/UI가 공유하는 단일 PairingSession을 주입해 claim 성공 시
                // pending → active 승격(DevicePromotionCoordinator)이 데몬 레이어에 배선되게 한다(D-3).
                let handle = try await DaemonBootstrap(
                    store: self.deviceStore,
                    pairingSession: self.pairingSession
                ).start()
                self.daemonHandle = handle

                // P6a Day 3: 데몬 port가 정해졌으니 페어링 화면 모델을 구성한다. wsEndpoint는
                // loopback ws://127.0.0.1:<port>/ (D-5).
                let model = PairingModel(
                    session: self.pairingSession,
                    store: self.deviceStore,
                    wsEndpoint: "ws://127.0.0.1:\(handle.port)/"
                )
                self.pairingModel = model
                // AppSettingsState도 동기화해 SettingsPageView가 자동 갱신되도록 한다.
                self.appSettingsState.pairingModel = model
                // P5 Day 5: lid-close → invalidate all WS attachments so push
                // fallback fires during sleep. Reconstruct powerObserver (let→var)
                // with the willSleep handler now that the registry exists.
                let invalidator = AttachmentInvalidator(registry: handle.registry)
                self.powerObserver.stop()
                self.powerObserver = PowerEventObserver(
                    willSleep: { Task { await invalidator.invalidateAllAttached() } }
                )
                self.powerObserver.start()
                // P5 Day 4 (h): live-wire internal (Claude) input once the daemon
                // is up. Runtime firing is verified by manual C2 sign-off.
                let coordinator = InternalInputCoordinator(
                    provider: RegistrySurfaceProvider(registry: registry),
                    daemon: handle.daemon,
                    internalSessions: { [weak self] in self?.internalClaudeSessions() ?? [] }
                )
                self.internalInputCoordinator = coordinator
                coordinator.start()
                Self.logger.info("daemon 기동 완료")
            } catch {
                Self.logger.error("daemon 기동 실패: \(error.localizedDescription, privacy: .public)")
            }
        }

        // 종료조건 #7: v1 → v2 변환이 일어났으면 윈도우 표시 후 한국어 성공 다이얼로그 1회.
        // (modal 이 부팅을 막지 않도록 makeKeyAndOrderFront 이후에 표시.)
        if case .migrated(let backupURL) = migrationResult {
            SchemaMigrationDialogs.presentSuccess(backupURL: backupURL, in: window)
        }
    }

    /// P5 Day 4 (h): live Claude (internal) sessions as (tabId, sessionId) pairs.
    /// Read-only traversal of the workspace model, mirroring `resolveSessionId`.
    @MainActor
    private func internalClaudeSessions() -> [(tabId: UUID, sessionId: UUID)] {
        guard let mgr = workspaceManager else { return [] }
        var out: [(tabId: UUID, sessionId: UUID)] = []
        for ws in mgr.workspaces {
            for pane in ws.panes {
                for tab in pane.tabs where tab.kind == .claude {
                    if let sid = tab.sessionId { out.append((tab.id, sid)) }
                }
            }
        }
        return out
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

        // 설정 창 진입점. 표준 macOS 설정 단축키 Cmd+,. 주 진입점은 사이드바 톱니바퀴이며
        // 메뉴 항목은 보조 경로다.
        let settingsItem = NSMenuItem(
            title: "설정…",
            action: #selector(openSettingsWindow(_:)),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = [.command]
        settingsItem.target = self
        appMenu.addItem(settingsItem)
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

        // P3.5 Day 3 (REQ-4): 워크스페이스 닫기를 Cmd+W → Cmd+Shift+W 로 이전.
        // Cmd+W 는 활성 탭 닫기(탭 메뉴)로 재매핑됨.
        let closeWS = NSMenuItem(
            title: "워크스페이스 닫기",
            action: #selector(closeCurrentWorkspaceFromMenu(_:)),
            keyEquivalent: "w"
        )
        closeWS.keyEquivalentModifierMask = [.command, .shift]
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

        // P3.5 Day 3: Cmd+Shift+W 는 워크스페이스 닫기로 이전됨. Pane 닫기는
        // 단축키 없이 메뉴 항목으로만 유지(탭 cascade 가 주된 정리 경로).
        let closePane = NSMenuItem(
            title: "Pane 닫기",
            action: #selector(closeCurrentPane(_:)),
            keyEquivalent: ""
        )
        closePane.target = self
        paneMenu.addItem(closePane)

        paneMenuItem.submenu = paneMenu
        mainMenu.addItem(paneMenuItem)

        // 탭 menu (Cmd+T 새 탭, Cmd+W 활성 탭 닫기, Cmd+Shift+] / [ 탭 전환) — P3.5 Day 3 REQ-2/REQ-4
        let tabMenuItem = NSMenuItem()
        let tabMenu = NSMenu(title: "탭")

        let newTab = NSMenuItem(
            title: "새 탭",
            action: #selector(newTabFromMenu(_:)),
            keyEquivalent: "t"
        )
        newTab.keyEquivalentModifierMask = [.command]
        newTab.target = self
        tabMenu.addItem(newTab)

        let closeTab = NSMenuItem(
            title: "탭 닫기",
            action: #selector(closeActiveTabFromMenu(_:)),
            keyEquivalent: "w"
        )
        closeTab.keyEquivalentModifierMask = [.command]
        closeTab.target = self
        tabMenu.addItem(closeTab)

        tabMenu.addItem(NSMenuItem.separator())

        let nextTab = NSMenuItem(
            title: "다음 탭",
            action: #selector(cycleActiveTabNext(_:)),
            keyEquivalent: "]"
        )
        nextTab.keyEquivalentModifierMask = [.command, .shift]
        nextTab.target = self
        tabMenu.addItem(nextTab)

        let prevTab = NSMenuItem(
            title: "이전 탭",
            action: #selector(cycleActiveTabPrev(_:)),
            keyEquivalent: "["
        )
        prevTab.keyEquivalentModifierMask = [.command, .shift]
        prevTab.target = self
        tabMenu.addItem(prevTab)

        tabMenuItem.submenu = tabMenu
        mainMenu.addItem(tabMenuItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Menu item validation (Cmd+W blocked on agent-view)

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        MainActor.assumeIsolated {
            // 설정 항목은 workspace와 무관하며 데몬 준비 전에도 연다(창에 "데몬 준비 중"
            // 안내가 있으므로 항상 활성).
            if menuItem.action == #selector(openSettingsWindow(_:)) {
                return true
            }
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
            case #selector(closeActiveTabFromMenu(_:)),
                 #selector(newTabFromMenu(_:)),
                 #selector(cycleActiveTabNext(_:)),
                 #selector(cycleActiveTabPrev(_:)):
                // 탭 조작은 normal workspace + pane 존재 시에만 활성.
                // agent-view 는 pane/tab 구조가 없으므로 비활성(invariant 자연 보호).
                guard let id = manager.selectedID,
                      let ws = manager.workspaces.first(where: { $0.id == id }) else { return false }
                return ws.kind == .normal && !ws.panes.isEmpty
            default:
                return true
            }
        }
    }

    // MARK: - Settings page

    /// 설정 페이지를 본 창 내에서 연다. 사이드바 설정 버튼과 메뉴 항목(Cmd+,)의 공통 진입점이다.
    /// NSWindow 팝업 방식 대신 appSettingsState.isShowingSettings 를 true 로 설정해
    /// RootView 가 SettingsPageView 로 전환하도록 한다.
    ///
    /// pairingModel 은 데몬 부트스트랩 후 채워지며, nil 이어도 설정 페이지는 열리고
    /// PairingSettingsContent 가 "데몬 준비 중" 안내를 표시한다. RootView 가 pairingModel
    /// @Published 변화를 관찰하므로 부트스트랩 완료 후 자동으로 갱신된다.
    @objc private func openSettingsWindow(_ sender: Any?) {
        appSettingsState.open(section: .pairing)
        mainWindow?.makeKeyAndOrderFront(nil)
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

    // MARK: - Tab shortcut handlers (P3.5 Day 3, REQ-2/REQ-4)

    /// 선택된 workspace 의 focus 된 pane 을 반환. focus 미설정 시 첫 pane fallback.
    @MainActor
    private func focusedPane(in ws: Workspace) -> Pane? {
        if let pid = focusedPaneStore.currentFocus(workspaceId: ws.id),
           let p = ws.panes.first(where: { $0.id == pid }) {
            return p
        }
        return ws.panes.first
    }

    /// Cmd+W: focus 된 pane 의 활성 탭을 닫는다. 마지막 탭이면 pane → workspace cascade(REQ-4).
    @objc private func closeActiveTabFromMenu(_ sender: Any?) {
        Task { @MainActor [weak self] in
            guard let self,
                  let coordinator = self.coordinator,
                  let id = coordinator.manager.selectedID,
                  let ws = coordinator.manager.workspaces.first(where: { $0.id == id }),
                  ws.kind == .normal,
                  let pane = self.focusedPane(in: ws),
                  let tabId = pane.activeTabId ?? pane.tabs.first?.id else { return }
            await coordinator.closeTab(workspaceId: id, paneId: pane.id, tabId: tabId)
        }
    }

    /// Cmd+T: focus 된 pane 에 새 shell 탭을 추가한다(default kind = shell).
    @objc private func newTabFromMenu(_ sender: Any?) {
        Task { @MainActor [weak self] in
            guard let self,
                  let coordinator = self.coordinator,
                  let id = coordinator.manager.selectedID,
                  let ws = coordinator.manager.workspaces.first(where: { $0.id == id }),
                  ws.kind == .normal,
                  let pane = self.focusedPane(in: ws) else { return }
            await coordinator.addTab(workspaceId: id, paneId: pane.id, kind: .shell)
        }
    }

    @objc private func cycleActiveTabNext(_ sender: Any?) {
        MainActor.assumeIsolated { cycleActiveTab(by: +1) }
    }

    @objc private func cycleActiveTabPrev(_ sender: Any?) {
        MainActor.assumeIsolated { cycleActiveTab(by: -1) }
    }

    @MainActor
    private func cycleActiveTab(by delta: Int) {
        guard let manager = workspaceManager,
              let id = manager.selectedID,
              let ws = manager.workspaces.first(where: { $0.id == id }),
              ws.kind == .normal,
              let pane = focusedPane(in: ws),
              !pane.tabs.isEmpty,
              let activeId = pane.activeTabId ?? pane.tabs.first?.id,
              let idx = pane.tabs.firstIndex(where: { $0.id == activeId }) else { return }
        let count = pane.tabs.count
        let next = (idx + delta + count) % count
        manager.selectTab(workspaceId: id, paneId: pane.id, tabId: pane.tabs[next].id)
    }
}

/// AppSettingsState를 관찰해 isShowingSettings 변경 시 루트 뷰 전체를 다시 그리는 호스트.
///
/// RootView 자체는 비앱 타겟 컴파일 호환을 위해 Binding만 받는다. 그러나 NSHostingView에
/// Binding만 넘기면 관찰 주체가 없어 값이 바뀌어도 재렌더가 일어나지 않는다(설정 화면이
/// 열리지 않고, 돌아가기도 동작하지 않는 원인). 관찰 책임을 이 래퍼가 진다.
private struct SettingsObservingHost<Content: View>: View {
    @ObservedObject var settingsState: AppSettingsState
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
    }
}
