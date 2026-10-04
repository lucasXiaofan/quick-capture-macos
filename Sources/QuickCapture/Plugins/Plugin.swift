import AppKit
import SwiftUI

/// One shortcut-driven feature. The app core owns config.json, global hotkeys, the menu bar
/// menu and the Settings window; a plugin declares its actions and reacts to them.
///
/// To add one, see `.claude/skills/new-plugin/SKILL.md`, then list it in `PluginRegistry`.
@MainActor
protocol Plugin: AnyObject {
    /// Stable key in config.json ("plugins.<id>") and folder name under Resources/. Never rename once shipped.
    var id: String { get }
    var name: String { get }
    /// One sentence, shown in Settings and onboarding.
    var summary: String { get }
    /// SF Symbol name.
    var symbol: String { get }
    var enabledByDefault: Bool { get }
    /// Things a shortcut can trigger. Each gets a shortcut recorder in Settings and a menu item.
    var actions: [PluginAction] { get }

    /// False hides an action's global shortcut (it isn't registered, so the key reaches other apps).
    /// Call `state.applyHotkeys()` after the answer changes.
    func isAvailable(_ action: PluginAction) -> Bool

    /// Called when a hotkey or menu item fires. Only called while the plugin is enabled.
    func perform(_ action: PluginAction)

    /// The plugin's settings encoded as JSON, used to show every option in config.json.
    func defaultSettings() -> [String: JSONValue]
    /// Throw to reject a config change (from Settings or a hand edit). The previous config stays active.
    func validate(_ config: AppConfig) throws

    /// Enabled at launch, or switched on in Settings.
    func activate()
    /// Switched off: close windows, stop processes, release resources.
    func deactivate()
    /// config.json changed while enabled.
    func configDidChange()

    /// Extra menu bar menu items shown under the plugin's actions.
    func menuItems() -> [NSMenuItem]
    /// Plugin-specific settings: `Section`s placed in the plugin's page in Settings.
    func settingsView() -> AnyView?
    /// Setup steps (permissions, external apps) shown in onboarding and Settings.
    func setupView() -> AnyView?
    /// False while something required is missing. Blocks "Get Started" in onboarding.
    var isReady: Bool { get }
    /// Human-readable problems; any makes the menu show "Finish Setup…".
    var setupIssues: [String] { get }
}

extension Plugin {
    var enabledByDefault: Bool { true }
    func isAvailable(_ action: PluginAction) -> Bool { true }
    func defaultSettings() -> [String: JSONValue] { [:] }
    func validate(_ config: AppConfig) throws {}
    func activate() {}
    func deactivate() {}
    func configDidChange() {}
    func menuItems() -> [NSMenuItem] { [] }
    func settingsView() -> AnyView? { nil }
    func setupView() -> AnyView? { nil }
    var isReady: Bool { true }
    var setupIssues: [String] { [] }

    var state: AppState { AppState.shared }
    var isEnabled: Bool { state.config.isEnabled(self) }
    func action(_ id: String) -> PluginAction? { actions.first { $0.id == id } }

    /// Encodes a settings type's defaults for `defaultSettings()`.
    func encodeDefaults<T: PluginSettings>(_ type: T.Type) -> [String: JSONValue] {
        (try? JSONValue(encoding: T()))?.object ?? [:]
    }
}

struct PluginAction: Identifiable, Hashable {
    /// Key under the plugin's "hotkeys" in config.json.
    let id: String
    let title: String
    let symbol: String
    /// pynput-style, e.g. "<cmd>+<shift>+i". nil means no shortcut until the user sets one.
    var defaultShortcut: String?
}

/// Menu item that runs a closure, so plugins don't need to be NSObjects to build menus.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String? = nil, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() { handler() }
}
