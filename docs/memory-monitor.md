# Memory Monitor

A live memory window for local-model work (MLX, llama.cpp, LM Studio). Off by default: switch it on in
Settings → Memory Monitor, then ⌃⌥M (set by you; no default) or the menu bar → **Open Memory Monitor**.

## The window

| Area | What it shows |
|---|---|
| Header | Used of total (Activity Monitor's definition: app + wired + compressed), what is left before swapping, swap used, memory pressure. |
| Bar | App, Wired, Compressed, **Cached files**, Free. Cached files are file pages in RAM: a model loaded with mmap (llama.cpp, LM Studio) lives here, so Activity Monitor's Memory column shows a 5 GB model as ~1.6 GB. They are given back when something needs the memory. |
| Chart | Used, Cached files and Free + cached, every second, last 10 minutes. |
| Baseline | **Set Baseline Now**, load a model, read the change in used, cached files and swap. |
| Apps | Every app with its full footprint (helper processes included), **Keep** checkbox, **Quit** (asks the app to quit; right-click for Force Quit). **Quit All Not Kept…** lists what it will quit and asks first. |
| Other big processes | Processes over 50 MB that belong to no app (python, llama-server…), with **Stop** (SIGTERM, after a confirmation). System processes are hidden. |

Finder and Quick Capture are always kept.

## Options

`memory_monitor.keep`: bundle ids that Quit All skips (default: Terminal, iTerm2, Xcode, VS Code, Claude). Changed by the Keep checkboxes.
