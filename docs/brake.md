# Brake

One shortcut that pulls you back from the brink: it shows **one** reminder you picked in advance — a PDF or EPUB book at a bookmark, a video or audio clip from a set second, an image, or a single line of text. Keep several and choose which one it shows.

## Use it

1. Turn it on in **Settings → Brake**.
2. **Add Files…**: PDFs or EPUBs, videos, audio files or images — as many as you like. The filled circle marks the one Brake shows; click another to switch, or pick *No file — only the line*. In the Brake window, the stack icon at the top left switches too. Each file keeps its own bookmark, start time and zoom.
3. Write the **Line** (optional when there is a file): it is shown above the file, in large type when it is on its own.
4. Give *Show Brake* a shortcut, or add it as a slice in **Settings → Radial Wheel**.

The window opens in front, in the middle of the screen you're on, as an ordinary window: it stays on the Space it opened in, other windows can go over it, and Quick Capture shows in the Dock and ⌘-Tab while it's open (so you can switch back to it). **Esc** or **Close** closes it and hands focus back to the app you were in; other Quick Capture windows — the selfie camera of a screen + camera recording, the REC timer — stay on screen.

## Reading a book

A PDF or EPUB opens like Apple Books: pages on a soft paper backdrop, as an open two-page spread when the window is wide enough (one page when it's narrow — resize to switch). The bookmarked page wears a red ribbon.

- **← →** (or space / ⇧space, Page Up/Down, a sideways two-finger swipe, or the arrows that appear on hover) turn pages; Home/End jump to the start/end.
- The slider at the bottom scrubs through the book (pages for a PDF, chapters for an EPUB).
- **PDF:** the **bookmark icon** at the top right (⌘D) moves the bookmark to this page; **Back to Bookmark** returns to it.
- **EPUB:** keep as many bookmarks as you like. The **bookmark icon** (⌘D) bookmarks this page, or removes its bookmark (blue ribbon). The **pin** (⇧⌘D) makes this page's bookmark the one Brake opens at (red ribbon) — a page has to be bookmarked first. Pinning another page turns the old one back into an ordinary bookmark. The **list** icon jumps to any bookmark; **Back to Bookmark** returns to the pinned one.

### Bigger text

- **EPUB:** click **Aa** to pick a font (Iowan Old Style, New York, Georgia, Palatino, Charter, San Francisco, Avenir Next, or the book's own) and size, or press ⌘+ / ⌘− / ⌘0. The text re-flows and keeps your place.
- **PDF:** a PDF's text is fixed, so **Aa**, ⌘+ / ⌘−, or a pinch zooms the page instead; ⌘0 fits it again. A zoomed page scrolls with ↑ ↓.

Brake remembers your font, size and zoom.

### Highlights

Select text, then click the **highlighter** at the top (⌃⌘H for yellow, or its menu for green, blue, pink or purple) — or right-click the selection. Right-click (PDF) or click (EPUB) a highlight to recolour or remove it.

- **PDF:** highlights are saved into the PDF itself, so Preview and other PDF apps show them too.
- **EPUB:** the book file isn't changed; highlights are kept in `~/Library/Application Support/Quick Capture/brake/highlights/`.

## Bookmarks

- **PDF:** opens at `page` every time, not where you stopped last. Move it from the reader (above), or in **Settings → Brake → Bookmark**: a large preview of the bookmarked page with ‹ › to step, and a strip of every page — click one to make it the bookmark.
- **EPUB:** opens at the pinned bookmark (`shown_bookmark`), or at the start of the book when none is pinned. **Settings → Brake → Bookmarks** lists them: click a pin to choose where Brake opens, × to delete one, *Bookmark a Chapter* to add one at a chapter's start. The preview shows how the pinned page opens in your font and size.
- **Video / audio:** starts at `start_seconds` and plays at once (switch off *Play as soon as it opens* to start paused). **Start Here Next Time** saves the current position.


An EPUB is unpacked once into `~/Library/Application Support/Quick Capture/brake/epub/` (again only when the file changes). Apple Books' own `.epub` folders are read in place.

Settings from before Brake had several sources (a top-level `path`, `page`, `chapter`, `chapter_progress`) are turned into one source the first time Brake loads them.

## Why not Apple Books?

Apple Books can't be told from outside to open a book at a bookmark — only to open the book where you last left it. Brake uses its own reader instead. To turn a PDF into an EPUB (for re-flowing text in Brake, or to read it in Apple Books and on iPhone/iPad), use calibre:

```bash
brew install --cask calibre
ebook-convert book.pdf book.epub --enable-heuristics
open -a Books book.epub
```

## config.json

```json
"brake": {
  "enabled": true,
  "hotkeys": { "show": "<ctrl>+<alt>+b" },
  "current": "a1b2c3d4",
  "sources": [
    { "id": "9f8e7d6c", "path": "~/Documents/books/Deep Work.pdf", "page": 20, "pdf_zoom": 1 },
    {
      "id": "a1b2c3d4",
      "path": "~/Documents/books/The Power of Now.epub",
      "bookmarks": [
        { "id": "5e6f7a8b", "chapter": 3, "progress": 0 },
        { "id": "c9d0e1f2", "chapter": 7, "progress": 0.42 }
      ],
      "shown_bookmark": "c9d0e1f2"
    },
    { "id": "0a1b2c3d", "path": "~/Movies/breathe.mp4", "start_seconds": 12 }
  ],
  "font": "Iowan Old Style",
  "font_size": 20,
  "text": "Stop. Breathe. Is this what you really want to be doing right now?",
  "autoplay": true
}
```
