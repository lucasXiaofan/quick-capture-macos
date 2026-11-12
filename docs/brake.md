# Brake

One shortcut that pulls you back from the brink: it shows **one** reminder you picked in advance — a PDF or EPUB book at a set page, a video or audio clip from a set second, an image, or a single line of text.

## Use it

1. Turn it on in **Settings → Brake**.
2. **Choose File…**: a PDF or EPUB, a video, an audio file or an image. Or leave it empty and only write a line.
3. Write the **Line** (optional when there is a file): it is shown above the file, in large type when it is on its own.
4. Give *Show Brake* a shortcut, or add it as a slice in **Settings → Radial Wheel**.

The window opens in front, in the middle of the screen you're on, as an ordinary window: it stays on the Space it opened in, other windows can go over it, and Quick Capture shows in the Dock and ⌘-Tab while it's open (so you can switch back to it). **Esc** or **Close** closes it and hands focus back to the app you were in; other Quick Capture windows — the selfie camera of a screen + camera recording, the REC timer — stay on screen.

## Reading a book

A PDF or EPUB opens like Apple Books: pages on a soft paper backdrop, as an open two-page spread when the window is wide enough (one page when it's narrow — resize to switch). The bookmarked page wears a red ribbon.

- **← →** (or space / ⇧space, Page Up/Down, a sideways two-finger swipe, or the arrows that appear on hover) turn pages; Home/End jump to the start/end.
- The slider at the bottom scrubs through the book (pages for a PDF, chapters for an EPUB).
- The **bookmark icon** at the top right (⌘D) moves the bookmark to this page; **Back to Bookmark** returns to it.

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
- **EPUB:** opens at `chapter`, `chapter_progress` of the way in. In **Settings → Brake → Bookmark**, pick a chapter from the table of contents; the preview shows how it opens in your font and size.
- **Video / audio:** starts at `start_seconds` and plays at once (switch off *Play as soon as it opens* to start paused). **Start Here Next Time** saves the current position.

Choosing a different file resets the bookmark, start time and zoom.

An EPUB is unpacked once into `~/Library/Application Support/Quick Capture/brake/epub/` (again only when the file changes). Apple Books' own `.epub` folders are read in place.

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
  "path": "~/Documents/books/The Power of Now.pdf",
  "page": 20,
  "chapter": 1,
  "chapter_progress": 0,
  "font": "Iowan Old Style",
  "font_size": 20,
  "pdf_zoom": 1,
  "start_seconds": 0,
  "text": "Stop. Breathe. Is this what you really want to be doing right now?",
  "autoplay": true
}
```
