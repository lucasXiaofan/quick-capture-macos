# Nose Control

Move the pointer by turning your head and click with keyboard shortcuts, so you can work without touching the mouse. The camera image is processed on your Mac with Apple's Vision framework; nothing is saved or sent anywhere.

> **Experimental — not recommended.** After trying eye tracking and nose tracking, the author found head-based pointer control too unstable (jitter, calibration drift, lighting) to be genuinely useful. It is kept for reference. For hands-free-ish pointer control, use [Keyboard Mouse](keyboard-mouse.md) instead.

Off by default: turn it on in Settings → Nose Control.

## Setup

Two permissions, both on the plugin's Settings page:

- **Camera**, to see your nose.
- **Accessibility**, to move the pointer smoothly and to click. Turn on *Quick Capture* in System Settings → Privacy & Security → Accessibility.

## Using it

1. Press **⌃⌥N** (or *Start* in Settings, or the menu-bar item).
2. A small preview shows your camera with a **green dot on your nose**. Hold still for a moment.
3. Calibrate in five steps. A green circle already follows your nose, so you can see what your head does. Confirm each step with the **Left Click** shortcut (⌥↩):
   centre, then your **comfortable** limit to the left, right, up and down.
4. Move the pointer with your head. Press ⌃⌥N again to stop.

The calibration is saved, so the next start skips it. Press **⌃⌥C** to redo it (for example after moving your chair).

## Shortcuts

All of these are configurable in Settings. Except for Start / Stop, they only exist while nose control is running, so ⌥↩ works normally in other apps otherwise.

| Action | Default |
|---|---|
| Start / Stop | ⌃⌥N |
| Left click (also confirms calibration steps) | ⌥↩ |
| Right click | ⌥⇧↩ |
| Double click | ⌃⌥↩ |
| Pause / resume pointer | ⌥Space |
| Sensitivity up / down | ⌥] / ⌥[ |
| Recalibrate | ⌃⌥C |

## Tuning

- **Sensitivity** (horizontal and vertical separately): how far the pointer travels per head movement. ×1 means your calibrated limits reach the screen edges; ×2 means half the head turn. It applies on top of the calibration, so it needs no recalibration.
- **Steadiness:** higher removes shake when you hold still, at the cost of a slightly slower response. Raise it if the pointer wobbles while your head is still; lower it if it feels sluggish. Raising sensitivity magnifies wobble, so raise steadiness with it.
- Light your face evenly and avoid a bright window behind you. Tracking works best at about arm's length.

## Limits

- It follows the primary display only.
- Anything that hides your nose (a mask) stops tracking.
- A hand on the trackpad still moves the pointer; whichever moved last wins.

## Troubleshooting

- *"Looking for your nose…" never ends:* check the camera permission and lighting; only one app can use the camera at a time.
- *Clicks do nothing:* Accessibility isn't granted for Quick Capture (a rebuilt, differently signed app needs it again).
- *Pointer jumps by a fixed amount:* recalibrate (⌃⌥C).
