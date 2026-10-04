# Obsidian Capture

Screenshot or jot a note into Obsidian from any app.

| Default | Action |
|---|---|
| ⌘⇧I | Screenshot → current note (at cursor) |
| ⌘⇧J | Note → current note (at cursor) |
| ⌥⇧⌘I | Screenshot → today's diary |
| ⌥⇧⌘J | Note → today's diary |

## Setup

- **Vault:** choose your vault folder. Your Daily Notes folder, format, and template are imported automatically.
- **Screen Recording:** needed for screenshots. Click *Grant Access…*, approve it, then *Relaunch*.
- **Obsidian CLI** (recommended): turn on Obsidian's *Settings → General → Command line interface* so captures land at your cursor.

## Capturing

For a screenshot, select a region (**Space** picks a window, **Esc** cancels). A panel shows the preview and a note field: **⌘↩** saves, **Esc** cancels. A picker in the panel switches between the note and today's diary for this one capture.

## Where captures go

The first of these that applies:

1. **At the cursor in the active note.** With a selection, it goes at the start of the selection; nothing is replaced.
2. **At the end of that note**, if it's in reading view or was edited while the panel was open.
3. **At the bottom of today's diary**, if no Markdown note is active.
4. **In a new diary** created from your template (`{{date}}`, `{{date:FORMAT}}`, `{{time}}`, `{{title}}`).

If Obsidian is closed or its CLI doesn't respond, the capture is appended straight to today's diary file.

Screenshots are saved as `capture-YYYYMMDD-HHmmss.png` in Obsidian's *Default location for new attachments* and embedded as `![[…]]`. Until a save is confirmed, a copy is kept in `~/Library/Application Support/Quick Capture/recovery`, and the menu shows **Unsaved Captures** if any are left.
