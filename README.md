# Quick Capture for macOS

A small menu-bar app that puts useful things behind global shortcuts. Each feature is a plugin you can turn on or off.

| Plugin | Shortcut | What it does |
|---|---|---|
| **AI Chat** | ⌃⌥Space | A quick chat with **Claude Code** or **Codex** from any app. It can search the web and read and edit files. Renders Markdown and LaTeX, and every link is clickable. |
| **Obsidian Capture** | ⌘⇧I / ⌘⇧J | Screenshot or jot a note straight into the Obsidian note you're in (at the cursor) or today's diary. |

No account and no server. AI Chat uses the Claude Code or Codex CLI you already have, with your own sign-in.

## Install

Requires macOS 13+ and Xcode or the Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/lucasXiaofan/quick-capture-macos.git
```

```bash
cd quick-capture-macos && scripts/build.sh --install
```

The app opens with a **Welcome** window: switch on the plugins you want and follow their setup steps. Afterwards, the camera icon in the menu bar holds everything, including **Settings**, where you can change any shortcut.

For AI Chat, install at least one CLI and run it once to sign in:

- Claude Code: `curl -fsSL https://claude.ai/install.sh | bash`
- Codex: `npm i -g @openai/codex`

## Using it

- **AI Chat:** press ⌃⌥Space, type, and press ↩. Pick the model and working folder in the header; ⌘N starts a new chat, Esc hides it. By default it can edit files in the working folder and run sandboxed commands; switch to *Read only* or *Full access* in Settings. → [docs/ai-chat.md](docs/ai-chat.md)
- **Obsidian Capture:** press ⌘⇧I, drag a region, add a note, and press ⌘↩. It lands at your cursor in Obsidian. Add ⌥ (⌥⇧⌘I / ⌥⇧⌘J) to send to today's diary instead. → [docs/obsidian-capture.md](docs/obsidian-capture.md)

All settings are also in a JSON file that applies live when edited. → [docs/configuration.md](docs/configuration.md)

## Docs

- [AI Chat](docs/ai-chat.md): models, permissions, links, keys
- [Obsidian Capture](docs/obsidian-capture.md): setup, and where captures go
- [Configuration](docs/configuration.md): `config.json` reference
- [Troubleshooting](docs/troubleshooting.md): permissions, missing CLIs, Gatekeeper
- [Development](docs/development.md): building, signing, tests, writing a plugin
- [Changelog](CHANGELOG.md)

## Uninstall

Turn off *Open at login* in Settings, quit from the menu, and delete the app. Optionally, delete `~/Library/Application Support/Obsidian Quick Capture`. Your notes are never touched.

## License

[MIT](LICENSE)
