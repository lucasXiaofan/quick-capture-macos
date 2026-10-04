import AppKit
import ServiceManagement

/// Shared, observable app state: configuration, plugins, permissions, and hotkey registration.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    let plugins: [Plugin]
    /// The app's own shortcuts (Open Settings). Always on; not listed as a plugin.
    let core: Plugin = CorePlugin()
    @Published private(set) var config = AppConfig()
    @Published private(set) var configError: String?
    @Published private(set) var hotkeyWarnings: [String] = []
    @Published var screenGranted = CGPreflightScreenCaptureAccess()
    @Published var screenRequested = UserDefaults.standard.bool(forKey: "screenRequested")
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled

    /// Opens Settings at a page ("general" or a plugin id).
    var showSettings: ((String?) -> Void)?
    private var active: Set<String> = []
    private var lastConfigData: Data?
    private var lastModified: Date?
    private var hotkeysPaused = false

    private init() { plugins = PluginRegistry.makeAll() }

    var enabledPlugins: [Plugin] { plugins.filter { config.isEnabled($0) } }
    func plugin(_ id: String) -> Plugin? { plugins.first { $0.id == id } }

    /// Problems worth a "Finish Setup…" item in the menu.
    var setupIssues: [String] {
        var issues = enabledPlugins.flatMap(\.setupIssues) + hotkeyWarnings
        if let configError { issues.insert(configError, at: 0) }
        return issues
    }

    func start() {
        Paths.migrateLegacyHome()
        try? FileManager.default.createDirectory(at: Paths.home, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: Paths.config.path) {
            reloadFromDisk(announce: false)
        } else {
            save(AppConfig())
        }
        // Watch config.json so edits made in a text editor take effect immediately.
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollConfigFile() }
        }
        // Refresh permission state whenever the user comes back from System Settings.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
    }

    // MARK: Config

    private func pollConfigFile() {
        let modified = (try? Paths.config.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard modified != lastModified else { return }
        lastModified = modified
        guard let data = try? Data(contentsOf: Paths.config), data != lastConfigData else { return }
        reloadFromDisk(announce: true)
    }

    private func reloadFromDisk(announce: Bool) {
        lastModified = (try? Paths.config.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        lastConfigData = try? Data(contentsOf: Paths.config)
        do {
            let loaded = try AppConfig.load()
            try validate(loaded)
            let normalized = loaded.normalized(for: [core] + plugins)
            // Migrates old files and writes every option out; at launch also rewrites legacy layouts.
            if normalized != loaded || (!announce && lastConfigData != normalized.encoded()) {
                save(normalized)
            } else {
                config = loaded
                configError = nil
                applied()
            }
            if announce { Toast.show("Settings reloaded from config.json", symbol: "arrow.clockwise") }
        } catch {
            configError = error.localizedDescription
            if announce { Toast.show("config.json not applied: \(error.localizedDescription)", symbol: "exclamationmark.triangle", isError: true) }
            if !announce { applied() }  // Keep defaults working if the file is broken at launch.
        }
    }

    /// Validates, writes, and applies a change. Throws without saving if invalid.
    func update(_ change: (inout AppConfig) -> Void) throws {
        var next = config
        change(&next)
        try validate(next)
        save(next.normalized(for: [core] + plugins))
    }

    func setEnabled(_ on: Bool, plugin: Plugin) throws {
        try update { $0.setEnabled(on, for: plugin) }
    }

    /// A plugin's typed settings. Falls back to defaults if the stored values are invalid.
    func settings<T: PluginSettings>(_ type: T.Type, for pluginID: String) -> T {
        (try? config.settings(type, for: pluginID)) ?? T()
    }

    func updateSettings<T: PluginSettings>(_ type: T.Type, for pluginID: String, _ change: (inout T) -> Void) throws {
        var settings = try config.settings(type, for: pluginID)
        change(&settings)
        try update { $0.setSettings(settings, for: pluginID) }
    }

    private func validate(_ next: AppConfig) throws {
        var seen: [Shortcut: String] = [:]
        for plugin in [core] + plugins where plugin === core || next.isEnabled(plugin) {
            for action in plugin.actions {
                guard let raw = next.shortcutString(action, of: plugin) else { continue }
                let label = "\(plugin.name): \(action.title)"
                guard let s = Shortcut(config: raw) else {
                    throw AppError("“\(raw)” is not a valid shortcut for \(label). "
                                   + "Use e.g. <cmd>+<shift>+i, with at least one of <cmd>, <ctrl>, <alt>.")
                }
                if let other = seen[s] { throw AppError("\(label) and \(other) use the same shortcut \(s.display).") }
                seen[s] = label
            }
            try plugin.validate(next)
        }
    }

    private func save(_ next: AppConfig) {
        let data = next.encoded()
        try? data.write(to: Paths.config, options: .atomic)
        lastConfigData = data
        lastModified = (try? Paths.config.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        config = next
        configError = nil
        applied()
    }

    /// Starts/stops plugins to match the config, then re-registers hotkeys.
    private func applied() {
        for plugin in plugins {
            let on = config.isEnabled(plugin)
            if on && !active.contains(plugin.id) {
                active.insert(plugin.id)
                plugin.activate()
            } else if !on && active.contains(plugin.id) {
                active.remove(plugin.id)
                plugin.deactivate()
            }
            if on { plugin.configDidChange() }
        }
        applyHotkeys()
    }

    // MARK: Shortcut overview & conflicts

    struct ShortcutSlot: Identifiable {
        let plugin: Plugin
        let action: PluginAction
        let id: String
        /// "Plugin: Action", or just the action for the app's own shortcuts.
        let label: String

        @MainActor init(plugin: Plugin, action: PluginAction) {
            self.plugin = plugin
            self.action = action
            id = plugin.id + "." + action.id
            label = plugin.id == CorePlugin.pluginID ? action.title : "\(plugin.name): \(action.title)"
        }
    }

    /// Every action that can have a shortcut: the app's own first, then each plugin's (on or off).
    var shortcutSlots: [ShortcutSlot] {
        ([core] + plugins).flatMap { plugin in plugin.actions.map { ShortcutSlot(plugin: plugin, action: $0) } }
    }

    func shortcut(of slot: ShortcutSlot) -> Shortcut? { config.shortcut(slot.action, of: slot.plugin) }

    /// Other actions (in any plugin, even switched-off ones) already using `shortcut`.
    func slots(using shortcut: Shortcut, excluding slot: ShortcutSlot?) -> [ShortcutSlot] {
        shortcutSlots.filter { $0.id != slot?.id && self.shortcut(of: $0) == shortcut }
    }

    /// Shortcuts that more than one action uses right now (for example after a hand edit while a plugin was off).
    var duplicateShortcuts: [(Shortcut, [ShortcutSlot])] {
        var groups: [Shortcut: [ShortcutSlot]] = [:]
        for slot in shortcutSlots { if let s = shortcut(of: slot) { groups[s, default: []].append(slot) } }
        return groups.filter { $0.value.count > 1 }.sorted { $0.key.display < $1.key.display }.map { ($0.key, $0.value) }
    }

    /// Sets `shortcut` for `slot`, first clearing it from the actions that held it.
    func assign(_ shortcut: Shortcut?, to slot: ShortcutSlot, replacing others: [ShortcutSlot] = []) throws {
        try update { cfg in
            for other in others { cfg.setShortcut(nil, for: other.action, of: other.plugin) }
            cfg.setShortcut(shortcut, for: slot.action, of: slot.plugin)
        }
    }

    // MARK: Hotkeys

    func applyHotkeys() {
        guard !hotkeysPaused else { return }
        var bindings: [(Shortcut, String, () -> Void)] = []
        for plugin in [core] + enabledPlugins {
            for action in plugin.actions {
                guard plugin.isAvailable(action), let s = config.shortcut(action, of: plugin) else { continue }
                bindings.append((s, action.title, { [weak plugin] in plugin?.perform(action) }))
            }
        }
        hotkeyWarnings = HotkeyCenter.shared.register(bindings)
    }

    /// While recording a new shortcut, existing ones must not intercept the key press.
    func pauseHotkeys(_ paused: Bool) {
        hotkeysPaused = paused
        if paused { HotkeyCenter.shared.unregisterAll() } else { applyHotkeys() }
    }

    // MARK: Permissions & login item

    func refreshPermissions() {
        screenGranted = CGPreflightScreenCaptureAccess()
        loginEnabled = SMAppService.mainApp.status == .enabled
    }

    func requestScreenRecording() {
        if !screenRequested {
            screenRequested = true
            UserDefaults.standard.set(true, forKey: "screenRequested")
            if CGRequestScreenCaptureAccess() { screenGranted = true; return }
        }
        // After the first prompt macOS won't ask again; send the user to the right pane.
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            else { Toast.show("Couldn't change login item: \(error.localizedDescription)", symbol: "exclamationmark.triangle", isError: true) }
        }
        refreshPermissions()
    }

    func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.7; /usr/bin/open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
