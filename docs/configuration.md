# Configuration

Everything in Settings is stored in `~/Library/Application Support/Obsidian Quick Capture/config.json`. The app watches the file, so edits apply within a second. A toast confirms each change, or says why an invalid edit was ignored.

```json
{
  "plugins": {
    "ai_chat": {
      "enabled": true,
      "hotkeys": { "toggle": "<ctrl>+<alt>+<space>", "new_chat": "" },
      "default_model": "claude:sonnet",
      "working_directory": "~/Projects/my-app",
      "permissions": "edit",
      "claude_path": "",
      "codex_path": ""
    },
    "obsidian_capture": {
      "enabled": true,
      "hotkeys": {
        "image": "<cmd>+<shift>+i",
        "text": "<cmd>+<shift>+j",
        "diary_image": "<cmd>+<shift>+<alt>+i",
        "diary_text": "<cmd>+<shift>+<alt>+j"
      },
      "vault": "~/Documents/MyVault",
      "obsidian": "/Applications/Obsidian.app/Contents/MacOS/obsidian",
      "diary_folder": "Daily",
      "diary_format": "YYYY-MM-DD",
      "template": "",
      "destination_mode": "current"
    }
  }
}
```

## Shortcuts

- Modifiers: `<cmd>`, `<shift>`, `<alt>`, `<ctrl>`. Keys: a letter, a digit, punctuation, `<space>`, `<tab>`, `<enter>`, arrow keys, or `<f1>`–`<f19>`.
- Every shortcut except a function key needs at least one of ⌘, ⌥, or ⌃. `""` means no shortcut.
- A shortcut used twice, even across plugins, is rejected. Shortcuts are system-wide and need no Accessibility permission.

## Options

| Key | Values |
|---|---|
| `ai_chat.default_model` | `claude:<model>` or `codex:<model>`; any model id the CLI accepts |
| `ai_chat.working_directory` | Folder the agent works in; empty means your home folder |
| `ai_chat.permissions` | `read_only`, `edit`, or `full` (see [AI Chat](ai-chat.md#permissions)) |
| `ai_chat.claude_path`, `codex_path` | CLI location; empty means find it automatically |
| `obsidian_capture.destination_mode` | `current` (at cursor) or `diary` (the two main shortcuts also go to the diary) |
| `obsidian_capture.diary_folder`, `diary_format`, `template` | Fallback diary: folder, Moment.js-style file name, template note |

Config files from version 2 and from the Python version are migrated automatically.
