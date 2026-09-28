# Troubleshooting

## “App can't be opened because the developer cannot be verified”

Builds that aren't notarized trigger this. Right-click the app → **Open** → **Open**, once. To avoid it for people you share it with, build with a Developer ID certificate and notarization (see [Development](development.md#sharing-builds)).

## A shortcut doesn't work

Settings → the plugin's page lists shortcuts that another app already owns. Pick a different combination, or free it in that app.

## Screenshots are blank or the capture asks for permission again

Grant **Screen Recording** in System Settings → Privacy & Security, then relaunch from the menu (*Finish Setup…* → *Relaunch*). If you build the app yourself, sign every build with the same certificate. macOS ties the permission to the signature and bundle ID.

## The AI Chat can't find Claude Code or Codex

Settings → AI Chat → *Detect Again*. If it still fails, run `which claude` or `which codex` in Terminal, and paste the path under *Advanced*. Make sure you've run the CLI once in Terminal to sign in.

## Obsidian froze after building the app (fixed in 3.0.0)

**Symptom:** Obsidian stopped responding a few seconds after `scripts/build.sh` ran, with its window process at 100% CPU for many minutes. It happened on every build, so it looked like the new app was freezing Obsidian.

**Cause:** the build script; the app itself never did this. To make the drag-to-install DMG, `build.sh` staged it in `dist/dmg-stage/` with a symlink `Applications → /Applications`. When the project folder is inside an Obsidian vault, Obsidian follows that symlink and starts indexing all of `/Applications`, which is roughly 260,000 files on a typical Mac. The stage folder was deleted seconds later, but Obsidian was already stuck processing the file events. Every freeze came right after a build.

**Fix:** `build.sh` now stages the DMG and the icon set in a temporary folder outside the project (`mktemp -d`). The DMG is unchanged. Verified by watching the project for symlinks during a full build (none appeared), with Obsidian's CPU staying flat.

**Rule for this repo:** temporary files, and especially symlinks or large file trees, go in `mktemp -d`, never inside the project, because it may sit in a vault or a synced folder. `.build/` is fine because Obsidian ignores dot-folders.

If Obsidian is frozen from an older build, quit and reopen it. Nothing in the vault is changed.
