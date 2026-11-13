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
    "task_log": {
      "enabled": false,
      "hotkeys": { "image": "", "text": "" },
      "folder": "~/Documents/tasks/logs"
    },
    "read_aloud": {
      "enabled": false,
      "hotkeys": { "read": "", "clipboard": "", "stop": "" },
      "python_path": "",
      "voice": "af_heart",
      "speed": 1,
      "memory_limit_gb": 3,
      "audio_limit_mb": 500,
      "idle_minutes": 10
    },
    "brake": {
      "enabled": false,
      "hotkeys": { "show": "" },
      "sources": [],
      "current": "",
      "text": "Stop. Breathe. Is this what you really want to be doing right now?",
      "autoplay": true
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
    "radial_wheel": {
      "enabled": false,
      "hotkeys": { "show": "<ctrl>+<alt>+w" },
      "slots": ["video_notes.record", "video_notes.meeting", "video_notes.selfie", "video_notes.record_screen",
                "obsidian_capture.image", "obsidian_capture.text", "ai_chat.toggle", "video_notes.dashboard"],
      "size": 1.0
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

- Modifiers: `<cmd>`, `<shift>`, `<alt>`, `<ctrl>`. Keys: a letter, a digit, punctuation, `<space>`, `<tab>`, `<enter>`, `<esc>`, arrow keys, or `<f1>`–`<f19>`.
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
| `radial_wheel.slots` | The wheel's slices clockwise from the top, 2–12 entries of `"<plugin id>.<action id>"`, e.g. `"video_notes.record"` (see [Radial Wheel](radial-wheel.md)) |
| `radial_wheel.size` | 0.7–1.5; wheel size multiplier (default 1.0) |
| `keyboard_mouse.activation_key` | `right_option`, `right_command` or `right_control`; the key you hold to use WASD as a mouse (see [Keyboard Mouse](keyboard-mouse.md)) |
| `video_notes.folder` | Media Capture (formerly Video Notes; the key stays `video_notes`). Parent of the `quick-capture-video`, `quick-capture-selfie` and `quick-capture-audio` folders; empty means `~/Movies` (see [Media Capture](media-capture.md)) |
| `video_notes.tags` | The tag columns of the dashboard, left to right (empty by default); manage them in the dashboard rather than by hand, since deleting there asks first |
| `video_notes.compression` | `off`, `efficient` (720p HEVC) or `smart` (720p HEVC at 15 fps, the default); screen recordings get 15 fps HEVC unless `off`. See [Video compression](video-compression.md) |
| `video_notes.microphone` | Record sound with the video |
| `video_notes.volume` | Playback volume in percent, 25–800 (default 100), on top of the Mac's volume |
| `video_notes.screen_camera_size` | Screen + camera recordings: side of the camera square in percent of the video height, 10–50 (default 25) |
| `video_notes.screen_camera_corner` | Screen + camera recordings: `bottom_left` (default), `bottom_right`, `top_left` or `top_right` |
| `video_notes.screen_system_volume`, `screen_mic_volume` | Screen + camera recordings: how loud the Mac's sound and your voice are in the saved video, in percent, 0–300 (defaults 70 and 100). Applied when the recording stops; above 100 boosts with a soft limiter |
| `video_notes.untagged_last` | Dashboard: show the Untagged column after the tags instead of first (default `false`). The tag order itself is `video_notes.tags` |
| `video_notes.selfie_prompt`, `meeting_prompt` | Ask for a tag and note after each selfie / when a meeting recording stops (default `true`) |
| `video_notes.selfie_mirror` | Save selfies mirrored, as the preview shows them (default `true`) |
| `video_notes.meeting_system_audio` | Meeting recordings also capture the Mac's sound, i.e. the other people (default `true`; needs Screen Recording) |
| `video_notes.meeting_compression` | `compact` (HE-AAC mono 32 kbps, ~16 MB/hour, default), `standard` (AAC mono 64 kbps) or `high` (AAC stereo 128 kbps) |
| `video_notes.meeting_indicator` | Small REC timer at the top right while a meeting is recorded (hidden from screen sharing) |
| `video_notes.transcription_engine` | `auto` (default: whisper.cpp → OpenAI Whisper → Apple Speech), `whisper_cpp`, `openai_whisper`, `apple` or `off` |
| `video_notes.transcription_language` | Whisper language code (`zh`, `en`, …) or `auto` (default) |
| `video_notes.transcription_prompt` | Whisper's initial prompt; the default asks for Simplified Chinese with English words kept in English |
| `video_notes.transcription_model` | A ggml `.bin` (whisper.cpp) or `.pt` (OpenAI Whisper) file, or a model name; empty finds the best downloaded one (Handy's models included) |
| <a id="tickets"></a>`tickets.folder` | Where tickets are kept as Markdown (see [Tickets](tickets.md)); empty uses the app's data folder |
| `tickets.agent` | Default agent: `claude`, `codex` or `pi` |
| `tickets.claude_model`, `codex_model`, `pi_model` | Model per agent, as that CLI takes it (empty: its default). The older `tickets.model` still applies to the default agent when its own is empty |
| `tickets.claude_effort`, `codex_effort`, `pi_effort` | Reasoning effort per agent: Claude Code `low`…`max`, Codex `minimal`…`xhigh`, Pi `off`…`xhigh`; empty: the CLI's default |
| `tickets.auto_process` | Run the agent as soon as a ticket is sent or replied to (default `true`) |
| `tickets.access` | `read_only`, `workspace` (default: edit files and run sandboxed commands in the working and extra folders) or `full` (no sandbox) |
| `tickets.working_directory`, `extra_folders` | Where the agent works (empty: `<folder>/workspace`) and other folders it may change in `workspace` access |
| `tickets.allow_network` | Let sandboxed commands reach the network (Codex; default `true`) |
| `tickets.self_update` | Let the agent change Quick Capture's own source and order a rebuild + restart, with git snapshots and automatic rollback (default `false`; see [Tickets](tickets.md#letting-the-agent-update-quick-capture-itself)) |
| `tickets.self_update_folder` | The Quick Capture source checkout; empty uses the one this app was built from |
| `tickets.self_update_confirm` | Legacy setting (default `true`); confirmation is always required, even when this field is `false` |
| `tickets.timeout_minutes` | Stop a run after this long (default `20`) |
| `tickets.notify_your_turn` | Notify when the agent has answered and a ticket waits for you (default `true`) |
| `tickets.notify_due` | Notify on the day an open ticket is due (default `true`) |
| `tickets.due_notify_hour` | Hour of that reminder when the ticket has no due time (default `7`) |
| `tickets.due_lead_hours` | Hours before the due time, when it has one (default `5`) |
| `tickets.claude_path`, `codex_path`, `pi_path` | CLI locations; empty finds them |
| `skill_manager.folders` | Folders searched for skills (see [Skill Manager](skill-manager.md)); default `~/.claude/skills`, `~/.codex/skills`, `~/.agents/skills` |
| `skill_manager.show_builtin` | Also list the skills that ship with Claude Code and Codex |
| `memory_monitor.keep` | Bundle ids that Quit All never quits (see [Memory Monitor](memory-monitor.md)); default Terminal, iTerm2, Xcode, VS Code, Claude |
| `storage_manager.project_roots` | Folders searched for `node_modules` and virtualenvs (see [Storage Manager](storage-manager.md)); default `~/Documents`, `~/Developer`, `~/Projects`, … (missing ones skipped) |
| `storage_manager.extra_paths`, `protected_paths` | Your own folders to list for cleaning / folders that are never cleaned |
| `storage_manager.min_discovered_mb` | Hide found items (app caches, environments) smaller than this (default `100`) |
| `brake.sources` | Everything Brake can show (PDF, EPUB, video, audio or image), each with its own `path` (`~` allowed), `page`, `pdf_zoom`, `start_seconds`, EPUB `bookmarks` and `shown_bookmark` (see [Brake](brake.md)) |
| `brake.current` | `id` of the source Brake shows; empty shows only `brake.text` |
| `brake.autoplay` | Whether video/audio plays at once (default `true`) |
| `brake.text` | Line shown above the file, or on its own |
| `keyboard_mouse.speed` | 0.3–3; multiplier for the top pointer speed |
| `nose_control.panel_layout` | `columns` or `rows`: how the three panels are arranged |
| `nose_control.show_legend` | Cheat sheet of Nose Control's shortcuts while tracking |
| `nose_control.show_preview`, `reuse_calibration` | Show the camera preview while tracking; skip calibration when a saved one exists |

Config files from version 2 and from the Python version are migrated automatically.
