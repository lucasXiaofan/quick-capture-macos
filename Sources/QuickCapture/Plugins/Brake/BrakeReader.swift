import AppKit
import PDFKit
import SwiftUI

/// Highlight colours, as in Apple Books.
enum HighlightColor: String, CaseIterable, Codable {
    case yellow, green, blue, pink, purple

    var title: String { rawValue.capitalized }

    var nsColor: NSColor {
        switch self {
        case .yellow: return NSColor(calibratedRed: 1.00, green: 0.86, blue: 0.25, alpha: 1)
        case .green: return NSColor(calibratedRed: 0.56, green: 0.86, blue: 0.45, alpha: 1)
        case .blue: return NSColor(calibratedRed: 0.52, green: 0.76, blue: 1.00, alpha: 1)
        case .pink: return NSColor(calibratedRed: 1.00, green: 0.57, blue: 0.72, alpha: 1)
        case .purple: return NSColor(calibratedRed: 0.76, green: 0.62, blue: 1.00, alpha: 1)
        }
    }

    /// For the web reader: translucent, so the text stays readable in dark mode too.
    var css: String {
        let c = nsColor.usingColorSpace(.sRGB) ?? nsColor
        return String(format: "rgba(%d,%d,%d,0.45)", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }

    var swatch: NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
            self.nsColor.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
    }

    /// "Highlight" items for a context menu.
    static func menuItems(_ apply: @escaping (HighlightColor) -> Void) -> [NSMenuItem] {
        allCases.map { c in
            let item = ClosureMenuItem("Highlight \(c.title)") { apply(c) }
            item.image = c.swatch
            return item
        }
    }
}

/// Fonts offered for EPUB text. `css` nil keeps the book's own.
struct BrakeFont: Identifiable {
    let name: String
    let css: String?
    var id: String { name }

    static let all: [BrakeFont] = [
        BrakeFont(name: "Original", css: nil),
        BrakeFont(name: "Iowan Old Style", css: "'Iowan Old Style', 'Palatino', serif"),
        BrakeFont(name: "New York", css: "ui-serif, Georgia, serif"),
        BrakeFont(name: "Georgia", css: "Georgia, serif"),
        BrakeFont(name: "Palatino", css: "Palatino, 'Palatino Linotype', serif"),
        BrakeFont(name: "Charter", css: "Charter, Georgia, serif"),
        BrakeFont(name: "San Francisco", css: "system-ui, -apple-system, sans-serif"),
        BrakeFont(name: "Avenir Next", css: "'Avenir Next', 'Helvetica Neue', sans-serif"),
    ]

    static func named(_ name: String) -> BrakeFont { all.first { $0.name == name } ?? all[1] }

    /// The same face in SwiftUI, for the Settings preview.
    func swiftUI(size: CGFloat) -> Font {
        switch name {
        case "Original", "New York": return .system(size: size, design: .serif)
        case "San Francisco": return .system(size: size)
        default: return .custom(name, size: size)
        }
    }
}

/// The paper the pages sit on and the ink for reflowed text, as in Apple Books.
enum Paper {
    static var isDark: Bool { NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    static let nsColor = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.13, alpha: 1)
            : NSColor(calibratedRed: 0.95, green: 0.94, blue: 0.91, alpha: 1)
    }
    static let color = Color(nsColor: nsColor)
    static var cssBackground: String { isDark ? "#1f1f21" : "#f2efe8" }
    static var cssInk: String { isDark ? "#dcdad5" : "#1d1d1f" }
}

/// What the Brake window needs from a book, PDF or EPUB: one view to show, page turning, the
/// bookmark, highlights and text size. Subclasses fill in the published state.
@MainActor
class BookController: ObservableObject {
    weak var plugin: BrakePlugin?

