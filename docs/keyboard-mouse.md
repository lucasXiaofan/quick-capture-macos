# Keyboard Mouse

Control the pointer from the keyboard: hold one key and your left hand becomes a mouse. Nothing to calibrate, no camera, and it works the same every time.

Off by default: turn it on in Settings → Keyboard Mouse.

## Setup

Two permissions, both on the plugin's Settings page:

- **Accessibility**, to move the pointer and to swallow the keys you use as a mouse.
- **Input Monitoring**, to notice when you hold the activation key.

## Using it

Hold the **activation key** (default: **Right Option**, with your right thumb) and use your left hand:

| Key | Does |
|---|---|
| W A S D | Move the pointer. Hold longer to go faster; add **Shift** for a boost |
| 1 2 3 / 4 5 6 | Jump to the centre of a screen panel (see below) |
| Space | Left button (hold = press and hold, so you can drag with WASD) |
| E | Right button |
| Space, Space | Double click (press the button twice quickly) |

The screen is split into six panels laid out like the number keys:

```
 1 | 2 | 3
 ---+---+---
 4 | 5 | 6
```

The usual flow: jump to the panel your target is in with a number, then fine-tune with WASD and click with Space. Panels use the display the pointer is currently on.

Letting go of the activation key stops everything (and releases a held button). Keys other than the ones above, and any combination with ⌘ or ⌃, reach the app normally.

## Options

- **Activation key:** Right Option (default), Right Command, or Right Control (external keyboards). Right Option types special characters (⌥E, ⌥A…) only while it is held, so it rarely collides with normal typing.
- **Top speed:** how fast the pointer goes after a direction key has been held for about a second.
- An optional **Pause / Resume** shortcut can be assigned in Settings → Shortcuts.

## Why this exists

Eye tracking and nose tracking (see [Nose Control](nose-control.md)) were both tried first. Neither was stable enough, or helpful enough, to replace a mouse: the pointer wobbles, calibration drifts when you move, and lighting matters. Keyboard control is deterministic.

## Troubleshooting

- *Nothing happens:* check Settings → Keyboard Mouse says "on". If it says "Waiting for permissions…", grant both permissions (a rebuilt, differently signed app needs them again).
- *The activation key types accents:* choose Right Command or Right Control instead.
