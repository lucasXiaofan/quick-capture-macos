# Read Aloud

Drag a region of the screen and hear its text, read by Kokoro-82M running locally on Apple Silicon (MLX).
Nothing leaves the Mac.

| Action | Default | Does |
|---|---|---|
| Read Screenshot Aloud (`read`) | none | Select a region; its text is read aloud |
| Read Clipboard Aloud (`clipboard`) | none | Reads the text on the clipboard |
| Pause / Resume Reading (`pause`) | none | Pauses or resumes playback (shown in the menu while reading) |
| Stop Reading (`stop`) | none | Stops playback and generation |

## The reading panel

Every reading opens a small floating panel (it doesn't take focus from the app you're in; drag it by its background):
the recognized text, split the way it is spoken, with finished parts dimmed and the words already said in the accent
color; a progress bar with elapsed / total time (the total is an estimate until the last chunk is generated);
**Pause / Resume** and **Stop**, and **✕** to close. It says what is happening (Recognizing text…, Preparing voice…,
Generating…, Reading, Paused, Done) and shows problems (no text found, no Python, engine stopped or over its memory
limit) instead of failing silently. After **Done** it offers **Replay** and closes itself after 8 s.

A new reading replaces the one playing. The plugin's submenu has **Replay Last Reading** and **Open Read Aloud Folder**.

## Setup
1. A Python 3.10–3.12 with `mlx-audio` (and `misaki`). The plugin looks in `read_aloud/venv`, then in conda / miniforge
   envs, then `python3`; or set **Python** in Settings (`read_aloud.python_path`). To keep everything in one deletable folder:
   ```bash
   python3.11 -m venv ~/Library/Application\ Support/Quick\ Capture/read_aloud/venv
   ~/Library/Application\ Support/Quick\ Capture/read_aloud/venv/bin/pip install mlx-audio "misaki[en]" soundfile
   ```
2. Screen Recording permission (shared with the other screenshot plugins).
3. The first reading downloads the model (≈340 MB) into `read_aloud/models`.

## How it is fast
- **Text:** Apple Vision, accurate level without language correction (0.38 s for a 16-line abstract; the fast level
  made audible mistakes).
- **Warm start:** the shortcut starts the engine before you select, so loading overlaps the selection. It stays loaded
  for `idle_minutes` (default 10), then exits and frees its memory. Cold start ≈ 5–7 s in Low Power Mode.
- **Chunks that grow:** 80 → 200 → 360 characters. Generation time is ~linear in audio length, so the short first chunk
  sets the time to first audio (0.8 s measured in Low Power Mode; about half that expected without it, not measured) and each next chunk is ready before the previous ends.
- **Same text again:** saved readings are keyed by text + voice + speed and play without running the model.

## Memory and storage
- `memory_limit_gb` (default 3): MLX memory limit; the buffer cache is capped at 0.5 GB and cleared after each reading
  (uncapped it grew to 17 GB on Kokoro); the engine exits if its footprint passes the limit and restarts on the next
  reading. Measured: ~0.7 GB idle, 2.1 GB footprint while reading, MLX peak 2.6 GB on 360-character chunks.
- Everything is in `~/Library/Application Support/Quick Capture/read_aloud/`: `models/` (the model, `HF_HOME`) and `audio/`
  (saved readings, `.wav` + `.txt`, pruned oldest-first above `audio_limit_mb`). Settings → Read Aloud shows both sizes
  with **Delete Saved Audio** / **Delete Model**.

## Options
| Key | Default | Meaning |
|---|---|---|
| `python_path` | `""` | Python with mlx-audio; empty = search |
| `voice` | `af_heart` | Kokoro voice id (`a…` US English, `b…` UK, `z…` Mandarin, …) |
| `speed` | `1` | 0.5–2 |
| `memory_limit_gb` | `3` | see above (≥ 1.5) |
| `audio_limit_mb` | `500` | saved audio kept |
| `idle_minutes` | `10` | unload after this long idle; 0 = keep loaded |

Protocol (for changing the engine): one JSON object per line on stdin (`speak`, `stop`, `stats`, `quit`), events on stdout
(`ready`, `chunk`, `done`, `stats`, `error`, `exit`). `python kokoro_server.py bench …` compares chunk plans and cache settings.
