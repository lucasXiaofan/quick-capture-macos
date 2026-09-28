# AI Chat

A quick, temporary chat with **Claude Code** or **Codex**, opened from any app with **⌃⌥Space**. It runs the CLI you already have installed, with your own sign-in, so it can search the web, read and edit files, and run commands the same way those tools do.

## Using it

| Key | Action |
|---|---|
| ⌃⌥Space | Show / hide the chat (from any app) |
| ↩ / ⇧↩ | Send / new line (input methods like Chinese or Japanese work: ↩ confirms the composition) |
| ⌘. | Stop the reply |
| ⌘N | New chat |
| Esc | Hide |

The conversation stays until you start a new one. Hiding the window keeps it. The app saves nothing; each CLI keeps its usual session history.

- **Models:** the picker lists what's installed. Claude Code offers Sonnet (default), Opus, Fable, and Haiku. Codex offers GPT-6 Luna plus the models your account lists. Switching between Claude and Codex starts a new conversation.
- **Working folder:** shown in the header; click it to change. It defaults to your home folder.
- **Links:** web links open in your browser. File links (relative to the working folder; `file.swift:42` is fine) open in their default app, and ⌥-click reveals them in Finder.
- **Files:** drop files onto the window to reference them in your message.
- **Rendering:** Markdown, LaTeX (`$…$`, `$$…$$`, `\(…\)`, `\[…\]`), tables, and highlighted code. It works offline, because the libraries are bundled.

## Permissions

Settings → AI Chat → Permissions:

| Mode | What the agent may do |
|---|---|
| Read only | Read files and search the web |
| **Edit** (default) | Also edit files, and run commands inside the CLI's sandbox |
| Full access | No sandbox or approval prompts. Use only in folders you trust. |

## Finding the CLIs

Apps opened from Finder don't see your shell's `PATH`, so the app asks your login shell for it and also checks the common install locations (npm/nvm, Homebrew, bun, volta, `~/.local/bin`, and the Codex app bundle). If detection still fails, set the path in **Settings → AI Chat → Advanced**.

Install the CLIs from their official instructions:

- Claude Code: `curl -fsSL https://claude.ai/install.sh | bash`, then run `claude` once to sign in.
- Codex: `npm i -g @openai/codex`, then run `codex` once to sign in.

## How it works

Each message runs the CLI once in headless mode (`claude -p --output-format stream-json`, `codex exec --json`), and later messages resume the same CLI session. The window is a local web page (`Resources/ai_chat/`) that renders the streamed events. `scripts/chat-smoke.sh` tests a real round trip.
