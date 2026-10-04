# Changelog

## Unreleased

### Changed
- **The app is now just "Quick Capture"** (it works with Obsidian but doesn't depend on it). The bundle identifier is unchanged, so permissions carry over. Settings move automatically from `~/Library/Application Support/Obsidian Quick Capture` to `~/Library/Application Support/Quick Capture` on first launch, and the installer removes the old `Obsidian Quick Capture.app`.

### Added
- **Shortcuts page** in Settings: every shortcut of every plugin in one place, with duplicate detection. Recording a shortcut another action already uses asks whether to replace it, and ⌘-only combinations get a heads-up that they overlap with other apps' commands.
- **Open Settings shortcut** (default ⌃⌥,): a configurable system-wide shortcut. The menu item no longer uses a fixed ⌘, that clashed with other apps.
- **Nose Control plugin** (off by default, ⌃⌥N): move the pointer by turning your head, tracked on-device with the camera, and click with configurable keyboard shortcuts (left, right, double click, pause, sensitivity up/down, recalibrate). Live feedback during calibration, separate horizontal/vertical sensitivity, and a steadiness setting. See [docs/nose-control.md](docs/nose-control.md). **Experimental:** eye and nose tracking were both tried and found too unstable to replace a mouse, so Keyboard Mouse is the recommended way to move the pointer without one.
- **Keyboard Mouse plugin** (off by default): hold Right Option (configurable) and use WASD to move the pointer with acceleration, 1–6 to jump to one of six screen panels, Space for the left button (press twice for a double click, hold to drag) and E for the right button. See [docs/keyboard-mouse.md](docs/keyboard-mouse.md).
- Plugins can hide a shortcut while it isn't relevant (`Plugin.isAvailable`), so it isn't grabbed system-wide.
- The app declares camera access (`NSCameraUsageDescription` and the camera entitlement in `scripts/entitlements.plist`).

## 3.0.1 — 2026-09-28

### Fixed
- **“Capture not saved” when it actually was saved:** Obsidian's CLI sometimes drops a command's reply after running it. The app now retries calls with a missing reply (the bridge never saves twice), and logs lost replies to `obsidian_capture/bridge.log`. See [Troubleshooting](docs/troubleshooting.md#capture-not-saved--obsidian-cli-isnt-responding-but-the-capture-was-saved-fixed-in-301).

## 3.0.0 — 2026-09-28

### Added
- **AI Chat plugin** (⌃⌥Space): a quick, temporary chat with Claude Code or Codex. It detects installed CLIs automatically. Models: Claude Sonnet (default), Opus, Fable, Haiku; Codex GPT-6 Luna plus your account's models. It can search the web, edit files, and run sandboxed commands in a chosen working folder, with Read only / Edit / Full access permission modes. Renders Markdown, LaTeX, tables, and highlighted code offline. Web links and file links (`path:line`) are clickable, and files dropped on the window are referenced in the message.
- **Plugin architecture:** every feature is a plugin with its own on/off switch, shortcuts, menu items, Settings page, and options in `config.json`. See [the plugin guide](.claude/skills/new-plugin/SKILL.md).
- New Settings window: a sidebar with General plus one page per plugin. Shortcuts can be removed as well as changed.
- Onboarding lists each plugin with its setup steps.
- Standard Edit shortcuts (⌘C/⌘V/⌘A/⌘Z) now work in the app's text fields.
- Tests for the chat renderer and a real-CLI smoke test (`scripts/chat-smoke.sh`).

### Changed
- `config.json` groups settings under `plugins.<id>` and writes out every option. Version 2 files are migrated automatically, keeping your shortcuts and vault.
- Command-line tools are found through your login shell's `PATH` and common install locations, so the app works the same on any Mac.
- The Obsidian CLI is found wherever Obsidian is installed. Obsidian Capture starts switched on only if Obsidian is installed.
- The bundle ID can be set with `BUNDLE_ID=…` when building.

### Fixed
- **Building froze Obsidian** when the project was inside a vault: the DMG staging folder contained a symlink to `/Applications`, which Obsidian tried to index. Staging now happens in a temp folder. See [Troubleshooting](docs/troubleshooting.md#obsidian-froze-after-building-the-app-fixed-in-300).

## 2.0.0 — 2026-09-26

- Rewrote the Python version as a native Swift/AppKit menu-bar app. No Python runtime, and no Accessibility permission for shortcuts.
- Captures land at the cursor in the active note via Obsidian's CLI, with fallbacks to the end of the note, today's diary, or a new diary from your template.
- Welcome window with live setup status, a Settings window with a shortcut recorder, a Login Item, a watched `config.json`, and a recovery folder for unsaved captures.

## 1.x

- The original Python (rumps + pynput) version, kept in `legacy-python/`.
