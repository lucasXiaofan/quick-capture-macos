# Quick Capture for macOS

A small menu-bar app that puts useful things behind global shortcuts. Each feature is a plugin you can turn on or off.

| Plugin | Shortcut | What it does |
|---|---|---|
| **Radial Wheel** | ⌃⌥W | One shortcut for everything: a game-style wheel of your favourite actions pops up at the pointer — hold, point, let go. Pick the slices in Settings. Off by default. |
| **AI Chat** | ⌃⌥Space | A quick chat with **Claude Code** or **Codex** from any app. It can search the web and read and edit files. Renders Markdown and LaTeX, and every link is clickable. |
| **Obsidian Capture** | ⌘⇧I / ⌘⇧J | Screenshot or jot a note straight into the Obsidian note you're in (at the cursor) or today's diary. |
| **Media Capture** | ⌃⌥R | Record a quick video with the Mac camera (or the screen with your camera in a corner, ⌃⌥⇧R), tag it, and replay favourites with ⌃⌥V then 1–5. Also a daily selfie (⌃⌥F) and meeting recordings (⌃⌥A: microphone + the Mac's sound, transcribed on this Mac when you stop). One dashboard with Videos, Selfies and Recordings (audio next to its transcript), sorted by shared tags. Off by default. |
| **Tickets** | ⌃⌥E, ⌃⌥⇧E | Capture a todo, question, idea, habit check-in or bug as a ticket; Claude Code, Codex or Pi classifies it and takes the first turn, you reply like email. Inbox, projects, habit heatmaps, Gantt plan; tickets are Markdown files. Off by default. |
| **Skill Manager** | ⌃⌥K | A dashboard of your Claude Code and Codex skills: read every file rendered, follow links between them, edit, and create new skills. Off by default. |
| **Memory Monitor** | none | Live RAM window for local-model work: used / cached files (where mmap'd models sit) over time, a baseline to see what a model load cost, and one-click quitting of apps you can spare. Off by default. |
| **Storage Manager** | none | Disk dashboard: free space, caches, old environments (`node_modules`, virtualenvs, conda), AI models, backups, sorted by size with age; one click to clean (caches emptied, the rest to the Trash), a folder explorer, and protected folders. Off by default. |
| **Keyboard Mouse** | hold Right ⌥ | Hold a key, then WASD moves the pointer, 1–6 jump to a screen panel, Space/E click. Off by default. |
| **Nose Control** | ⌃⌥N | Experimental: move the pointer by turning your head (camera, on-device). Found too unstable to recommend. Off by default. |

No account and no server. AI Chat uses the Claude Code or Codex CLI you already have, with your own sign-in.

## Install

The app is built from source on the Mac that will run it (any Mac with macOS 13+: MacBook, Mac mini, iMac, Studio). There is no download; the build takes about a minute.

1. Install Apple's build tools, if the Mac doesn't have Xcode yet:

   ```bash
   xcode-select --install
   ```

2. Get the code:

   ```bash
   git clone https://github.com/lucasXiaofan/quick-capture-macos.git
   ```

3. Build, install into `/Applications` and launch:

   ```bash
   cd quick-capture-macos && scripts/build.sh --install
   ```

4. The app opens with a **Welcome** window: switch on the plugins you want and follow their setup steps (macOS asks for Screen Recording, Camera or Microphone only when a plugin needs it). Afterwards, the camera icon in the menu bar shows the most-used action of each plugin you switched on (seven at most), **Plugins ▸** has everything else per plugin, and **Settings** is where you change any shortcut and turn on *Open at login*.

For AI Chat and Tickets, install at least one CLI and run it once to sign in:

- Claude Code: `curl -fsSL https://claude.ai/install.sh | bash`
- Codex: `npm i -g @openai/codex`

**Updating:** in the cloned folder, `git pull && scripts/build.sh --install`.

**A second Mac:** each Mac has its own settings and its own permissions. To carry your settings over, copy `~/Library/Application Support/Quick Capture/config.json` to the same place on the new Mac before the first launch, then check the folders it names (Obsidian vault, Task Log folder, Brake files) exist there too.

**Permissions after a rebuild:** without a signing certificate the build is signed ad hoc, and macOS may ask for Screen Recording again after each rebuild. A free *Apple Development* certificate (Xcode → Settings → Accounts) avoids that; the script picks it up by itself. → [docs/development.md](docs/development.md)

## What works on which Mac

Everything works on a MacBook (Air or Pro) with Apple Silicon, because it has a camera and a microphone built in. A Mac mini, Mac Studio or Mac Pro has neither, so the camera features need a webcam plugged in (or an iPhone as Continuity Camera); the rest works as is. Leave the plugins you can't use switched off.

| Plugin | MacBook | Mac mini / Studio (no camera, no microphone) |
|---|---|---|
| Radial Wheel | ✅ | ✅ |
| AI Chat | ✅ | ✅ |
| Obsidian Capture | ✅ | ✅ |
| Task Log | ✅ | ✅ |
| Tickets | ✅ | ✅ |
| Skill Manager | ✅ | ✅ |
| Memory Monitor | ✅ | ✅ |
| Storage Manager | ✅ | ✅ |
| Brake | ✅ | ✅ |
| Keyboard Mouse | ✅ | ✅ (the keyboard needs the activation key, Right ⌥ by default; choose another in Settings) |
| Read Aloud | ✅ Apple Silicon only | ✅ Apple Silicon only (not on an Intel Mac: it runs on MLX) |
| Media Capture: meeting recording (⌃⌥A) | ✅ microphone + the Mac's sound | ⚠️ the Mac's sound only, until a microphone is connected (USB, headset, AirPods, a webcam's) |
| Media Capture: dashboard, replay, transcripts | ✅ | ✅ |
| Media Capture: camera video (⌃⌥R), screen + camera (⌃⌥⇧R), selfie (⌃⌥F) | ✅ | ❌ “No camera found”, until a webcam or Continuity Camera is connected |
| Nose Control | ✅ | ❌ needs a camera, same as above |

Screenshots (Obsidian Capture, Task Log, Tickets, Read Aloud) need the Screen Recording permission on every Mac, and work on all of them. Screen recording exists only as *screen + camera*, so it needs a camera too.

## Using it

- **Radial Wheel:** turn it on in Settings, hold ⌃⌥W, point toward a slice and let go (or tap ⌃⌥W, then click a slice or press its number). Choose the 2–12 slices in Settings → Radial Wheel. → [docs/radial-wheel.md](docs/radial-wheel.md)
- **AI Chat:** press ⌃⌥Space, type, and press ↩. Pick the model and working folder in the header; ⌘N starts a new chat, Esc hides it. By default it can edit files in the working folder and run sandboxed commands; switch to *Read only* or *Full access* in Settings. → [docs/ai-chat.md](docs/ai-chat.md)
- **Obsidian Capture:** press ⌘⇧I, drag a region, add a note, and press ⌘↩. It lands at your cursor in Obsidian. Add ⌥ (⌥⇧⌘I / ⌥⇧⌘J) to send to today's diary instead. → [docs/obsidian-capture.md](docs/obsidian-capture.md)
- **Task Log:** turn it on in Settings, choose a folder and assign the two shortcuts; a screenshot or note goes to the end of today's `YYYY-MM-DD.md` there. → [docs/task-log.md](docs/task-log.md)
- **Read Aloud:** turn it on in Settings (needs a Python with `mlx-audio`), assign a shortcut, drag a region of text and hear it in a local Kokoro voice; the clipboard works too. → [docs/read-aloud.md](docs/read-aloud.md)
- **Brake:** turn it on in Settings, add reminders and pick the one to show (a PDF or EPUB book at a bookmark, a video or audio clip from a second, an image, or just a line) and give it a shortcut or a wheel slice; it opens right there, every time. → [docs/brake.md](docs/brake.md)
- **Keyboard Mouse:** turn it on in Settings, then hold Right ⌥ and press W/A/S/D to move, 1–6 to jump to a screen panel, Space to click (twice = double click), E to right-click. → [docs/keyboard-mouse.md](docs/keyboard-mouse.md)
- **Nose Control (experimental, not recommended):** turn it on in Settings, press ⌃⌥N, calibrate (centre, then your comfortable left/right/up/down limits, confirming each with ⌥↩), then move the pointer with your head. ⌥↩ left click, ⌥⇧↩ right click, ⌃⌥↩ double click, ⌥Space pause. All shortcuts are configurable. → [docs/nose-control.md](docs/nose-control.md)

Every shortcut is listed in **Settings → Shortcuts**, where you can change them and see conflicts. ⌃⌥, opens Settings from anywhere.

All settings are also in a JSON file that applies live when edited. → [docs/configuration.md](docs/configuration.md)

## Docs

- [Radial Wheel](docs/radial-wheel.md): slices, holding vs. tapping, keys
- [AI Chat](docs/ai-chat.md): models, permissions, links, keys
- [Obsidian Capture](docs/obsidian-capture.md): setup, and where captures go
- [Task Log](docs/task-log.md): daily log file for an agent to read
- [Read Aloud](docs/read-aloud.md): screenshot → speech on this Mac, memory and storage limits
- [Brake](docs/brake.md): one preset reminder — PDF or EPUB book (Books-style reader, highlights), video, audio, image or a line
- [Keyboard Mouse](docs/keyboard-mouse.md): activation key, panels, clicks
- [Nose Control](docs/nose-control.md): calibration, sensitivity, steadiness, shortcuts
- [Tickets](docs/tickets.md): kinds, views, the agent and what it may do, file format
- [Skill Manager](docs/skill-manager.md): where it looks, editing, new skills
- [Memory Monitor](docs/memory-monitor.md): reading the bar, baseline, quitting apps
- [Storage Manager](docs/storage-manager.md): what it finds, safety rules, options
- [Configuration](docs/configuration.md): `config.json` reference
- [Troubleshooting](docs/troubleshooting.md): permissions, missing CLIs, Gatekeeper
- [Development](docs/development.md): building, signing, tests, writing a plugin
- [Changelog](CHANGELOG.md)

## Uninstall

Turn off *Open at login* in Settings, quit from the menu, and delete the app. Optionally, delete `~/Library/Application Support/Quick Capture`. Your notes are never touched.

## License

[MIT](LICENSE)
