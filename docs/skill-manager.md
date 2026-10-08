# Skill Manager

A dashboard of every agent skill on your Mac (Claude Code, Codex and any agent that uses the
`SKILL.md` folder layout). Read every file of a skill, follow its links, edit, and create new
skills, all without leaving the window.

## Open it

⌃⌥K, or the menu bar → **Open Skill Manager**. The shortcut can be changed in Settings. The
plugin is off by default: switch it on in Settings → Skill Manager.

## The window

| Area | What it does |
|---|---|
| Sidebar | Every skill, grouped by the folder it was found in. Search (⌘F) matches names, descriptions and file names; ↑/↓ and Return move through the results. **Skills** (top left) goes back to the overview. |
| Overview | One card per skill, most recently changed first: description, number of files, last change. |
| Skill page | Header with the name, description (click to expand), folder (click to show in Finder). Left: all its files (`SKILL.md` first, then `references/`, `templates/`, `scripts/`…). Right: the file rendered as Markdown; code and YAML files are syntax-highlighted. |
| Links | Any file path in the text (a link or `inline code` such as `references/evaluation.md`) that names a file of the skill is clickable and opens it. Web links open in your browser; other local paths open in their default app. |
| Edit | **Edit** (⌘E) switches the file to a plain-text editor; ⌘S saves, Esc cancels (asks if there are unsaved changes). **Open in editor** uses your default app for the file type. |
| New skill | **+** or ⌘N: a name (lowercase-kebab), a sentence on when the agent should use it, and a location. Creates `<location>/<name>/SKILL.md` from a template and opens it for editing. |
| Built-in skills | The switch at the bottom shows the skills that ship with Claude Code (`skills/synced/`) and Codex (`skills/.system/`). Hidden by default so the list shows your own. |

## Where it looks

By default `~/.claude/skills`, `~/.codex/skills` and `~/.agents/skills`. **Add folder** (sidebar
footer, or Settings) adds another, for example a project's `.claude/skills`. A skill is any
folder with a `SKILL.md`, up to three levels below a listed folder; a folder reached twice
through symlinks is shown once. The window rescans each time it opens; **↻** rescans now.

The window only reads and writes files inside the skill folders it found. Nothing is deleted
from here: delete a skill in Finder.

## Options (config.json)

| Key | Meaning |
|---|---|
| `skill_manager.folders` | Folders searched for skills (`~` allowed) |
| `skill_manager.show_builtin` | Also list Claude Code's and Codex's built-in skills |
