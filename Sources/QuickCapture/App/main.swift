import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let state = AppState.shared
    private let windows = Windows()
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One instance only: opening the app again just shows the running one's settings.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0 != .current }
        if let other = others.first {
            other.activate()
            NSApp.terminate(nil)
            return
        }
        removeLegacyLaunchAgent()
        DebugSnapshot.installIfRequested()
        NSApp.mainMenu = Self.makeMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Quick Capture")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        state.showSettings = { [weak self] page in self?.showSetup(page: page) }
        state.start()

        if !UserDefaults.standard.bool(forKey: "onboarded") || !state.enabledPlugins.allSatisfy(\.isReady) {
            windows.showOnboarding(state: state)
        }
    }

    /// Launching the app from Finder/Spotlight while it's running opens Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windows.showSettings(state: state)
        return true
    }

    private func showSetup(page: String? = nil) {
        if UserDefaults.standard.bool(forKey: "onboarded") {
            windows.showSettings(state: state, page: page)
        } else {
            windows.showOnboarding(state: state)
        }
    }

    /// The earlier Python version registered a LaunchAgent; the app now uses a standard Login Item.
    private func removeLegacyLaunchAgent() {
        guard let text = try? String(contentsOf: Paths.legacyAgent, encoding: .utf8),
              text.contains("quick_capture.py") else { return }
        try? FileManager.default.removeItem(at: Paths.legacyAgent)
    }

    /// Menu-bar apps have no visible menu bar, but text fields still need ⌘C/⌘V/⌘A/⌘Z from an Edit menu.
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        main.addItem(editItem)
        let windowItem = NSMenuItem()
        windowItem.submenu = NSMenu(title: "Window")
        windowItem.submenu?.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        main.addItem(windowItem)
        return main
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        StatusMenu.rebuild(menu, state: state) { [weak self] page in self?.showSetup(page: page) }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
