import AppKit

/// The app's own shortcuts, listed on the Shortcuts page next to the plugins'. It is always on and has
/// no page of its own, so it is not in `PluginRegistry`.
@MainActor
final class CorePlugin: Plugin {
    nonisolated static let pluginID = "app"

    let id = CorePlugin.pluginID
    let name = "Quick Capture"
    let summary = "Shortcuts for the app itself."
    let symbol = "command"
    let actions = [
        PluginAction(id: "open_settings", title: "Open Settings", symbol: "gearshape", defaultShortcut: "<ctrl>+<alt>+,"),
    ]

    func perform(_ action: PluginAction) {
        if action.id == "open_settings" { state.showSettings?(nil) }
    }
}
