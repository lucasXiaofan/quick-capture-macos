# Video compression (Video Notes)

Video is about 95% of a recording's size (measured: 2.1–2.75 Mbit/s of picture vs. 130–150 kbit/s of sound), so the savings come from the picture. Every recording is shrunk in the background after it's saved, to a fixed target measured on real recordings. The code is `Sources/QuickCapture/Plugins/VideoNotes/VideoCompressor.swift` (`VideoCompressor.target`).

## What happens to each kind of video

| Video | Picture | Sound | Size |
|---|---|---|---|
| Camera, `smart` (default) | 720p HEVC, ~0.5 Mbit/s, background blurred (Apple Vision person segmentation) | AAC mono 64 kbit/s | ~4 MB/min |
| Camera, `efficient` | 720p HEVC, ~0.7 Mbit/s, no blur | AAC mono 64 kbit/s | ~5.5 MB/min |
| Screen + camera (`smart` or `efficient`) | HEVC at **15 fps**, ~0.8 Mbit/s at most, same size as recorded (720 high) | AAC stereo 96 kbit/s | ~4–6.5 MB/min |
| `off` | as recorded | as recorded | camera ~17 MB/min, screen ~22 MB/min |

The result replaces the original only if it is complete (same duration) **and** smaller. `compression_version` in `index.json` records which target a video was compressed with; when the targets change, cards offer **Compress Again** and the dashboard's **⋯ → Compress All Videos** recompresses everything older, one at a time.

Why 15 fps for screen recordings: a screen is mostly still. At the same bit rate each frame gets twice the bits, which keeps text sharp where 30 fps smears it (see below). Your face in the corner moves a bit less smoothly; for talking that's fine.

## Measurements (2026-10-07, Apple-silicon Mac, hardware HEVC encoder)

Screen + camera, 90 s from a real 1112×720 recording (original H.264, 30 fps):

| Picture | MB/min | SSIM | Text |
|---|---|---|---|
| original H.264 30 fps | 24.8 | 1 | sharp |
| HEVC 30 fps 1.2 Mbit/s | 9.0 | 0.970 | sharp |
| HEVC 30 fps 0.8 Mbit/s | 6.0 | 0.951 | text in grey bubbles smears |
| HEVC 30 fps 0.5 Mbit/s | 4.7 | 0.936 | clearly blurry |
| **HEVC 15 fps 0.8 Mbit/s** (chosen) | **6.0** | — | **sharp, like 1.2 Mbit/s at 30 fps** |
| HEVC 15 fps 0.6 Mbit/s | 4.5 | 0.963 | slightly soft |
| 540p HEVC 0.5 Mbit/s | 3.8 | 0.923 | text too small |

Camera, a real 2-min 1080p recording (already `smart` at 1080p, 15.8 MB/min of picture):

| Picture | MB/min | SSIM | Note |
|---|---|---|---|
| 1080p HEVC 1 Mbit/s | 7.5 | 0.992 | slow (40 s for 2 min) |
| 720p HEVC 0.8 Mbit/s | 6.0 | 0.992 | |
| **720p HEVC 0.5 Mbit/s** (chosen) | **3.75** | **0.990** | face looks the same |
| 720p 15 fps 0.4 Mbit/s | 3.0 | 0.981 | movement a bit choppy |
| 540p HEVC 0.35 Mbit/s | 2.6 | 0.988 | less face detail |

Sound (computed, not measured): AAC 130–150 kbit/s ≈ 1 MB/min → mono 64 kbit/s ≈ 0.5 MB/min, no audible difference for voice. HE-AAC 32 kbit/s (0.24 MB/min) sounds dull on music; Opus would be best for voice but isn't reliably playable by QuickTime/AVPlayer in .mov, so neither is used.

Applying the new targets to the whole library (6 videos, 11.5 minutes, of which 8.6 min screen): **249 MB → 57 MB**. The 7.7-min screen recording went 165 MB → 35 MB (the encoder used only ~0.53 Mbit/s since the screen was mostly still); camera videos ~4 MB/min. At these rates 5 GB holds roughly 12 hours of camera video or 13+ hours of screen recordings.

## Other techniques considered

| Technique | Why not |
|---|---|
| Face-region quality map (ROI/QP) | AVFoundation/VideoToolbox give no region control for HEVC; needs ffmpeg + x265 (not bundled) |
| AV1 | No Apple hardware encoder; software is very slow; QuickTime on older Macs can't play it |
| Recording directly at the low bit rate | Real-time encoders at low rates look worse than this second pass; recording stays high quality, compression follows |
