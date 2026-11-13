import AppKit
import SwiftUI
import WebKit

/// An EPUB laid out as pages, like Apple Books: one chapter at a time in a web view, split into
/// columns the width of the window and turned sideways. Font and size are yours; highlights are
/// kept beside Brake's settings.
@MainActor
final class EpubBookController: BookController {
    private enum Landing { case start, end, progress(Double), anchor(String) }

    let webView: BrakeWebView
    private let source: URL
    private var book: EpubBook?
    private let store: EpubHighlightStore
    private var chapter = 0
    private var page = 0
    private var pageCount = 1
    private var columns = 1
    /// Every bookmark (chapters 1-based), and the one Brake opens at.
    private var bookmarks: [BrakeBookmark]
    private var shownID: String?
    private(set) var fontName: String
    private(set) var fontSize: Int
    private var landing: Landing = .start
    private var revealForward: Bool?
    private var started = false
    private var navigation: EpubNavigation?

    override var contentView: NSView { webView }
    override var isEPUB: Bool { true }
    override var hasManyBookmarks: Bool { true }

    static let padH: CGFloat = 56
    static let padV: CGFloat = 44

    init(url: URL, source src: BrakeSource, settings: BrakeSettings, plugin: BrakePlugin) {
        source = url
        store = EpubHighlightStore(book: url)
        bookmarks = src.bookmarks
        shownID = src.shown?.id
        fontName = settings.font
        fontSize = settings.fontSize
        let config = WKWebViewConfiguration()
        webView = BrakeWebView(frame: .zero, configuration: config)
        super.init(plugin: plugin, sourceID: src.id)
        config.userContentController.add(EpubMessageHandler(self), name: "brake")
        webView.controller = self
        let nav = EpubNavigation(self)
        navigation = nav
        webView.navigationDelegate = nav
        webView.underPageBackgroundColor = Paper.nsColor
        webView.allowsMagnification = false
        webView.alphaValue = 0
        title = url.deletingPathExtension().lastPathComponent
        message = "Opening…"
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { Result { try EpubBook.open(url) } }.value
            self?.opened(result)
        }
    }

    private func opened(_ result: Result<EpubBook, Error>) {
        switch result {
        case .failure(let error):
            message = error.localizedDescription
        case .success(let b):
            book = b
            title = b.title
            sliderRange = 1...Double(max(2, b.chapters.count))
            if started { openAtShown() }
        }
    }

    override func start() {
        started = true
        if book != nil { openAtShown() }
    }

    /// Where Brake opens: the chosen bookmark, else the start of the book. Chapter 0-based.
    private var home: (chapter: Int, progress: Double) {
        guard let m = bookmarks.first(where: { $0.id == shownID }) else { return (0, 0) }
        return (index(m), m.progress)
    }

    private func index(_ m: BrakeBookmark) -> Int { min(max(0, m.chapter - 1), max(0, (book?.chapters.count ?? 1) - 1)) }

    private func openAtShown() {
        let h = home
        load(h.chapter, .progress(h.progress))
    }

    /// The bookmark on the page now showing.
    private var markHere: BrakeBookmark? {
        bookmarks.first { index($0) == chapter && pageFor(progress: $0.progress) == page }
    }

    override func stop() {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "brake")
        webView.stopLoading()
    }

    // MARK: Layout

    override func wantsTwoUp(in size: CGSize) -> Bool { size.width > 900 && size.width > size.height * 1.2 }

    override func setTwoUp(_ t: Bool) {
        let c = t ? 2 : 1
        guard c != columns else { return }
        columns = c
        restyle()
    }

    private func options(highlights: Bool) -> [String: Any] {
        var o: [String: Any] = [
            "columns": columns, "size": fontSize, "bg": Paper.cssBackground, "fg": Paper.cssInk, "dark": Paper.isDark,
            "padH": Self.padH, "padV": Self.padV,
        ]
        if let css = BrakeFont.named(fontName).css { o["font"] = css }
        if highlights {
            o["highlights"] = store.inChapter(chapter).map { ["id": $0.id, "start": $0.start, "end": $0.end, "color": $0.color.css] }
        }
        return o
    }

    private func json(_ o: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: o)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private func load(_ index: Int, _ land: Landing) {
        guard let book, book.chapters.indices.contains(index) else { return }
        let forward = index >= chapter
        chapter = index
        landing = land
        revealForward = webView.alphaValue > 0 ? forward : nil
        let ucc = webView.configuration.userContentController
        ucc.removeAllUserScripts()
        ucc.addUserScript(WKUserScript(source: "window.__brakeOpts = \(json(options(highlights: true)));\n" + Self.script,
                                       injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        webView.loadFileURL(book.chapters[index], allowingReadAccessTo: book.root)
        sync()
    }

    fileprivate func finished() {
        Task { @MainActor in
            let count = (try? await webView.callAsyncJavaScript("return await brake.ready()", contentWorld: .page)) as? Int ?? 1
            pageCount = max(1, count)
            let target: Int
            switch landing {
            case .start: target = 0
            case .end: target = pageCount - 1
            case .progress(let p): target = pageFor(progress: p)
            case .anchor(let id):
                target = (try? await webView.callAsyncJavaScript("return brake.pageOf(id)", arguments: ["id": id], contentWorld: .page)) as? Int ?? 0
            }
            show(page: target, forward: revealForward)
            webView.alphaValue = 1
            message = nil
        }
    }

    fileprivate func failed(_ error: Error) { message = error.localizedDescription }

    /// Links inside the book move to that chapter (and footnote); web links open in the browser.
    fileprivate func allows(_ action: WKNavigationAction) -> Bool {
        guard action.navigationType == .linkActivated, let url = action.request.url else { return true }
        defer { followLink(url) }
        return false
    }

    private func followLink(_ url: URL) {
        if url.isFileURL, let book {
            let path = url.standardizedFileURL.path
            if let i = book.chapters.firstIndex(where: { $0.standardizedFileURL.path == path }) {
                let anchor = url.fragment.map { Landing.anchor($0) } ?? .start
                if i == chapter, case .anchor(let id) = anchor {
                    Task { @MainActor in
                        let p = (try? await webView.callAsyncJavaScript("return brake.pageOf(id)", arguments: ["id": id], contentWorld: .page)) as? Int ?? page
                        show(page: p, forward: p >= page)
                    }
                } else {
                    load(i, anchor)
                }
            }
        } else if let scheme = url.scheme, ["http", "https", "mailto"].contains(scheme) {
            NSWorkspace.shared.open(url)
        }
    }

    private func pageFor(progress p: Double) -> Int { min(pageCount - 1, max(0, Int((p * Double(pageCount)).rounded()))) }

    private func show(page p: Int, forward: Bool?) {
        page = min(max(0, p), pageCount - 1)
        if let forward { Self.pushTransition(on: webView, forward: forward) }
        webView.evaluateJavaScript("brake.go(\(page))")
        sync()
    }

    private func restyle() {
        guard book != nil, webView.alphaValue > 0 else { return }
        webView.evaluateJavaScript("brake.restyle(\(json(options(highlights: false))))") { [weak self] result, _ in
            MainActor.assumeIsolated { self?.laidOut(result) }
        }
    }

    private func laidOut(_ result: Any?) {
        guard let r = result as? [String: Any] else { return }
        pageCount = max(1, r["count"] as? Int ?? pageCount)
        page = min(pageCount - 1, max(0, r["page"] as? Int ?? page))
        sync()
    }

    private func sync() {
        guard let book else { return }
        let title = book.titles[chapter]
        positionLabel = "\(title) · \(page + 1) of \(pageCount)"
        sliderValue = Double(chapter + 1)
        let here = markHere
        bookmarkShowing = here != nil
        shownShowing = here != nil && here?.id == shownID
        let h = home
        hasShownMark = bookmarks.contains { $0.id == shownID }
        if !hasShownMark { shownShowing = chapter == h.chapter && page == 0 }
        canGoBack = chapter > 0 || page > 0
        canGoForward = chapter < book.chapters.count - 1 || page < pageCount - 1
        let items = bookmarks.sorted { ($0.chapter, $0.progress) < ($1.chapter, $1.progress) }.map { m in
            BookMarkItem(id: m.id, label: book.titles[index(m)] + (m.progress > 0 ? " · \(Int((m.progress * 100).rounded()))%" : ""),
                         shown: m.id == shownID)
        }
        if items != marks { marks = items }
        let rect = bookmarkShowing
            ? CGRect(x: Self.padH, y: 0, width: max(0, webView.bounds.width - 2 * Self.padH), height: webView.bounds.height) : nil
        if rect != ribbon { withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { ribbon = rect } }
    }

    // MARK: Turning pages

    override func next() {
        guard let book else { return }
        if page < pageCount - 1 { show(page: page + 1, forward: true) }
        else if chapter < book.chapters.count - 1 { load(chapter + 1, .start) }
        else { NSSound.beep() }
    }

    override func previous() {
        if page > 0 { show(page: page - 1, forward: false) }
        else if chapter > 0 { load(chapter - 1, .end) }
        else { NSSound.beep() }
    }

    override func first() { if chapter != 0 { load(0, .start) } else { show(page: 0, forward: false) } }
    override func last() {
        guard let book else { return }
        if chapter != book.chapters.count - 1 { load(book.chapters.count - 1, .end) } else { show(page: pageCount - 1, forward: true) }
    }

    override func goToSlider(_ value: Double) {
        guard let book else { return }
        let i = min(max(0, Int(value.rounded()) - 1), book.chapters.count - 1)
        if i != chapter { load(i, .start) }
    }

    override func sliderLabel(_ value: Double) -> String {
        guard let book else { return "" }
        let i = min(max(0, Int(value.rounded()) - 1), book.chapters.count - 1)
        return "\(book.titles[i]) · \(i + 1) of \(book.chapters.count)"
    }

    // MARK: Bookmark

    /// ⌘D: bookmark this page, or take its bookmark away.
    override func bookmarkHere() {
        guard let book else { return }
        if let here = markHere {
            bookmarks.removeAll { $0.id == here.id }
            let wasShown = here.id == shownID
            if wasShown { shownID = nil }
            saveMarks()
            sync()
            Toast.show(wasShown ? "Bookmark removed — Brake now opens at the start of the book" : "Bookmark removed")
            return
        }
        let p = pageCount > 1 ? (Double(page) / Double(pageCount) * 1000).rounded() / 1000 : 0
        let m = BrakeBookmark(chapter: chapter + 1, progress: p)
        bookmarks.append(m)
        saveMarks()
        sync()
        Toast.show("Bookmarked: \(book.titles[chapter]) — click the pin (⇧⌘D) to have Brake open here")
    }

    /// ⇧⌘D: the bookmark on this page becomes the one Brake opens at; the old one stays an ordinary bookmark.
    override func showHere() {
        guard let here = markHere, here.id != shownID else { return }
        shownID = here.id
        saveMarks()
        sync()
        Toast.show("Brake now opens here: \(book?.titles[chapter] ?? "")")
    }

    private func saveMarks() {
        let marks = bookmarks, shown = shownID
        saveSource { $0.bookmarks = marks; $0.shownBookmark = shown }
    }

    override func goToBookmark() {
        let h = home
        go(chapter: h.chapter, progress: h.progress)
    }

    override func goTo(mark id: String) {
        guard let m = bookmarks.first(where: { $0.id == id }) else { return }
        go(chapter: index(m), progress: m.progress)
    }

    private func go(chapter c: Int, progress: Double) {
        if c == chapter { let t = pageFor(progress: progress); show(page: t, forward: t > page) }
        else { load(c, .progress(progress)) }
    }

    // MARK: Text

    override func textSize(_ step: Int) {
        fontSize = step == 0 ? 20 : min(48, max(10, fontSize + step * 2))
        let s = fontSize
        save { $0.fontSize = s }
        restyle()
    }

    override func setFont(_ name: String) {
        fontName = name
        save { $0.font = name }
        restyle()
    }

    // MARK: Highlights

    override func highlightSelection(_ color: HighlightColor) {
        let c = chapter
        webView.evaluateJavaScript("brake.highlight(...\(json([color.css])))") { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let self, let r = result as? [String: Any], let id = r["id"] as? String,
                      let start = r["start"] as? Int, let end = r["end"] as? Int else { return }
                if self.store.inChapter(c).contains(where: { $0.start == start && $0.end == end }) { self.hasSelection = false; return }
                self.store.add(EpubHighlight(id: id, chapter: c, start: start, end: end, color: color, text: r["text"] as? String ?? ""))
                self.hasSelection = false
            }
        }
    }

    func handle(_ body: Any) {
        guard let m = body as? [String: Any], let type = m["type"] as? String else { return }
        switch type {
        case "selection": hasSelection = m["has"] as? Bool ?? false
        case "layout": laidOut(m)
        case "tapHighlight":
            guard let id = m["id"] as? String else { return }
            let menu = NSMenu()
            menu.addItem(ClosureMenuItem("Remove Highlight", symbol: "xmark.circle") { [weak self] in
                self?.store.remove(id)
                self?.webView.evaluateJavaScript("brake.unhighlight(...\(self?.json([id]) ?? "[]"))")
            })
            menu.addItem(.separator())
            for c in HighlightColor.allCases {
                let item = ClosureMenuItem("Make \(c.title)") { [weak self] in
                    self?.store.recolor(id, c)
                    self?.webView.evaluateJavaScript("brake.recolor(...\(self?.json([id, c.css]) ?? "[]"))")
                }
                item.image = c.swatch
                menu.addItem(item)
            }
            let point = webView.convert(webView.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
            menu.popUp(positioning: nil, at: point, in: webView)
        default: break
        }
    }

    // MARK: Page script

    /// Lays the chapter out in columns one window wide, turns pages by scrolling sideways, and
    /// keeps highlights as character offsets into the chapter's text.
    private static let script = #"""
    (function () {
      const post = (m) => window.webkit.messageHandlers.brake.postMessage(m);
      const root = () => document.scrollingElement || document.documentElement;
      let opts = window.__brakeOpts, page = 0;
      const style = document.createElement('style');
      (document.head || document.documentElement).appendChild(style);
      document.documentElement.style.visibility = 'hidden';

      function css(o) {
        const font = o.font ? `font-family:${o.font} !important;` : '';
        return `
          html { background:${o.bg} !important; height:100vh !important; overflow:hidden !important; margin:0 !important; padding:0 !important; }
          body { box-sizing:border-box !important; margin:0 !important; height:100vh !important; max-width:none !important; width:auto !important;
                 padding:${o.padV}px ${o.padH}px !important; column-count:${o.columns} !important; column-gap:${2 * o.padH}px !important;
                 column-width:calc((100vw - ${2 * o.columns * o.padH}px) / ${o.columns}) !important;
                 column-fill:auto !important; overflow:visible !important; background:transparent !important; color:${o.fg} !important;
                 font-size:${o.size}px !important; line-height:1.55 !important; ${font} -webkit-hyphens:auto; hyphens:auto; }
          body p, body li, body blockquote, body span, body div, body a, body em, body strong, body i, body b, body td, body dd, body dt, body small, body sup, body sub
            { font-size:inherit !important; line-height:inherit !important; }
          ${o.font ? 'body *:not(code):not(pre):not(kbd) { font-family:inherit !important; }' : ''}
          ${o.dark ? 'body * { color:inherit !important; background-color:transparent !important; border-color:#555 !important; }' : ''}
          body a { color:inherit !important; text-decoration-color:rgba(127,127,127,.5) !important; }
          img, svg, video { max-width:100% !important; max-height:calc(100vh - ${2 * o.padV}px) !important; object-fit:contain; break-inside:avoid; }
          h1, h2, h3, h4, h5, h6 { break-after:avoid; }
          mark.brake-hl { color:inherit !important; border-radius:2px; padding:0; cursor:pointer; }
        `;
      }
      function count() { return Math.max(1, Math.ceil((root().scrollWidth - 4) / window.innerWidth)); }
      function go(i) { page = Math.max(0, Math.min(count() - 1, i)); root().scrollLeft = page * window.innerWidth; document.documentElement.style.visibility = 'visible'; }
      function relayout(o) {
        const frac = count() > 1 ? page / count() : 0;
        if (o) { opts = Object.assign(opts, o); style.textContent = css(opts); }
        const n = count();
        go(Math.min(n - 1, Math.round(frac * n)));
        return { page, count: n };
      }

      function textNodes() {
        const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT), a = [];
        let n; while ((n = w.nextNode())) a.push(n);
        return a;
      }
      function offset(node, off) {
        const r = document.createRange(); r.setStart(document.body, 0); r.setEnd(node, off);
        return r.toString().length;
      }
      function wrap(start, end, id, color) {
        let pos = 0;
        for (const n of textNodes()) {
          const len = n.data.length, s = Math.max(start, pos), e = Math.min(end, pos + len);
          if (s < e && n.parentNode && !/^(script|style)$/i.test(n.parentNode.nodeName) && n.data.slice(s - pos, e - pos).trim() !== '') {
            let t = n;
            if (s > pos) t = t.splitText(s - pos);
            if (e < pos + len) t.splitText(e - s);
            const m = document.createElement('mark');
            m.className = 'brake-hl'; m.dataset.id = id; paint(m, color);
            t.parentNode.insertBefore(m, t); m.appendChild(t);
          }
          pos += len;
          if (pos >= end) break;
        }
      }
      // Important and inline, so the book's CSS (and the dark-mode reset, which clears every background) can't hide it.
      function paint(m, color) { m.style.setProperty('background-color', color, 'important'); }
      function marks(id) { return document.querySelectorAll(`mark.brake-hl[data-id="${CSS.escape(id)}"]`); }

      window.brake = {
        async ready() {
          style.textContent = css(opts);
          (opts.highlights || []).forEach(h => wrap(h.start, h.end, h.id, h.color));
          const imgs = [...document.images].filter(i => !i.complete).map(i => new Promise(r => { i.onload = i.onerror = r; }));
          await Promise.race([Promise.all([document.fonts.ready, ...imgs]), new Promise(r => setTimeout(r, 1500))]);
          // Not requestAnimationFrame: WebKit doesn't run it while the view is still hidden.
          await new Promise(r => setTimeout(r, 40));
          return count();
        },
        go,
        restyle: relayout,
        pageOf(id) {
          const el = document.getElementById(id) || document.getElementsByName(id)[0];
          if (!el) return 0;
          const x = el.getBoundingClientRect().left + root().scrollLeft;
          return Math.max(0, Math.min(count() - 1, Math.floor(x / window.innerWidth)));
        },
        highlight(color) {
          const sel = window.getSelection();
          if (!sel || sel.isCollapsed || !sel.rangeCount) return null;
          const r = sel.getRangeAt(0);
          const start = offset(r.startContainer, r.startOffset), end = offset(r.endContainer, r.endOffset);
          if (end <= start) return null;
          const id = Date.now().toString(36) + Math.random().toString(36).slice(2, 6);
          const text = r.toString();
          wrap(start, end, id, color);
          sel.removeAllRanges();
          return { id, start, end, text };
        },
        unhighlight(id) {
          marks(id).forEach(m => { const p = m.parentNode; while (m.firstChild) p.insertBefore(m.firstChild, m); p.removeChild(m); p.normalize(); });
        },
        recolor(id, color) { marks(id).forEach(m => paint(m, color)); },
      };

      document.addEventListener('selectionchange', () => {
        const s = window.getSelection();
        post({ type: 'selection', has: !!s && !s.isCollapsed && s.toString().trim() !== '' });
      });
      document.addEventListener('click', (e) => {
        const m = e.target.closest && e.target.closest('mark.brake-hl');
        const s = window.getSelection();
        if (m && (!s || s.isCollapsed)) post({ type: 'tapHighlight', id: m.dataset.id });
      });
      // Sideways scrolling is ours (page turns); keep the page where we put it.
      window.addEventListener('scroll', () => { const x = page * window.innerWidth; if (root().scrollLeft !== x) root().scrollLeft = x; });
      let timer;
      window.addEventListener('resize', () => {
        clearTimeout(timer);
        timer = setTimeout(() => { const r = relayout(); post({ type: 'layout', page: r.page, count: r.count }); }, 60);
      });
    })();
    """#
}

/// WKWebView with highlight items in its right-click menu.
final class BrakeWebView: WKWebView {
    weak var controller: EpubBookController?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        MainActor.assumeIsolated {
            guard let controller, controller.hasSelection else { return }
            let items = HighlightColor.menuItems { [weak controller] c in controller?.highlightSelection(c) } + [.separator()]
            for (i, item) in items.enumerated() { menu.insertItem(item, at: i) }
        }
    }
}

/// The web view's navigation delegate, kept apart because the controller isn't an NSObject.
private final class EpubNavigation: NSObject, WKNavigationDelegate {
    private weak var target: EpubBookController?
    init(_ target: EpubBookController) { self.target = target }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { target?.finished() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { target?.failed(error) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { target?.failed(error) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        MainActor.assumeIsolated { decisionHandler(target?.allows(action) ?? true ? .allow : .cancel) }
    }
}

/// WKUserContentController retains its handlers; this avoids a retain cycle with the controller.
private final class EpubMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: EpubBookController?
    init(_ target: EpubBookController) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        MainActor.assumeIsolated { target?.handle(body) }
    }
}
