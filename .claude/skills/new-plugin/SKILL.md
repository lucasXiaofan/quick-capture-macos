---
name: new-plugin
description: Add a new shortcut-driven feature (plugin) to the Quick Capture macOS menu-bar app. Use when the user wants a new global shortcut, a new menu-bar feature, or a new tool/window in this project — e.g. "add a plugin that…", "add a shortcut to…", "new feature for the app".
---

# Creating a Quick Capture plugin

Every feature in this app is a plugin: a Swift class that declares **actions** (things a global
shortcut can trigger). The core app gives every plugin, for free:

- an on/off switch, stored in `config.json` and shown in Settings and onboarding;
- a shortcut recorder per action, conflict checking across all plugins, and system-wide hotkeys;
- menu-bar items for its actions;
- typed settings persisted in `config.json` (hand-edits apply live);
- a Settings page (`PluginPage`) that hosts the plugin's own setup steps and settings sections.

Read these first — they are short and define the contract:

- `Sources/QuickCapture/Plugins/Plugin.swift` — the `Plugin` protocol (every hook has a default).
- `Sources/QuickCapture/Plugins/PluginRegistry.swift` — the list of shipped plugins.
- `Sources/QuickCapture/App/Config.swift` — `AppConfig`, `PluginSettings`, `Paths`.
- One existing plugin as a model: `Plugins/AIChat/AIChatPlugin.swift` (window + external CLIs) or
  `Plugins/ObsidianCapture/ObsidianCapturePlugin.swift` (permissions, menu items, setup steps).

## Steps

1. **Pick an id** — `snake_case`, e.g. `clipboard_history`. It is the key under `plugins` in
   config.json and the folder name under `Resources/`. Never rename it after shipping (users'
   settings would be orphaned).

2. **Create `Sources/QuickCapture/Plugins/<Name>/<Name>Plugin.swift`** from the template below.
   SwiftPM compiles every file under `Sources/QuickCapture`, so no project file needs editing.
   Put extra types (windows, views, helpers) in the same folder.

3. **Register it** — add `<Name>Plugin()` to `PluginRegistry.makeAll()`. Order there is the order
   in the menu and in Settings.

4. **Resources** (HTML, JS, images, scripts) go in `Resources/<id>/`; `scripts/build.sh` copies the
   whole `Resources/` folder into the app. Load them with `Paths.resource("file.ext", plugin: id)`.
   Files the plugin writes at runtime go in `Paths.data(for: id)` (create the folder first).

5. **Build and check**
   ```bash
   swift build
   node tests/bridge.test.cjs && node tests/render.test.cjs
   scripts/build.sh --install
   ```
   Then confirm: `~/Library/Application Support/Quick Capture/config.json` gained a
   `plugins.<id>` entry with `enabled`, `hotkeys` and your settings; the plugin appears in
   Settings (sidebar) with working toggle and shortcut recorders; the shortcut fires from any app.
   If the plugin has pure logic (parsers, formatters), add a test under `tests/` or a small
   `swiftc` harness like `tests/chat_smoke` (see docs/development.md).

6. **Document it** — add a row to the plugin table in `README.md`, a `docs/<plugin>.md` page
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

    func defaultSettings() -> [String: JSONValue] { encodeDefaults(ExampleSettings.self) }

    func validate(_ config: AppConfig) throws {
        let s = try config.settings(ExampleSettings.self, for: id)
        if s.greeting.isEmpty { throw AppError("example.greeting can't be empty.") }
    }

    // Optional hooks (defaults do nothing): activate(), deactivate(), configDidChange(),
    // menuItems(), setupView(), isReady, setupIssues.

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
- **Shortcuts:** `defaultShortcut` needs ⌘, ⌥ or ⌃ (function keys excepted) and must not clash with
  shipped defaults — currently ⌘⇧I, ⌘⇧J, ⌥⇧⌘I, ⌥⇧⌘J (Obsidian Capture), ⌃⌥Space (AI Chat), ⌃⌥, (Open Settings), and Nose Control's (see docs/nose-control.md). Settings → Shortcuts shows them all.
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
