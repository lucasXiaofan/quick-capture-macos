# Media Capture

Three kinds of capture, each one shortcut away, all tagged and found in one dashboard. Everything stays on your Mac.

- **Videos** of yourself — usually about self-control, to encourage your future self — tagged and replayed in a second.
- **Selfies**, e.g. one a day.
- **Meeting recordings** of your microphone and the Mac's sound, transcribed into a `.txt` once you stop.

(Called Video Notes before; its config key is still `video_notes`, so settings, shortcuts and folders carry over.)

## Shortcuts (change them in Settings)

| Action | Default | |
|---|---|---|
| Open dashboard | (none) | First item in the menu bar section, and **Open Dashboard** at the top of Settings → Media Capture. **Plugins ▸ Media Capture ▸ Selfies… / Meeting Recordings & Transcripts…** open it on those tabs |
| Record | ⌃⌥R | Pressing it again while recording pauses / resumes |
| Record screen + camera | ⌃⌥⇧R | See [Screen + camera](#screen--camera). Pressing it again pauses / resumes |
| Pause / resume | ⌃⌥P | In the menu bar only while recording |
| Stop | ⌃⌥S | In the menu bar only while recording. Then a small window asks what the video is about |
| Discard | ⌃⌥X | While recording: pauses and asks, then throws the recording away (or resumes if you keep it). Also works while the tag prompt of a just-finished recording is open |
| Quick play | ⌃⌥V | Then press **1**–**5**; the video opens in a small window and starts playing after half a second (Esc closes) |
| Play slot 1–5 directly | (none) | Optional: one shortcut per slot, no list in between (not in the menu bar) |
| Selfie | ⌃⌥F | Shows the camera; press again (or Space) to take the photo. See [Selfie](#selfie) |
| Record meeting audio | ⌃⌥A | Microphone + the Mac's sound. Pressing it again pauses / resumes. See [Meeting audio](#meeting-audio) |
| Stop meeting recording | ⌃⌥⇧A | Then it's compressed and transcribed |

While recording, a small preview with a timer sits at the bottom of the screen.

## Screen + camera

⌃⌥⇧R records the display the active window is on at 720p (H.264, 30 fps, as wide as the display's shape: 1152×720 on a 16:10 Mac) with your camera as a rounded square in a corner. Sound is the Mac's own audio plus the microphone (if on), mixed into one track when you stop. The live preview sits exactly where the square will be in the video; Quick Capture's own windows (preview, toasts, prompts) are left out of the recording.

Settings → Media Capture → **Screen + camera**: **Camera size** (10–50% of the video height, default 25%) and **Camera corner** (default bottom left).

They're recorded at high quality, then compressed in the background like camera videos but without the blur: HEVC at 15 fps, which keeps screen text sharp, about 4–6.5 MB per minute. Files are named `Screen yyyy-MM-dd HH.mm.ss.mov`.

Needs **Screen Recording** permission (the first press asks; after granting, relaunch Quick Capture).

## Selfie

For a daily photo of yourself. ⌃⌥F opens a mirrored live preview in the middle of the screen so you can see how you look; press ⌃⌥F again (or Space, Return, or click it) to take the photo. It stays on screen for a moment, then the window closes and asks for a tag and a note (optional: **Skip** or Esc leaves it untagged, **Discard…** throws the photo away; turn the question off with **Ask for a tag and note after each selfie**, `video_notes.selfie_prompt`). Esc in the camera window closes without a photo.

Photos are JPEGs named `Selfie yyyy-MM-dd HH.mm.ss.jpg` in `<folder>/quick-capture-selfie/`. They're saved mirrored, exactly as the preview showed them; turn **Save selfies mirrored** off in Settings for the camera's unmirrored view (`video_notes.selfie_mirror`). The camera can't take a selfie while it's recording a video.

## Meeting audio

For meetings of half an hour, an hour or more. ⌃⌥A starts recording **your microphone and the Mac's own sound** (the other people in Zoom, Teams, Meet, a video…); pressing it again pauses and resumes, and ⌃⌥⇧A stops. A small `REC 12:34` pill sits at the top right while recording; it's excluded from screen sharing, so the meeting doesn't see it (turn it off with `video_notes.meeting_indicator`).

The Mac's sound needs **Screen Recording** permission (ScreenCaptureKit, the same permission as screen + camera). Without it, only the microphone is recorded and the start message says so. Turn the Mac's sound off with **Also record the Mac's sound**.

### What happens when you stop

1. **Compression.** While recording, the microphone and the Mac's sound go to two tracks of a temporary `Meeting … .part.mov`, written in 10-second fragments, so a crash or a quit loses at most a few seconds. The next launch finishes any such file. On stop the two are mixed into one `.m4a`:

   | Quality (`meeting_compression`) | Format | Size |
   |---|---|---|
   | `compact` (default) | HE-AAC, mono, 32 kHz, 32 kbps | ~16 MB per hour (measured) |
   | `standard` | AAC-LC, mono, 32 kHz, 64 kbps | ~29 MB per hour |
   | `high` | AAC-LC, stereo, 48 kHz, 128 kbps | ~58 MB per hour |

   Speech needs very little: recognisers only look below 8 kHz, and HE-AAC rebuilds the high frequencies at a fraction of the bits, so `compact` sounds clear and transcribes as well as the others. Mono halves the size again; meeting audio has nothing worth keeping in stereo. (Opus would be a little smaller still, but AVFoundation can't write it to an `.m4a` that QuickTime and every player opens.) If compression fails, the uncompressed recording is kept as `.mov`.

While it's being compressed, a window asks what the meeting was about: a tag and a note, same as for videos (optional; **Skip** leaves it untagged; turn it off with `video_notes.meeting_prompt`).

2. **Transcription**, once the recording is finished (never live during the meeting). It runs as a separate process while you get on with your day, and writes `Meeting yyyy-MM-dd HH.mm.ss.txt` next to the audio: a header, then one `[mm:ss] sentence` line at a time. A message tells you when it's ready.

Files go to `<folder>/quick-capture-audio/`, each recording next to its transcript. The dashboard's **Recordings** tab shows them together (see [Dashboard](#dashboard)); **Transcribe Again** on a card (or **Plugins ▸ Media Capture ▸ Transcribe a Recording Again…**) redoes one, for example after installing whisper.cpp or changing the language.

### Speech to text

Everything runs on this Mac; nothing is uploaded. **Engine** in Settings (`video_notes.transcription_engine`), `auto` tries these in order:

| Engine | Install | Chinese + English mixed | Speed (Apple silicon) |
|---|---|---|---|
| **whisper.cpp** | `brew install whisper-cpp` | Good | ~15× real time (measured with `small`), ~4 min per hour; the recommended engine |
| **OpenAI Whisper** | `brew install openai-whisper` | Good | Slow (CPU): ~0.7× real time with `small`, so ~45 min per hour |
| **Apple Speech** (`SpeechTranscriber`) | Built into macOS 26; the language model downloads once | One language per recording: in Chinese mode English words mostly come through, but less reliably | ~4× real time (measured), ~15 min per hour |

**Models.** Whisper models aren't bundled. If you use [Handy](https://handy.computer), its downloaded models (`~/Library/Application Support/com.pais.handy/models/ggml-*.bin`) are found automatically, as are models in `~/.cache/whisper.cpp`; the best one wins (large-v3-turbo › medium › small › base; English-only `.en` models last). OpenAI Whisper uses what's in `~/.cache/whisper` (or downloads `small` once). Set **Model** (`transcription_model`) to a file path or name to choose yourself. For mixed meetings `small` is the minimum; `large-v3-turbo` is noticeably better and still fast with whisper.cpp.

**Language.** `auto` lets Whisper detect the language from the first 30 seconds. For meetings that are mostly Chinese with English terms, choose **Chinese (with English words)** (`zh`): Whisper then keeps English words in English instead of translating them. The **Hint** (`transcription_prompt`) is Whisper's initial prompt; the default asks for Simplified Chinese and English, and it's a good place for names and jargon that come up often.

## After recording

Pick an existing tag or type a new one (each video has one tag), optionally add a note, press Return. **Skip** leaves it untagged. Not happy with it? **Discard…** (⌘⌫) asks once and moves it to the Trash, so it never reaches the dashboard. Videos are named `Video yyyy-MM-dd HH.mm.ss.mov` (screen recordings `Screen …`).

## Dashboard

Three tabs, **Videos**, **Selfies** and **Recordings**, each with its count. The header has search, the playback volume, a capture button for the open tab (**Record**, **Take Selfie**, **Record Meeting**; **Stop** while recording) and **⋯** for tags and Finder.

Each tab is a Kanban board with one column per tag (plus **Untagged**), newest at the top; the tags are shared by all three. Drag a card to another column to change its tag. **⋯** on a card, or right-click, for **Edit Tag & Note**, **Show in Finder** and **Move to Trash**. The header and each column show how many items there are and how much disk space they use, so you know when to clean up.

- **Videos:** the five **Quick Play** slots sit above the board: click one to play it, drop a card on one to assign it. Each card shows a thumbnail and the length. Click the thumbnail to play (same small player, starts automatically; **Open in QuickTime Player** for the default player). The card menu also has **Quick Play Slot** (1–5; one video per slot) and **Compress**.
- **Selfies:** click a photo to open it in Preview.
- **Recordings:** each card holds the audio and its transcript together: **Play** opens the small player, **Transcript** (or a click on the transcript preview) opens the `.txt`. The card shows the first lines of the transcript, or **Compressing & transcribing…** while that's running. Search also looks inside transcripts and shows the matching lines. **Transcribe Again** is in the card menu. Moving a recording to the Trash takes its transcript with it.

## Volume

Recordings from the Mac's microphone are often quiet. **Volume** (Settings → Media Capture → Playback, or the dashboard header) plays every video louder, 25–800%, without touching the Mac's volume. A soft limiter rounds off the loud parts instead of letting them crackle. It changes playback only, never the files, and doesn't apply to QuickTime Player.

## Tags

Tags are columns. **New Tag** (dashboard header) adds one next to Untagged; **drag a column header** onto another column to reorder. **⋯** on a column deletes that tag, and **Manage Tags…** lets you reorder, add, and select several to delete. Deleting always asks first, and the videos are kept and move to Untagged. There are no built-in tags.

## Compression

After each recording the video is shrunk in the background: camera videos to 720p HEVC (default **Smart** also blurs the background), about 4 MB per minute; screen recordings to 15 fps HEVC. The original is replaced only if the result is complete and smaller. Change the mode in Settings; **Compress Again** on a card or **⋯ → Compress All Videos** in the dashboard brings older videos to the current targets. See [video-compression.md](video-compression.md) for the algorithm comparison.

## Where files go

`<folder>/quick-capture-video/`, with an `index.json` holding tags, notes and slots (so the folder can be moved or synced as a whole). The folder defaults to `~/Movies`; change it in Settings. Deleted videos go to the Trash.

## Permissions

Camera (required for video and selfies), Microphone (optional for videos — turn it off with `video_notes.microphone` — and used by meeting audio), and Screen Recording (only for screen + camera and the Mac's sound in meeting recordings).
