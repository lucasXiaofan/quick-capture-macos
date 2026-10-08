---
name: new-plugin
description: Add a new shortcut-driven feature (plugin) to the Quick Capture macOS menu-bar app. Use when the user wants a new global shortcut, a new menu-bar feature, or a new tool/window in this project — e.g. "add a plugin that…", "add a shortcut to…", "new feature for the app".
---

# Creating a Quick Capture plugin

## The idea

Every feature in this app is a plugin: a Swift class that **declares** what it offers — actions,
settings, setup steps, menu priorities — and the core decides where those appear. A plugin never
builds the menu bar menu, the Settings window, hotkeys or config.json itself; it describes itself and
reacts to `perform(_:)`. That's why switching a plugin off removes it everywhere at once (menu,
shortcuts, Settings) with no plugin code involved, and why a new plugin only touches its own folder
plus one line in `PluginRegistry`.

The core gives every plugin, for free:

- an on/off switch, stored in `config.json` and shown in Settings and onboarding;
- a shortcut recorder per action, conflict checking across all plugins, and system-wide hotkeys;
- a place in the menu bar menu (see *Where things show up*);
- typed settings persisted in `config.json` (hand-edits apply live);
- a Settings page (`PluginPage`) that hosts the plugin's own overview, setup steps and settings sections.

## Where things show up

| Plugin declares | Appears in |
|---|---|
| `actions` | Settings → shortcut recorder each; Settings → Shortcuts page; the plugin's menu submenu |
| `primaryActions()` (default: first action) | **Top of the menu bar menu.** 1–2 per plugin; the core shows 7 rows at most in total, giving every enabled plugin its first row before anyone gets a second |
| `showsInMenu(_:)` | Hides an action from the menu entirely (shortcut still works) — per-slot variants, "Stop" while idle |
| `menuAlerts()` | Top of the menu, only while something needs attention ("Unsaved Captures (3)…") |
| `menuItems()` | **Plugins ▸ <name> ▸**, under the actions (toggles, "Open …"). A "<name> Settings…" link is added for you |
| `overviewView()` | Top of the plugin's Settings page — the thing people come to the page for (e.g. Open Dashboard) |
| `setupView()`, `setupIssues`, `isReady` | Onboarding, Settings → Setup, and "Finish Setup…" in the menu |
| `settingsView()` | The plugin's Settings page, below Shortcuts |

The menu is rebuilt each time it opens (`App/StatusMenu.swift`), so these hooks may depend on state
(e.g. Media Capture puts **Stop** first while recording). Pick primaries by asking "what would someone
open the menu for?" — usually the window/dashboard or the main capture action — not by listing everything.

Read these first — they are short and define the contract:

- `Sources/QuickCapture/Plugins/Plugin.swift` — the `Plugin` protocol (every hook has a default).
- `Sources/QuickCapture/Plugins/PluginRegistry.swift` — the list of shipped plugins.
- `Sources/QuickCapture/App/Config.swift` — `AppConfig`, `PluginSettings`, `Paths`.
- `Sources/QuickCapture/App/StatusMenu.swift` — how the menu is assembled from those hooks.
- One existing plugin as a model: `Plugins/SkillManager/SkillManagerPlugin.swift` (smallest: one
  action that opens a window), `Plugins/AIChat/AIChatPlugin.swift` (window + external CLIs),
  `Plugins/VideoNotes/VideoNotesPlugin.swift` (state-dependent menu, overview, dashboard), or
  `Plugins/ObsidianCapture/ObsidianCapturePlugin.swift` (permissions, menu items and alerts, setup steps).

## Steps

1. **Pick an id** — `snake_case`, e.g. `clipboard_history`. It is the key under `plugins` in
   config.json and the folder name under `Resources/`. Never rename it after shipping (users'
   settings would be orphaned).

