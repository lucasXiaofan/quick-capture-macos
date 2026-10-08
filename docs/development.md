# Development

Requires macOS 13+ and Xcode or the Command Line Tools. Node is only needed for the tests.

```bash
scripts/build.sh --install
```

This compiles the app, bundles and signs `dist/Quick Capture.app`, creates `dist/Quick Capture.dmg`, then copies the app to /Applications and launches it. Without `--install`, it only builds.

- **Signing:** the script uses a *Developer ID Application* certificate if you have one, then *Apple Development*, then ad-hoc. Ad-hoc builds lose the Screen Recording permission on every rebuild.
- **Bundle ID:** set `BUNDLE_ID=com.you.QuickCapture scripts/build.sh`. Keep it stable, because permissions are tied to it.
- **Intel + Apple Silicon:** `UNIVERSAL=1 scripts/build.sh`.

## Sharing builds

Create a *Developer ID Application* certificate (Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application), store notary credentials once, then build with notarization:

```bash
xcrun notarytool store-credentials quickcapture --apple-id YOU@example.com --team-id YOURTEAMID
```

```bash
NOTARY_PROFILE=quickcapture scripts/build.sh
```

## Tests

```bash
node tests/bridge.test.cjs
```

```bash
node tests/render.test.cjs
```

```bash
node tests/skills.test.cjs
```

```bash
scripts/chat-smoke.sh claude haiku
```

1. The Obsidian bridge: cursor-safe saves against a mocked Obsidian.
2. The chat's Markdown + LaTeX renderer.
3. A real two-turn conversation through the chat engine (file edit, shell command, follow-up), run with a bare environment like an app opened from Finder. It uses a little of your CLI quota; try `codex gpt-6-luna` too.

To work on the chat page in a browser, serve `Resources/ai_chat` (there's a config in `.claude/launch.json`) and feed it events with `qc.receive({...})` from the console. `scripts/vendor.sh` upgrades the bundled web libraries (marked, KaTeX, DOMPurify, highlight.js).

## Layout

```
Sources/QuickCapture/
  App/        app delegate, StatusMenu (menu bar menu built from the enabled plugins), AppState (config, plugin lifecycle, hotkeys, permissions), config types
  Core/       global hotkeys, process helpers (login-shell PATH discovery), toasts, JSON values
  UI/         Settings (General + one page per plugin), onboarding, shared components
  Plugins/    Plugin protocol, registry, one folder per plugin
Resources/<plugin id>/   files each plugin ships
scripts/                 build, icon, vendoring, chat smoke test
tests/                   Node tests + the chat smoke harness
legacy-python/           the original Python version, kept for reference
```

## Writing a plugin

Every feature is a plugin: a Swift class that declares actions. The core provides its on/off switch, shortcut recorders, menu items, Settings page, and typed options in `config.json`. Follow [`.claude/skills/new-plugin/SKILL.md`](../.claude/skills/new-plugin/SKILL.md); Claude Code loads it as the `new-plugin` skill, and `AGENTS.md` points Codex to it.

## Seeing the UI without Screen Recording

To check a window's layout from a script (or an agent) without granting Screen Recording to the terminal, start the
app with `QC_SNAPSHOT_DIR` set and post a distributed notification; every open (or minimized) window of the app is
saved as `<window title>.png` in that folder. It renders the app's own views, so no permission is needed, and it does
nothing unless the variable is set.

```bash
osascript -e 'quit app "Quick Capture"'
open -a "/Applications/Quick Capture.app" --env QC_SNAPSHOT_DIR="$(mktemp -d)"
echo 'import Foundation
DistributedNotificationCenter.default().postNotificationName(.init("QuickCaptureSnapshot"), object: nil, userInfo: nil, deliverImmediately: true)' | swift -
```
