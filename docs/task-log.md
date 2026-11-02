# Task Log

Capture a screenshot or a note into a plain daily log file, for an agent to read later (e.g. turn results and new
tasks into task-board updates). Unlike Obsidian Capture it needs no Obsidian and always writes to one place.

- **Screenshot → Task Log** (`task_log.hotkeys.image`) and **Note → Task Log** (`task_log.hotkeys.text`): no default
  shortcut; assign them in Settings → Task Log or Settings → Shortcuts.
- Writes to `<folder>/YYYY-MM-DD.md` (created with a `# YYYY-MM-DD task log` heading), one entry per capture:
  `**HH:mm** your text` and, for a screenshot, `![](images/YYYYMMDD-HHmmss.png)` with the image in `<folder>/images/`.
- Setup: choose the folder (`task_log.folder`, `~` allowed). Screenshots need Screen Recording (shared with Obsidian
  Capture). Menu: Plugins ▸ Task Log ▸ Open Today's Task Log.
