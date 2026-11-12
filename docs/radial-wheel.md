# Radial Wheel

One shortcut instead of many: a wheel of your favourite actions pops up at the mouse pointer, like a weapon wheel in a game.

## Use it

1. Turn it on in **Settings → Radial Wheel**.
2. **Hold** ⌃⌥W, move the mouse toward a slice (it lights up and the middle shows its name), then **let go**: that action runs.
3. Or **tap** ⌃⌥W and let go without pointing anywhere: the wheel stays open. Then click a slice, press its number (1–9, 0 for the 10th), or press ↩ / Space for the highlighted one.

Pressing ⌃⌥W again, Esc, a right-click, or a click in the middle closes it without doing anything. Only the direction counts, not the distance, so a quick flick is enough.

The wheel opens on the display the pointer is on and doesn't take focus from the app you're in, so actions like *Screenshot → Current Note* still go to the right place.

## Slices

Settings → Radial Wheel lists the slices clockwise from the top. Each one can be any action of any plugin (the same list as Settings → Shortcuts). Use ↑ ↓ to reorder, − to remove, **Add Slice** for more (2–12), and **Reset to Defaults** to start over. A preview shows the wheel.

Dimmed slices belong to plugins that are switched off; picking one tells you which plugin to turn on.

Defaults: Record video, Record meeting audio, Selfie, Record screen + camera, Screenshot → current note, Note → current note, AI Chat, Media dashboard.

## Stopping recordings

While any Media Capture recording runs (video, screen + camera, meeting audio), **Esc** pauses it and asks **Save** (↩), **Discard** (D) or **Keep going** (Esc). So you start from the wheel and stop with Esc. See [Media Capture](media-capture.md).

## config.json

```json
"radial_wheel": {
  "enabled": true,
  "hotkeys": { "show": "<ctrl>+<alt>+w" },
  "slots": ["video_notes.record", "video_notes.meeting", "ai_chat.toggle"],
  "size": 1.0
}
```

Slot entries are `"<plugin id>.<action id>"`; the ids are the keys under `plugins` and their `hotkeys` in config.json.
