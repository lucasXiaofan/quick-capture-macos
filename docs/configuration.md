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
        "panel_1": "1",
        "panel_2": "2",
        "panel_3": "3",
        "whole_screen": "",
        "pause": "<alt>+<space>",
        "sens_up": "<alt>+]",
        "sens_down": "<alt>+[",
        "recalibrate": "<ctrl>+<alt>+c"
      },
      "sensitivity_x": 1.0,
      "sensitivity_y": 1.0,
      "steadiness": 0.6,
      "show_preview": true,
      "reuse_calibration": true,
      "panel_layout": "columns",
      "show_legend": true
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
- Every shortcut except a function key needs at least one of ⌘, ⌥, or ⌃ — except actions that are only active temporarily (Nose Control's clicks and panel keys), which accept plain keys. `""` means no shortcut.
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
| `video_notes.folder` | Parent of the `quick-capture-video` folder; empty means `~/Movies` (see [Video Notes](video-notes.md)) |
| `video_notes.tags` | The tag columns of the dashboard, left to right (empty by default); manage them in the dashboard rather than by hand, since deleting there asks first |
| `video_notes.compression` | `off`, `efficient` (720p HEVC) or `smart` (720p HEVC + blurred background); screen recordings get 15 fps HEVC unless `off`. See [Video compression](video-compression.md) |
| `video_notes.microphone` | Record sound with the video |
| `video_notes.volume` | Playback volume in percent, 25–800 (default 100), on top of the Mac's volume |
| `video_notes.screen_camera_size` | Screen + camera recordings: side of the camera square in percent of the video height, 10–50 (default 25) |
| `video_notes.screen_camera_corner` | Screen + camera recordings: `bottom_left` (default), `bottom_right`, `top_left` or `top_right` |
| `video_notes.selfie_mirror` | Save selfies mirrored, as the preview shows them (default `true`) |
| `video_notes.meeting_system_audio` | Meeting recordings also capture the Mac's sound, i.e. the other people (default `true`; needs Screen Recording) |
| `video_notes.meeting_compression` | `compact` (HE-AAC mono 32 kbps, ~16 MB/hour, default), `standard` (AAC mono 64 kbps) or `high` (AAC stereo 128 kbps) |
| `video_notes.meeting_indicator` | Small REC timer at the top right while a meeting is recorded (hidden from screen sharing) |
| `video_notes.transcription_engine` | `auto` (default: whisper.cpp → OpenAI Whisper → Apple Speech), `whisper_cpp`, `openai_whisper`, `apple` or `off` |
| `video_notes.transcription_language` | Whisper language code (`zh`, `en`, …) or `auto` (default) |
| `video_notes.transcription_prompt` | Whisper's initial prompt; the default asks for Simplified Chinese with English words kept in English |
| `video_notes.transcription_model` | A ggml `.bin` (whisper.cpp) or `.pt` (OpenAI Whisper) file, or a model name; empty finds the best downloaded one (Handy's models included) |
| `skill_manager.folders` | Folders searched for skills (see [Skill Manager](skill-manager.md)); default `~/.claude/skills`, `~/.codex/skills`, `~/.agents/skills` |
| `skill_manager.show_builtin` | Also list the skills that ship with Claude Code and Codex |
| `keyboard_mouse.speed` | 0.3–3; multiplier for the top pointer speed |
| `nose_control.panel_layout` | `columns` or `rows`: how the three panels are arranged |
| `nose_control.show_legend` | Cheat sheet of Nose Control's shortcuts while tracking |
| `nose_control.show_preview`, `reuse_calibration` | Show the camera preview while tracking; skip calibration when a saved one exists |

Config files from version 2 and from the Python version are migrated automatically.