    @Published var title = ""
    @Published var positionLabel = ""
    @Published var sliderValue = 1.0
    @Published var sliderRange: ClosedRange<Double> = 1...1
    @Published var bookmarkShowing = false
    /// Where the bookmarked page is inside `contentView` (top-left origin); nil when it isn't showing.
    @Published var ribbon: CGRect?
    @Published var hasSelection = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    /// Shown in place of the pages while loading, or when the book can't be opened.
    @Published var message: String?

    var contentView: NSView { NSView() }
    /// Space between the window edge and `contentView`.
    var contentPadding: CGFloat { 0 }
    /// True when a sideways swipe should pan the page rather than turn it.
    var swipePans: Bool { false }
    var isEPUB: Bool { false }

    init(plugin: BrakePlugin?) { self.plugin = plugin }

    func start() {}
    func stop() {}
    func wantsTwoUp(in size: CGSize) -> Bool { false }
    func setTwoUp(_ twoUp: Bool) {}
    func next() {}
    func previous() {}
    func first() {}
    func last() {}
    func goToSlider(_ value: Double) {}
    func sliderLabel(_ value: Double) -> String { "" }
    func bookmarkHere() {}
    func goToBookmark() {}
    func highlightSelection(_ color: HighlightColor) {}
    /// +1 bigger, -1 smaller, 0 back to the default.
    func textSize(_ step: Int) {}
    func setFont(_ name: String) {}

    func save(_ change: @escaping (inout BrakeSettings) -> Void) {
        do { try plugin?.update(change) } catch { Toast.show(error.localizedDescription) }
    }

    /// Slides the view sideways, like turning a page.
    static func pushTransition(on view: NSView, forward: Bool) {
        view.wantsLayer = true
        let t = CATransition()
        t.type = .push
        t.subtype = forward ? .fromRight : .fromLeft
        t.duration = 0.24
        t.timingFunction = CAMediaTimingFunction(name: .easeOut)
        view.layer?.add(t, forKey: "turn")
    }
}

// MARK: - PDF

/// A PDF in PDFKit: pinch or ⌘+/⌘− to zoom, select text, highlights saved into the PDF itself.
@MainActor
final class PDFBookController: BookController {
    let book: BrakeBook
    let pdfView = BrakePDFView()
    private var twoUp = false
    private var page = 1
    private var bookmarkedPage: Int
    private var zoom: Double
    private var observers: [NSObjectProtocol] = []
    private var turning = false
    /// Until the window is up, the view's current page is just the first one; don't believe it.
    private var started = false
    private var saveWork: DispatchWorkItem?

    override var contentView: NSView { pdfView }
    override var contentPadding: CGFloat { 14 }
    override var swipePans: Bool { pdfView.scaleFactor > pdfView.scaleFactorForSizeToFit * 1.02 }

