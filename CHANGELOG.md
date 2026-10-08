# Changelog

## Unreleased

### Changed
- **The app is now just "Quick Capture"** (it works with Obsidian but doesn't depend on it). The bundle identifier is unchanged, so permissions carry over. Settings move automatically from `~/Library/Application Support/Obsidian Quick Capture` to `~/Library/Application Support/Quick Capture` on first launch, and the installer removes the old `Obsidian Quick Capture.app`.

### Added
- **Rank tags in the Media Capture dashboard:** **Arrange Tags** (header button) lists the tags in dashboard order with their counts; select one or several and move them Top / Up / Down / Bottom (⌘↑ / ⌘↓, ⌥⌘↑ / ⌥⌘↓), or **Sort by Most Used**. Each column's ⋯ menu has Move to Front / Left / Right / End, and Untagged can be the last column (`video_notes.untagged_last`). Replaces dragging column headers, which didn't work inside the horizontally scrolling board.
- **Video Notes is now Media Capture**, with a dashboard of three tabs: **Videos**, **Selfies** and **Recordings**, sharing one set of tags. A recording's card holds the audio and its transcript together (Play, Transcript, the first lines or the lines matching the search; search covers transcripts). Selfies open in Preview. Selfies and meeting recordings ask for an optional tag and note like videos do (`video_notes.selfie_prompt`, `video_notes.meeting_prompt`). The config key stays `video_notes`, so settings and folders carry over. See [docs/media-capture.md](docs/media-capture.md#dashboard).
- **Media Capture selfie** (⌃⌥F): the first press shows the camera, the second (or Space) takes the photo. Saved as JPEG in `quick-capture-selfie`, mirrored like the preview (`video_notes.selfie_mirror`). See [docs/media-capture.md](docs/media-capture.md#selfie).
- **Media Capture meeting audio** (⌃⌥A starts, press again to pause / resume, ⌃⌥⇧A stops): records the microphone and the Mac's own sound (ScreenCaptureKit; needs Screen Recording) for as long as a meeting lasts. Written to a fragmented file while recording, so a crash or quit keeps everything up to the last ~10 s (finished on next launch). On stop it's mixed into one `.m4a` (default HE-AAC mono 32 kbps, ~16 MB/hour; `video_notes.meeting_compression`), then transcribed on this Mac into a `.txt` next to it — only after the recording, never live. Engines: whisper.cpp (uses Handy's downloaded models), OpenAI Whisper, or Apple's `SpeechTranscriber` on macOS 26; Whisper handles Chinese and English mixed. A small REC timer stays out of screen sharing. See [docs/media-capture.md](docs/media-capture.md#meeting-audio).
- **Smaller Media Capture, measured:** camera videos compress to 720p HEVC (~4 MB/min instead of ~17), screen + camera videos to 15 fps HEVC (~4–6.5 MB/min instead of ~22; text stays sharp), and audio to AAC 64 kbit/s mono / 96 kbit/s stereo. Screen recordings are now compressed too. **⋯ → Compress All Videos** and **Compress Again** bring older videos to the new targets (`compression_version` in `index.json`). Measurements and the options compared: [docs/video-compression.md](docs/video-compression.md).
- **Discard a bad take in Media Capture:** ⌃⌥X while recording pauses, asks, then throws the recording away (or resumes). The tag prompt after a recording has **Discard…** (⌘⌫) too. Discarded videos go to the Trash.
- **Media Capture screen + camera recording** (⌃⌥⇧R; press again to pause, ⌃⌥S stops): records the main display at 720p (H.264) with your camera as a rounded square in a corner, the Mac's sound and the microphone, mixed into one audio track. The square's size (10–50% of the height) and corner are set in Settings (`video_notes.screen_camera_size`, `video_notes.screen_camera_corner`). The preview sits where the square will be; the app's own windows aren't recorded. Same tag-and-note prompt afterwards; compressed in the background to 15 fps HEVC. Needs Screen Recording permission. Built on ScreenCaptureKit; see [docs/media-capture.md](docs/media-capture.md#screen--camera).
- **Media Capture volume boost:** play every video up to 800% louder without changing the Mac's volume (Settings or the dashboard header; `video_notes.volume`). Uses an audio tap with a soft limiter; files are untouched.
- **Redesigned Video dashboard:** thumbnails with length, a Quick Play strip (drop a card on a slot to assign it), search, Record/Stop and volume in the header, empty state. Settings → Media Capture now opens with the dashboard.
- **Menu bar menu is now a short launcher built from the plugins:** the top shows each enabled plugin's most important action (`Plugin.primaryActions()`, seven rows at most), alerts such as Unsaved Captures (`menuAlerts()`), and **Plugins ▸** holds one submenu per plugin with its other actions, extra items and a direct link to its Settings page. Switching a plugin off removes it from the menu. Actions can be hidden from the menu (`showsInMenu`), e.g. Media Capture' per-slot play, or Pause/Stop while not recording. Plugins can also put sections at the top of their Settings page (`overviewView`).
- **Skill Manager plugin** (off by default, ⌃⌥K): a dashboard of every Claude Code / Codex skill (`~/.claude/skills`, `~/.codex/skills`, `~/.agents/skills`, plus folders you add). Overview cards, search, every file of a skill rendered as Markdown with syntax highlighting, file paths in the text open the file, plain-text editing with ⌘S, and **New skill** from a template. Built-in skills hidden by default. The UI is a web page (`Resources/skill_manager/`) sharing AI Chat's renderer. See [docs/skill-manager.md](docs/skill-manager.md).
- **Media Capture plugin** (off by default): ⌃⌥R records the camera (press again to pause), ⌃⌥P pauses, ⌃⌥S stops, with a small live preview at the bottom of the screen. After stopping, pick an existing tag or type a new one and add a note. A Kanban dashboard shows one column per tag, newest first; drag cards between columns to retag, double-click to play in the default player, right-click for quick-play slots, Trash and more. ⌃⌥V then 1–5 plays the video in that slot. Shows each column's and the library's disk usage. Tags: new tags appear next to Untagged, **Arrange Tags** ranks them, adds and deletes several at once (always with confirmation; videos move to Untagged), and there are no built-in tags. Quick play opens a small player that starts automatically after half a second, with optional direct shortcuts per slot. Videos are compressed in the background (Smart: sharp person, blurred background, HEVC; audio untouched), see [docs/video-compression.md](docs/video-compression.md). See [docs/media-capture.md](docs/media-capture.md). Declares microphone access (`NSMicrophoneUsageDescription`, audio-input entitlement).
- **Nose Control panels:** the screen is split into three big panels; pressing **1**, **2** or **3** jumps the pointer to the middle of that panel and the nose then moves it inside the panel. Columns or rows; a **Whole Screen** shortcut leaves the panel. Plain keys are released while paused. Dividers and numbers on screen show where each key jumps, and panels follow the display the pointer is on (not always the primary one).
- **Plain-key shortcuts** for actions that are only active temporarily (`PluginAction.allowsBareKey`). Nose Control's click, panel, pause and sensitivity shortcuts can now be any key. Clearer click labels and an on-screen cheat sheet of the shortcuts while tracking.
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
