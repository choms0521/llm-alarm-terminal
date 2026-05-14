import AppKit
import Foundation
import SwiftUI
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let logger = Logger(subsystem: "com.choms0521.ClaudeAlarmTerminal", category: "AppDelegate")

    private var mainWindow: NSWindow?
    private var ghosttyApp: GhosttyApp?
    private var workspaceManager: WorkspaceManager?
    private let sessionManager = SessionManager()

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
            // Application Support 디렉터리 접근 실패는 macOS 환경 자체 문제 — 사용자에게 즉시 surface.
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

        let hosting = NSHostingView(rootView: RootView(manager: manager))
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
        // Best-effort cleanup: kill any session not yet wired to a workspace lifecycle.
        // Day 5 introduces workspace-aware cleanup via terminateAll(inWorkspace:).
        Task { [sessionManager] in
            // No-op for now (sessions list internal to actor); Day 5 wires it.
            _ = await sessionManager.count()
        }
    }

    // MARK: - Menu wiring

    private func configureMainMenu() {
        let mainMenu = NSMenu()

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

        // Workspace 메뉴 placeholder. Day 8 에서 단축키 wiring 완성.
        let wsMenuItem = NSMenuItem()
        let wsMenu = NSMenu(title: "Workspace")
        let newWorkspace = NSMenuItem(
            title: "새 워크스페이스",
            action: #selector(newWorkspaceFromMenu(_:)),
            keyEquivalent: ""
        )
        newWorkspace.target = self
        wsMenu.addItem(newWorkspace)
        wsMenuItem.submenu = wsMenu
        mainMenu.addItem(wsMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func newWorkspaceFromMenu(_ sender: Any?) {
        // Day 3 메뉴는 UI 트리거 placeholder. Day 8 에서 정식 단축키 + cwd picker 통합 후 동작.
        Task { @MainActor [weak self] in
            guard let self, let manager = self.workspaceManager else { return }
            manager.addWorkspace(
                cwd: WorkspaceManager.defaultWorkspaceRoot(),
                name: "새 워크스페이스 \(manager.workspaces.count)"
            )
        }
    }
}
