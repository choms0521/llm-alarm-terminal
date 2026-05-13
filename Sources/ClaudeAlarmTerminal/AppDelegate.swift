import AppKit
import Foundation
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let logger = Logger(subsystem: "com.choms0521.ClaudeAlarmTerminal", category: "AppDelegate")

    private var mainWindow: NSWindow?
    private var ghosttyApp: GhosttyApp?
    private var terminalView: GhosttyTerminalView?

    /// Single-session bookkeeping for P1. We keep the current session's UUID
    /// here so the Cmd+T / Cmd+Shift+T handlers can terminate it before
    /// spawning a new one (P1 invariant: max 1 session at a time).
    private let sessionManager = SessionManager()
    private var currentSessionID: UUID?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let contentRect = NSRect(x: 0, y: 0, width: 960, height: 600)
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = "Claude Alarm Terminal"
        window.minSize = NSSize(width: 480, height: 320)
        window.center()

        // Instantiate libghostty app + idle-passive surface (no PTY attached
        // yet). Cmd+T / Cmd+Shift+T swap the surface to one running a real
        // command via `replaceCommand`. The empty surface still renders and
        // keeps AppKit's contentView populated so the launch produces a
        // visible window even if the user never invokes a session.
        if let app = GhosttyApp() {
            let view = GhosttyTerminalView(app: app, command: nil, cwd: nil, frame: contentRect)
            window.contentView = view
            window.makeFirstResponder(view)
            self.ghosttyApp = app
            self.terminalView = view
        }

        window.makeKeyAndOrderFront(nil)
        self.mainWindow = window

        configureMainMenu()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Best-effort cleanup so child PTY processes don't linger after the
        // app shuts down. Termination is async; we don't wait for it because
        // AppKit will shoot us anyway.
        if let id = currentSessionID {
            Task { [sessionManager] in
                try? await sessionManager.terminate(id: id)
            }
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

        // Session menu
        let sessionMenuItem = NSMenuItem()
        let sessionMenu = NSMenu(title: "Session")
        let newShell = NSMenuItem(
            title: "New Shell Session",
            action: #selector(newShellSession(_:)),
            keyEquivalent: "t"
        )
        newShell.keyEquivalentModifierMask = [.command]
        newShell.target = self
        sessionMenu.addItem(newShell)

        let newClaude = NSMenuItem(
            title: "New Claude Session",
            action: #selector(newClaudeSession(_:)),
            keyEquivalent: "t"
        )
        newClaude.keyEquivalentModifierMask = [.command, .shift]
        newClaude.target = self
        sessionMenu.addItem(newClaude)

        sessionMenuItem.submenu = sessionMenu
        mainMenu.addItem(sessionMenuItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Session shortcuts

    @objc private func newShellSession(_ sender: Any?) {
        spawnSession(kind: .shell)
    }

    @objc private func newClaudeSession(_ sender: Any?) {
        spawnSession(kind: .claude)
    }

    /// Resolve the command + args list for the given session kind. Returns
    /// the command string libghostty will pass to its internal PTY (which
    /// invokes `/bin/sh -c <command>` style — multi-word commands are fine).
    /// Throws `BinaryResolveError.claudeNotFound` when `kind == .claude` and
    /// no claude binary is on PATH or in the brew fallbacks.
    private func resolveCommandString(kind: SessionKind) throws -> String {
        switch kind {
        case .claude:
            return try resolveClaudeBinary()
        case .shell:
            let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            return "\(shellPath) -l"
        }
    }

    private func spawnSession(kind: SessionKind) {
        guard let view = terminalView else { return }

        let cwd = FileManager.default.homeDirectoryForCurrentUser.path

        // Resolve the command synchronously on the main thread so we can
        // present the Korean NSAlert immediately on failure without bouncing
        // through the SessionManager actor.
        let commandString: String
        do {
            commandString = try resolveCommandString(kind: kind)
        } catch {
            presentSpawnFailureAlert(kind: kind, error: error)
            return
        }

        Task { [weak self] in
            guard let self = self else { return }

            // P1 invariant: tear down any existing session first.
            if let existing = self.currentSessionID {
                try? await self.sessionManager.terminate(id: existing)
                await self.sessionManager.remove(id: existing)
                await MainActor.run {
                    self.currentSessionID = nil
                }
            }

            do {
                let session = try await self.sessionManager.createInternal(
                    kind: kind, cwd: cwd
                )
                let sessionID = session.id
                await MainActor.run {
                    self.currentSessionID = sessionID
                    // Swap libghostty's surface to the new command. libghostty
                    // owns the PTY for this surface and renders the child's
                    // output natively (ANSI codes interpreted correctly).
                    view.replaceCommand(commandString, cwd: cwd)
                }
            } catch {
                await MainActor.run {
                    self.presentSpawnFailureAlert(kind: kind, error: error)
                }
            }
        }
    }

    private func presentSpawnFailureAlert(kind: SessionKind, error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning

        switch kind {
        case .claude:
            alert.messageText = "Claude 세션을 시작하지 못했습니다."
            if case BinaryResolveError.claudeNotFound = error {
                alert.informativeText = "claude 실행 파일을 찾을 수 없습니다. brew install claude 후 다시 시도하시기 바랍니다."
            } else {
                alert.informativeText = String(describing: error)
            }
        case .shell:
            alert.messageText = "Shell 세션을 시작하지 못했습니다."
            alert.informativeText = String(describing: error)
        }

        alert.addButton(withTitle: "확인")
        if let window = mainWindow {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}
