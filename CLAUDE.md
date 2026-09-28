# Quick Capture

Native macOS menu-bar app (Swift/AppKit + SwiftUI, SwiftPM, macOS 13+). Every feature is a
**plugin** triggered by global shortcuts; the core owns config, hotkeys, menu and Settings.

- `Sources/QuickCapture/App/` — app delegate + menu (`main.swift`), `AppState` (config load/watch/validate,
  plugin lifecycle, hotkeys, permissions), `Config.swift` (`AppConfig`, `PluginSettings`, `Paths`).
- `Sources/QuickCapture/Core/` — hotkeys (Carbon), `Shell`/`StreamingProcess`/`LoginEnvironment`, `Toast`, `JSONValue`.
- `Sources/QuickCapture/UI/` — Settings (sidebar: General + one page per plugin), onboarding, shared components.
- `Sources/QuickCapture/Plugins/` — `Plugin.swift` (protocol), `PluginRegistry.swift`, one folder per plugin.
- `Resources/<plugin id>/` — files a plugin ships (copied into the app by `scripts/build.sh`).

To add a feature, follow `.claude/skills/new-plugin/SKILL.md`.

Build and test:

```bash
swift build
node tests/bridge.test.cjs && node tests/render.test.cjs
scripts/chat-smoke.sh claude haiku      # real CLI round trip (uses quota)
scripts/build.sh --install              # bundle, sign, install to /Applications, relaunch
```

Keep the app shareable: no user-specific paths or tools assumed; find apps/CLIs at runtime; vendor web libraries.

**This repo may live inside an Obsidian vault** (the author's does). Never create symlinks or large temporary file trees inside the
project (use `mktemp -d`): Obsidian follows symlinks, and a link to `/Applications` in `dist/` once froze it
on every build. See docs/troubleshooting.md.
