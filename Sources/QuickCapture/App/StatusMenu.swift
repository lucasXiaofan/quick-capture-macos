import AppKit

/// Builds the menu bar menu from the enabled plugins every time it opens, so switching a plugin off
/// (or a state change such as starting a recording) shows up the next time it's clicked.
///
///     Screenshot → Current Note   ⌃⌘I     ← each plugin's primaryActions(), 7 rows at most
///     Video Dashboard             ⌃⌥D
///     ⚠ Unsaved Captures (3)…             ← menuAlerts()
///     ─────────
///     Plugins ▸  Obsidian Capture ▸        ← everything else, one submenu per plugin
///                …
///                Manage Plugins…
///     ─────────
///     Settings…  /  Quit
@MainActor
enum StatusMenu {
    static let maxPrimaryRows = 7

    static func rebuild(_ menu: NSMenu, state: AppState, showSettings: @escaping (String?) -> Void) {
        menu.removeAllItems()
        let plugins = state.enabledPlugins

        for (plugin, action) in primaryRows(plugins) { menu.addItem(item(action, of: plugin, state: state)) }
        plugins.flatMap { $0.menuAlerts() }.forEach(menu.addItem)

        if !plugins.isEmpty {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            let root = NSMenuItem(title: "Plugins", action: nil, keyEquivalent: "")
            root.image = NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)
            let sub = NSMenu()
            for plugin in plugins { sub.addItem(submenu(for: plugin, state: state, showSettings: showSettings)) }
            sub.addItem(.separator())
            sub.addItem(ClosureMenuItem("Manage Plugins…") { showSettings("general") })
            root.submenu = sub
            menu.addItem(root)
        }
        menu.addItem(.separator())

        if !state.setupIssues.isEmpty || !plugins.allSatisfy(\.isReady) {
            let page = plugins.first { !$0.isReady || !$0.setupIssues.isEmpty }?.id
            menu.addItem(ClosureMenuItem("Finish Setup…", symbol: "exclamationmark.circle") { showSettings(page ?? "general") })
        }
        let settings = ClosureMenuItem("Settings…") { showSettings(nil) }
        if let action = state.core.action("open_settings") { applyShortcut(action, of: state.core, to: settings, state: state) }
        menu.addItem(settings)
        menu.addItem(NSMenuItem(title: "Quit Quick Capture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// Every plugin's first primary action, then second ones while there's room — so a plugin
    /// enabled later still gets a row before an earlier one gets its second.
    static func primaryRows(_ plugins: [Plugin]) -> [(Plugin, PluginAction)] {
        let lists = plugins.map { p in p.primaryActions().filter(p.isAvailable).map { (p, $0) } }
        var picked = Set<String>()
        for rank in 0..<(lists.map(\.count).max() ?? 0) {
            for list in lists where rank < list.count && picked.count < maxPrimaryRows {
                picked.insert(key(list[rank]))
            }
        }
        return lists.flatMap { $0 }.filter { picked.contains(key($0)) }   // keep plugin order
    }

    private static func key(_ row: (Plugin, PluginAction)) -> String { "\(row.0.id).\(row.1.id)" }

    private static func submenu(for plugin: Plugin, state: AppState, showSettings: @escaping (String?) -> Void) -> NSMenuItem {
        let root = NSMenuItem(title: plugin.name, action: nil, keyEquivalent: "")
        root.image = NSImage(systemSymbolName: plugin.symbol, accessibilityDescription: nil)
        let sub = NSMenu()
        for action in plugin.actions where plugin.isAvailable(action) && plugin.showsInMenu(action) {
            sub.addItem(item(action, of: plugin, state: state))
        }
        let extra = plugin.menuItems()
        if !extra.isEmpty, !sub.items.isEmpty { sub.addItem(.separator()) }
        extra.forEach(sub.addItem)
        if !sub.items.isEmpty { sub.addItem(.separator()) }
        sub.addItem(ClosureMenuItem("\(plugin.name) Settings…", symbol: "gearshape") { showSettings(plugin.id) })
        root.submenu = sub
        return root
    }

    private static func item(_ action: PluginAction, of plugin: Plugin, state: AppState) -> NSMenuItem {
        let item = ClosureMenuItem(action.title, symbol: action.symbol) { [weak plugin] in
            // Let the menu close before anything (like a screenshot crosshair) appears.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { plugin?.perform(action) }
        }
        applyShortcut(action, of: plugin, to: item, state: state)
        return item
    }

    private static func applyShortcut(_ action: PluginAction, of plugin: Plugin, to item: NSMenuItem, state: AppState) {
        guard let (key, mods) = state.config.shortcut(action, of: plugin)?.menuKeyEquivalent else { return }
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = mods
    }
}