    init(book: BrakeBook, settings: BrakeSettings, plugin: BrakePlugin) {
        self.book = book
        page = book.clamp(settings.page)
        bookmarkedPage = page
        zoom = settings.pdfZoom
        super.init(plugin: plugin)
        title = book.title
        sliderRange = 1...Double(max(2, book.pageCount))
        pdfView.controller = self
        pdfView.document = book.document
        pdfView.displayMode = .singlePage
        pdfView.displaysAsBook = true
        pdfView.displaysPageBreaks = true
        pdfView.pageBreakMargins = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        pdfView.backgroundColor = Paper.nsColor
        pdfView.autoScales = true
        let nc = NotificationCenter.default
        for name in [Notification.Name.PDFViewPageChanged, .PDFViewScaleChanged, .PDFViewDisplayModeChanged] {
            observers.append(nc.addObserver(forName: name, object: pdfView, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.sync() }
            })
        }
        observers.append(nc.addObserver(forName: .PDFViewSelectionChanged, object: pdfView, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.hasSelection = !(self.pdfView.currentSelection?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        })
        pdfView.postsFrameChangedNotifications = true
        observers.append(nc.addObserver(forName: NSView.frameDidChangeNotification, object: pdfView, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.applyZoom(); self?.updateRibbon() }
        })
        sync()
    }

    override func start() {
        started = true
        if let clip = pdfView.documentView?.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) {
                [weak self] _ in Task { @MainActor in self?.updateRibbon() }
            })
        }
        jump(to: page)
        // PDFView settles its scale after the first layout; jump again once it has.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.applyZoom()
            self.jump(to: self.page)
        }
    }

    override func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if saveWork != nil { saveWork?.cancel(); writePDF() }
    }

    // MARK: Pages

    override func wantsTwoUp(in size: CGSize) -> Bool {
        book.pageCount > 1 && size.width > size.height * book.aspect(page) * 1.55
    }

    override func setTwoUp(_ t: Bool) {
        guard t != twoUp || pdfView.displayMode != (t ? .twoUp : .singlePage) else { return }
        twoUp = t
        let keep = page
        pdfView.displayMode = t ? .twoUp : .singlePage
        applyZoom()
        jump(to: keep)
    }

    private func jump(to p: Int) {
        guard let target = book.document.page(at: book.clamp(p) - 1) else { return }
        pdfView.go(to: target)
        page = book.spreadStart(p, twoUp: twoUp)
        sync()
    }

    private func turn(to n: Int) {
        guard let target = book.document.page(at: book.clamp(n) - 1) else { return }
        turning = true
        ribbon = nil
        Self.pushTransition(on: pdfView, forward: n > page)
        pdfView.go(to: target)
        page = book.spreadStart(n, twoUp: twoUp)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { [weak self] in
            self?.turning = false
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { self?.updateRibbon() }
        }
        sync()
    }

    override func next() {
        guard let n = book.next(page, twoUp: twoUp) else { NSSound.beep(); return }
        turn(to: n)
    }

    override func previous() {
        guard let n = book.previous(page, twoUp: twoUp) else { NSSound.beep(); return }
        turn(to: n)
    }

    override func first() { turn(to: 1) }
    override func last() { turn(to: book.pageCount) }

    override func goToSlider(_ value: Double) {
        let n = book.clamp(Int(value.rounded()))
        if book.spreadStart(n, twoUp: twoUp) != page { turn(to: n) }
    }

    override func sliderLabel(_ value: Double) -> String { "Page \(Int(value.rounded())) of \(book.pageCount)" }

    private func sync() {
        if started, let current = pdfView.currentPage, !turning {
            page = book.spreadStart(book.document.index(for: current) + 1, twoUp: twoUp)
        }
        let spread = book.spread(page, twoUp: twoUp)
        positionLabel = spread.count == 2 ? "Pages \(spread[0])–\(spread[1]) of \(book.pageCount)" : "Page \(page) of \(book.pageCount)"
        sliderValue = Double(page)
        bookmarkShowing = spread.contains(bookmarkedPage)
        canGoBack = book.previous(page, twoUp: twoUp) != nil
        canGoForward = book.next(page, twoUp: twoUp) != nil
        updateRibbon()
    }

    private func updateRibbon() {
        guard !turning, let p = book.document.page(at: bookmarkedPage - 1), pdfView.visiblePages.contains(p) else {
            if ribbon != nil { ribbon = nil }
            return
        }
        let r = pdfView.convert(p.bounds(for: pdfView.displayBox), from: p)
        let y = pdfView.isFlipped ? r.minY : pdfView.bounds.height - r.maxY
        let rect = CGRect(x: r.minX, y: y, width: r.width, height: r.height)
        if ribbon != rect { ribbon = rect }
    }

    // MARK: Bookmark

    override func bookmarkHere() {
        guard !bookmarkShowing else { return }
        let p = page
        save { $0.page = p }
        bookmarkedPage = p
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { sync() }
        Toast.show("Brake now opens at page \(p)")
    }

    override func goToBookmark() { turn(to: bookmarkedPage) }

    // MARK: Zoom

    override func textSize(_ step: Int) {
        zoom = step == 0 ? 1 : min(5, max(0.25, step > 0 ? zoom * 1.2 : zoom / 1.2))
        if abs(zoom - 1) < 0.04 { zoom = 1 }
        applyZoom()
        let z = (zoom * 100).rounded() / 100
        save { $0.pdfZoom = z }
    }

    var zoomPercent: Int { Int((zoom * 100).rounded()) }

    private func applyZoom() {
        if zoom == 1 {
            if !pdfView.autoScales { pdfView.autoScales = true }
        } else {
            pdfView.autoScales = false
            pdfView.scaleFactor = pdfView.scaleFactorForSizeToFit * zoom
        }
    }

    /// Pinch-zooming in the view changes the zoom that's kept for next time.
    func userMagnified() {
        let fit = pdfView.scaleFactorForSizeToFit
        guard fit > 0 else { return }
        zoom = min(5, max(0.25, pdfView.scaleFactor / fit))
        if abs(zoom - 1) < 0.04 { zoom = 1; pdfView.autoScales = true }
        let z = (zoom * 100).rounded() / 100
        save { $0.pdfZoom = z }
    }

    // MARK: Highlights

    override func highlightSelection(_ color: HighlightColor) {
        guard let sel = pdfView.currentSelection, !(sel.string ?? "").isEmpty else { return }
        guard book.document.allowsCommenting else {
            Toast.show("This PDF doesn't allow highlights.")
            return
        }
        for line in sel.selectionsByLine() {
            for p in line.pages {
                let b = line.bounds(for: p)
                guard b.width > 1, b.height > 1 else { continue }
                let a = PDFAnnotation(bounds: b, forType: .highlight, withProperties: nil)
                a.color = color.nsColor
                p.addAnnotation(a)
            }
        }
        pdfView.clearSelection()
        scheduleSave()
    }

    func removeHighlight(_ a: PDFAnnotation) {
        a.page?.removeAnnotation(a)
        scheduleSave()
    }

    func recolor(_ a: PDFAnnotation, _ color: HighlightColor) {
        a.color = color.nsColor
        scheduleSave()
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in Task { @MainActor in self?.saveWork = nil; self?.writePDF() } }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    /// Writes to a scratch copy, then swaps it in, so a failed write never damages the book.
    private func writePDF() {
        saveWork = nil
        let fm = FileManager.default
        do {
            let dir = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: book.url, create: true)
            defer { try? fm.removeItem(at: dir) }
            let tmp = dir.appendingPathComponent(book.url.lastPathComponent)
            guard book.document.write(to: tmp) else { throw AppError("Couldn't save highlights into \(book.url.lastPathComponent).") }
            _ = try fm.replaceItemAt(book.url, withItemAt: tmp)
        } catch {
            Toast.show(error.localizedDescription)
        }
    }
}

/// PDFView with highlight items in its right-click menu and pinch-zoom remembered.
final class BrakePDFView: PDFView {
    weak var controller: PDFBookController?

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard let controller else { return menu }
        var items: [NSMenuItem] = []
        let point = convert(event.locationInWindow, from: nil)
        if let page = page(for: point, nearest: false),
           let a = page.annotation(at: convert(point, to: page)),
           (a.type ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "Highlight" {
            items.append(ClosureMenuItem("Remove Highlight", symbol: "xmark.circle") { [weak controller] in controller?.removeHighlight(a) })
            for c in HighlightColor.allCases {
                let item = ClosureMenuItem("Make \(c.title)") { [weak controller] in controller?.recolor(a, c) }
                item.image = c.swatch
                items.append(item)
            }
        } else if controller.hasSelection {
            items = HighlightColor.menuItems { [weak controller] c in controller?.highlightSelection(c) }
        }
        guard !items.isEmpty else { return menu }
        items.append(.separator())
        for (i, item) in items.enumerated() { menu.insertItem(item, at: i) }
        return menu
    }

    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        if event.phase == .ended || event.phase == .cancelled {
            MainActor.assumeIsolated { controller?.userMagnified() }
        }
    }
}