2. **Create `Sources/QuickCapture/Plugins/<Name>/<Name>Plugin.swift`** from the template below.
   SwiftPM compiles every file under `Sources/QuickCapture`, so no project file needs editing.
   Put extra types (windows, views, helpers) in the same folder.

3. **Register it** — add `<Name>Plugin()` to `PluginRegistry.makeAll()`. Order there is the order
   in the menu and in Settings.

4. **Decide its menu presence** — which 1–2 actions are primary (`primaryActions()`), which are
   shortcut-only (`showsInMenu` false), and whether anything belongs in `overviewView()`.

5. **Resources** (HTML, JS, images, scripts) go in `Resources/<id>/`; `scripts/build.sh` copies the
   whole `Resources/` folder into the app. Load them with `Paths.resource("file.ext", plugin: id)`.
   Files the plugin writes at runtime go in `Paths.data(for: id)` (create the folder first).

6. **Build and check**
   ```bash
   swift build
   node tests/bridge.test.cjs && node tests/render.test.cjs && node tests/skills.test.cjs
   scripts/build.sh --install
   ```
   Then confirm: `~/Library/Application Support/Quick Capture/config.json` gained a
   `plugins.<id>` entry with `enabled`, `hotkeys` and your settings; the plugin appears in
   Settings (sidebar) with working toggle and shortcut recorders; the shortcut fires from any app;
   the menu shows its primary action at the top and a submenu under **Plugins ▸**, and both
   disappear when the plugin is switched off.
   If the plugin has pure logic (parsers, formatters), add a test under `tests/` or a small
   `swiftc` harness like `tests/chat_smoke` (see docs/development.md).

7. **Document it** — add a row to the plugin table in `README.md`, a `docs/<plugin>.md` page
   (shortcuts, setup, options), its keys in `docs/configuration.md`, and a `CHANGELOG.md` entry.

## Template

```swift
import AppKit
import SwiftUI

struct ExampleSettings: PluginSettings {
    // Every stored property needs a default; missing keys in config.json fall back to these.
    var greeting = "Hello"
    var showToast = true

    enum CodingKeys: String, CodingKey {   // config.json uses snake_case keys
        case greeting, showToast = "show_toast"
    }
}

@MainActor
final class ExamplePlugin: ObservableObject, Plugin {
    nonisolated static let pluginID = "example"

    let id = ExamplePlugin.pluginID
    let name = "Example"
    let summary = "One sentence saying what the shortcut does."
    let symbol = "sparkles"                 // SF Symbol
    var enabledByDefault: Bool { false }    // new plugins should usually start off
    let actions = [
        PluginAction(id: "run", title: "Run Example", symbol: "sparkles", defaultShortcut: nil),
    ]

    var settings: ExampleSettings { state.settings(ExampleSettings.self, for: id) }

    func update(_ change: (inout ExampleSettings) -> Void) throws {
        try state.updateSettings(ExampleSettings.self, for: id, change)
    }

    func perform(_ action: PluginAction) {
        switch action.id {
        case "run": if settings.showToast { Toast.show(settings.greeting) }
        default: break
        }
    }

    // Top of the menu bar menu. The default (first action) is fine here; override when the most
    // important thing isn't first, or depends on state.
    // func primaryActions() -> [PluginAction] { [action("run")].compactMap { $0 } }

    func defaultSettings() -> [String: JSONValue] { encodeDefaults(ExampleSettings.self) }

    func validate(_ config: AppConfig) throws {
        let s = try config.settings(ExampleSettings.self, for: id)
        if s.greeting.isEmpty { throw AppError("example.greeting can't be empty.") }
    }

    // Optional hooks (defaults do nothing): activate(), deactivate(), configDidChange(),
    // showsInMenu(_:), menuAlerts(), menuItems(), overviewView(), setupView(), isReady, setupIssues.

    func settingsView() -> AnyView? { AnyView(ExampleSettingsView(plugin: self, state: state)) }
}

private struct ExampleSettingsView: View {
    @ObservedObject var plugin: ExamplePlugin
    @ObservedObject var state: AppState   // observing state re-renders when config.json changes

    var body: some View {
        Section("Example") {   // return Sections: they are placed inside the plugin's Settings Form
            TextField("Greeting", text: Binding(get: { plugin.settings.greeting },
                                                set: { v in try? plugin.update { $0.greeting = v } }))
            Toggle("Show a toast", isOn: Binding(get: { plugin.settings.showToast },
                                                 set: { v in try? plugin.update { $0.showToast = v } }))
        }
    }
}
```

