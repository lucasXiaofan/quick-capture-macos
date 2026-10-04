# Troubleshooting

## “App can't be opened because the developer cannot be verified”

Builds that aren't notarized trigger this. Right-click the app → **Open** → **Open**, once. To avoid it for people you share it with, build with a Developer ID certificate and notarization (see [Development](development.md#sharing-builds)).

## A shortcut doesn't work

Settings → the plugin's page lists shortcuts that another app already owns. Pick a different combination, or free it in that app.

## Screenshots are blank or the capture asks for permission again

Grant **Screen Recording** in System Settings → Privacy & Security, then relaunch from the menu (*Finish Setup…* → *Relaunch*). If you build the app yourself, sign every build with the same certificate. macOS ties the permission to the signature and bundle ID.

## The AI Chat can't find Claude Code or Codex

Settings → AI Chat → *Detect Again*. If it still fails, run `which claude` or `which codex` in Terminal, and paste the path under *Advanced*. Make sure you've run the CLI once in Terminal to sign in.

## “Capture not saved — Obsidian CLI isn't responding”, but the capture *was* saved (fixed in 3.0.1)

**Symptom:** after pressing ⌘↩, an alert said the capture wasn't saved and pointed to a recovery file, yet the text was already in the note.

**Cause:** Obsidian's CLI occasionally exits without printing the result of a command it *did* run. The system log showed the `save` command's CLI process start, write the note, and exit normally in 0.25 s, but its reply never arrived, and no follow-up status check ran. Obsidian recorded the save as successful. The app took the missing reply as a failure. It couldn't be reproduced on demand: hundreds of repeated, parallel, and bare-environment calls all replied. Obsidian itself prints *"Your Obsidian installer is out of date… latest installer includes better CLI support"*, so an older installer is a likely factor.

**Fix:** the app retries a call when the reply is missing (up to 3 attempts). This is safe because every bridge action can be repeated: a repeated `save` with the same capture id returns without writing again, which `tests/bridge.test.cjs` checks. Verified by dropping every other CLI reply on purpose: every call recovered, and nothing was written twice. Lost replies are now logged, without your text, to `~/Library/Application Support/Quick Capture/obsidian_capture/bridge.log`.

**Also recommended:** install the latest Obsidian from [obsidian.md/download](https://obsidian.md/download). The in-app updater doesn't update the installer that the CLI runs from.

If you saw this alert, check the note. When the text is there, the recovery file named in the alert can be deleted (menu → *Unsaved Captures*).

## Obsidian froze after building the app (fixed in 3.0.0)

**Symptom:** Obsidian stopped responding a few seconds after `scripts/build.sh` ran, with its window process at 100% CPU for many minutes. It happened on every build, so it looked like the new app was freezing Obsidian.

**Cause:** the build script; the app itself never did this. To make the drag-to-install DMG, `build.sh` staged it in `dist/dmg-stage/` with a symlink `Applications → /Applications`. When the project folder is inside an Obsidian vault, Obsidian follows that symlink and starts indexing all of `/Applications`, which is roughly 260,000 files on a typical Mac. The stage folder was deleted seconds later, but Obsidian was already stuck processing the file events. Every freeze came right after a build.

**Fix:** `build.sh` now stages the DMG and the icon set in a temporary folder outside the project (`mktemp -d`). The DMG is unchanged. Verified by watching the project for symlinks during a full build (none appeared), with Obsidian's CPU staying flat.

**Rule for this repo:** temporary files, and especially symlinks or large file trees, go in `mktemp -d`, never inside the project, because it may sit in a vault or a synced folder. `.build/` is fine because Obsidian ignores dot-folders.

If Obsidian is frozen from an older build, quit and reopen it. Nothing in the vault is changed.
