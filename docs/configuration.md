# Configuration

Everything in Settings is stored in `~/Library/Application Support/Quick Capture/config.json`. The app watches the file, so edits apply within a second. A toast confirms each change, or says why an invalid edit was ignored.

```json
{
  "plugins": {
    "app": {
      "hotkeys": { "open_settings": "<ctrl>+<alt>+," }
    },
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
    },
    "nose_control": {
      "enabled": false,
      "hotkeys": {
        "toggle": "<ctrl>+<alt>+n",
        "left_click": "<alt>+<enter>",
        "right_click": "<alt>+<shift>+<enter>",
        "double_click": "<ctrl>+<alt>+<enter>",
        "pause": "<alt>+<space>",
        "sens_up": "<alt>+]",
        "sens_down": "<alt>+[",
        "recalibrate": "<ctrl>+<alt>+c"
      },
      "sensitivity_x": 1.0,
      "sensitivity_y": 1.0,
      "steadiness": 0.6,
      "show_preview": true,
      "reuse_calibration": true
    },
    "keyboard_mouse": {
      "enabled": false,
      "hotkeys": { "pause": "" },
      "activation_key": "right_option",
      "speed": 1.0
    }
  }
}
```

## Shortcuts

- Modifiers: `<cmd>`, `<shift>`, `<alt>`, `<ctrl>`. Keys: a letter, a digit, punctuation, `<space>`, `<tab>`, `<enter>`, arrow keys, or `<f1>`–`<f19>`.
- Every shortcut except a function key needs at least one of ⌘, ⌥, or ⌃. `""` means no shortcut.
- Settings → **Shortcuts** lists every shortcut of every plugin in one place and warns about conflicts; recording a shortcut another action uses asks before replacing it. `plugins.app` holds the app's own shortcuts (Open Settings).
- A shortcut used twice, even across plugins, is rejected. Shortcuts are system-wide and need no Accessibility permission. (Nose Control's click shortcuts are only grabbed while nose control is running.)

## Options

| Key | Values |
|---|---|
| `ai_chat.default_model` | `claude:<model>` or `codex:<model>`; any model id the CLI accepts |
| `ai_chat.working_directory` | Folder the agent works in; empty means your home folder |
| `ai_chat.permissions` | `read_only`, `edit`, or `full` (see [AI Chat](ai-chat.md#permissions)) |
| `ai_chat.claude_path`, `codex_path` | CLI location; empty means find it automatically |
| `obsidian_capture.destination_mode` | `current` (at cursor) or `diary` (the two main shortcuts also go to the diary) |
| `obsidian_capture.diary_folder`, `diary_format`, `template` | Fallback diary: folder, Moment.js-style file name, template note |
| `nose_control.sensitivity_x`, `sensitivity_y` | 0.3–6; pointer travel per head movement (see [Nose Control](nose-control.md)) |
| `nose_control.steadiness` | 0–1; higher removes shake but reacts slower |
| `keyboard_mouse.activation_key` | `right_option`, `right_command` or `right_control`; the key you hold to use WASD as a mouse (see [Keyboard Mouse](keyboard-mouse.md)) |
| `keyboard_mouse.speed` | 0.3–3; multiplier for the top pointer speed |
| `nose_control.show_preview`, `reuse_calibration` | Show the camera preview while tracking; skip calibration when a saved one exists |

Config files from version 2 and from the Python version are migrated automatically.