## Rules that keep the app shareable and stable

- **No machine-specific paths or assumptions.** Default settings must work on any Mac: use
  `FileManager.default.homeDirectoryForCurrentUser`, `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)`
  to find apps, and `LoginEnvironment.shared.find("tool")` to find command-line tools (apps started
  from Finder don't get the user's shell PATH). Run found tools with
  `LoginEnvironment.shared.environment(for: path)` so `#!/usr/bin/env node` scripts work.
- **No network dependencies at runtime** for UI: vendor web libraries into `Resources/<id>/vendor/`
  (see `scripts/vendor.sh`) instead of loading from a CDN.
- **Declare, don't build shared UI:** never add items to the status menu, register hotkeys or write
  config.json directly — use the hooks above so on/off, conflicts and ordering keep working.
- **Keep the menu short:** at most two `primaryActions()`; everything else lives in the plugin's
  submenu. Hide shortcut-only extras and items that only matter in some state with `showsInMenu`.
  Use `menuAlerts()` only for something the user should act on now.
- **Plain keys:** an action that is only active temporarily may set `allowsBareKey: true` (with `isAvailable`), so the user can bind e.g. `1` — never for an always-registered action.
- **Shortcuts:** `defaultShortcut` needs ⌘, ⌥ or ⌃ (function keys excepted) and must not clash with
  shipped defaults — currently ⌘⇧I, ⌘⇧J, ⌥⇧⌘I, ⌥⇧⌘J (Obsidian Capture), ⌃⌥Space (AI Chat), ⌃⌥K (Skill Manager), Media Capture's (⌃⌥R, ⌃⌥⇧R, ⌃⌥P, ⌃⌥S, ⌃⌥X, ⌃⌥V, ⌃⌥F, ⌃⌥A, ⌃⌥⇧A), ⌃⌥, (Open Settings), and Nose Control's (see docs/nose-control.md). Settings → Shortcuts shows them all.
  Prefer `nil` (user assigns one) over grabbing a combination other apps use; Carbon hotkeys
  swallow the key press system-wide.
- **Main thread:** `perform` runs on the main actor. Do slow work in `Task {}` / `Shell.run` /
  `StreamingProcess`, never block.
- **Lifecycle:** `activate()` runs at launch (if enabled) and when switched on; `deactivate()` must
  close windows and stop processes; `configDidChange()` runs after every config change.
- **Permissions:** macOS permissions live in `AppState` (e.g. `screenGranted`,
  `requestScreenRecording()`). Report missing ones through `setupIssues` and a `setupView()` built
  from `StepRow`, so the menu shows "Finish Setup…". Block onboarding with `isReady` only for
  things the plugin truly can't work without.
- **Errors:** throw `AppError("…")` with a message a user can act on; use `Toast.show` for
  confirmations. A plugin must never crash the app — no force-unwraps on external data.
- **Build/scratch files:** write temporary files, symlinks and large file trees to `mktemp -d`, never
  inside the project. The project may sit in an Obsidian vault, and Obsidian follows symlinks (a
  `/Applications` link in `dist/` once froze it on every build; see docs/troubleshooting.md).
- **Config compatibility:** only add settings keys; never change the meaning or type of an
  existing one. If you must, migrate in `AppConfig` like `migrateLegacyFormat()` does.
