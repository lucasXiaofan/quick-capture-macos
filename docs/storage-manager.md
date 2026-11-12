# Storage Manager

A disk dashboard for finding what fills your Mac and clearing it safely. Off by default: switch it on in
Settings → Storage Manager, then set a shortcut or use the menu bar → **Open Storage Manager**.
It replaces the standalone `storage-dashboard` Python script.

## The window

| Area | What it shows |
|---|---|
| Header | Free and used space, **Empty Trash** (with its size), **Rescan**, and **Mole Preview** when the `mo` cleaner is installed (dry run only). |
| Cleanup | Groups, each sorted by size: **Caches**, **App caches** (big folders in `~/Library/Caches`), **Environments** (`node_modules`, virtualenvs, conda envs), **AI models** (LM Studio, Hugging Face, Whisper), **Backups**, **Your folders**, **Protected**. Rows show size, a size bar, "untouched N mo" for environments and models, and a magnifier to show the folder in Finder. |
| Explore | Sizes of everything in a folder, biggest first. Double-click to go deeper; trash icon moves an entry to the Trash. |

## How cleaning works

- **safe** (caches that regenerate): the folder's contents are deleted at once.
- **→ Trash** (environments, models, backups, your folders): moved to the Trash, so you can put them back. Space returns after **Empty Trash**. Conda environments are removed with `conda env remove`.
- **Protected** (Keychains, `~/.ssh`, Photos, iCloud Drive, Messages, Chrome profile, simulators, Docker, Ollama, plus yours): shown, never cleaned. Nothing that contains or sits inside one is cleaned either.
- Cleaning is limited to your home folder (and a conda install), at least two levels down, and always asks first. Items belonging to a running app (Chrome, Spotify) are skipped until you quit it.

## Options

`storage_manager.project_roots` (where to look for `node_modules` and virtualenvs, up to 5 levels deep), `extra_paths` (your own folders to list), `protected_paths`, `min_discovered_mb` (hide small found items, default 100). All editable in Settings; see [Configuration](configuration.md).

macOS may ask permission the first time the scan reads Documents or Desktop.
