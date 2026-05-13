import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: NSWindow?
    private var ghosttyApp: GhosttyApp?
    private var terminalView: GhosttyTerminalView?

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

        // Day 3: instantiate libghostty app + surface and attach as the
        // window content view. If the app fails to construct we leave the
        // empty window in place so the launch still produces something
        // visible for debugging.
        if let app = GhosttyApp() {
            let view = GhosttyTerminalView(app: app, frame: contentRect)
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

        NSApp.mainMenu = mainMenu
    }
}
