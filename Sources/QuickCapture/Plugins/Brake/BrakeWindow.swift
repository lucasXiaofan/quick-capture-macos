import AVKit
import AppKit
import SwiftUI

/// The views and player for one showing of the Brake window. Built fresh each time, so it always
/// starts at the bookmark.
@MainActor
final class BrakeSession: ObservableObject {
    let settings: BrakeSettings
    let medium: BrakeMedium?
    let missingFile: URL?
    private weak var plugin: BrakePlugin?

    /// A PDF or EPUB.
    private(set) var book: BookController?
    private(set) var playerView: AVPlayerView?
    private(set) var image: NSImage?
    private var player: AVPlayer?
    @Published var bookmarkedSeconds: Double

    init(settings: BrakeSettings, plugin: BrakePlugin) {
        self.settings = settings
        self.plugin = plugin
        bookmarkedSeconds = settings.startSeconds
        let url = settings.fileURL
        if let url, !FileManager.default.fileExists(atPath: url.path) {
            missingFile = url
            medium = nil
            return
        }
        missingFile = nil
        medium = url.flatMap(BrakeMedium.init)
        guard let url, let medium else { return }
        switch medium {
        case .pdf:
            if let b = BrakeBook(url: url) { book = PDFBookController(book: b, settings: settings, plugin: plugin) }
        case .epub:
            book = EpubBookController(url: url, settings: settings, plugin: plugin)
        case .video, .audio:
            let player = AVPlayer(url: url)
            let view = AVPlayerView()
            view.player = player
            view.controlsStyle = .floating
            view.showsFullScreenToggleButton = medium == .video
            self.player = player
            playerView = view
        case .image:
            image = NSImage(contentsOf: url)
        }
    }

    /// Called once the window is on screen, so views have a size to lay out in.
    func start() {
        book?.start()
        if let player {
            let start = CMTime(seconds: settings.startSeconds, preferredTimescale: 600)
            player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor in if self?.settings.autoplay == true { self?.player?.play() } }
            }
        }
    }

    func stop() {
        book?.stop()
        player?.pause()
        player = nil
        playerView?.player = nil
    }

    var currentSeconds: Double {
        guard let t = player?.currentTime().seconds, t.isFinite else { return settings.startSeconds }
        return max(0, t)
    }

    func startHere() {
        let t = (currentSeconds * 10).rounded() / 10
        do {
            try plugin?.update { $0.startSeconds = t }
            bookmarkedSeconds = t
            Toast.show("Brake now starts at \(Self.clock(t))")
        } catch { Toast.show(error.localizedDescription) }
    }

    nonisolated static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// A comfortable window size for the medium, kept inside the screen. A book opens as an open
    /// two-page spread when the screen is wide enough.
    func preferredSize(on screen: NSScreen?) -> NSSize {
        let visible = screen?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let want: NSSize
        switch medium {
        case .pdf:
            let height = visible.height * 0.88
            let chrome: CGFloat = settings.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 120 : 150
            let b = (book as? PDFBookController)?.book
            let pageWidth = (height - chrome) * (b?.aspect(settings.page) ?? 0.7)
            let spreadWidth = pageWidth * 2 + 40
            want = NSSize(width: spreadWidth <= visible.width * 0.92 && (b?.pageCount ?? 0) > 1 ? spreadWidth : pageWidth + 40,
                          height: height)
        case .epub: want = NSSize(width: min(1240, visible.width * 0.85), height: visible.height * 0.88)
        case .video: want = NSSize(width: 960, height: 620)
        case .audio: want = NSSize(width: 560, height: 220)
        case .image:
            let size = image?.size ?? NSSize(width: 800, height: 600)
            let scale = min(1, min(visible.width * 0.8 / max(size.width, 1), visible.height * 0.75 / max(size.height, 1)))
            want = NSSize(width: max(420, size.width * scale), height: size.height * scale + 120)
        case nil: want = NSSize(width: 640, height: missingFile == nil ? 300 : 340)
        }
        return NSSize(width: min(want.width, visible.width * 0.95), height: min(want.height, visible.height * 0.95))
    }
}

/// An ordinary window (see `AppWindows`): opens in front on the current Space, but other windows can go
/// over it. Esc closes it. For a book, ← → (also space, Page Up/Down and a two-finger swipe) turn pages
/// and ⌘D bookmarks.
final class BrakeWindow: NSWindow {
    var onClose: (() -> Void)?
    private let session: BrakeSession
    private var swipe: CGFloat = 0
    private var swipeFired = false

    @MainActor init(session: BrakeSession) {
        self.session = session
        let screen = OverlayPanel.screenUnderMouse
        let size = session.preferredSize(on: screen)
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        title = session.book?.title ?? "Brake"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        collectionBehavior = [.moveToActiveSpace]
        minSize = NSSize(width: 380, height: 200)
        contentView = NSHostingView(rootView: BrakeView(session: session) { [weak self] in self?.close() })
        if let frame = screen?.visibleFrame {
            setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
        } else {
            center()
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) { close() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close() } else { super.keyDown(with: event) }
    }

    /// Book keys are caught before SwiftUI and the page view, so they can't swallow the arrows.
    @MainActor override func sendEvent(_ event: NSEvent) {
        if let book = session.book {
            if event.type == .keyDown, handleBookKey(event, book) { return }
            if event.type == .scrollWheel, handleSwipe(event, book) { return }
        }
        super.sendEvent(event)
    }

    @MainActor private func handleBookKey(_ event: NSEvent, _ book: BookController) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if mods == .command {
            switch key {
            case "d": book.bookmarkHere()
            case "=", "+": book.textSize(1)
            case "-": book.textSize(-1)
            case "0": book.textSize(0)
            default: return false
            }
            return true
        }
        if mods == [.command, .control], key == "h" {
            book.highlightSelection(.yellow)
            return true
        }
        if mods == .shift, event.keyCode == 49 { book.previous(); return true }
        guard mods.isEmpty else { return false }
        // A zoomed-in PDF page scrolls up and down; everything else turns pages.
        if book.swipePans, [125, 126, 49].contains(event.keyCode) { return false }
        switch event.keyCode {
        case 124, 125, 121, 49: book.next()       // → ↓ Page Down space
        case 123, 126, 116: book.previous()       // ← ↑ Page Up
        case 115: book.first()                    // Home
        case 119: book.last()                     // End
        default: return false
        }
        return true
    }

    /// A sideways two-finger swipe turns one page per gesture.
    @MainActor private func handleSwipe(_ event: NSEvent, _ book: BookController) -> Bool {
        guard event.hasPreciseScrollingDeltas, !book.swipePans else { return false }
        if event.momentumPhase != [] { return swipeFired }
        if event.phase == .began { swipe = 0; swipeFired = false }
        // Mostly vertical and not yet a swipe: leave it alone.
        if swipe == 0, abs(event.scrollingDeltaX) <= abs(event.scrollingDeltaY) { return false }
        swipe += event.scrollingDeltaX
        if !swipeFired, abs(swipe) > 40 {
            swipeFired = true
            swipe < 0 ? book.next() : book.previous()
        }
        return true
    }

    override func close() {
        let handler = onClose
        onClose = nil
        super.close()
        handler?()
    }
}

private struct BrakeView: View {
    @ObservedObject var session: BrakeSession
    let close: () -> Void

    private var line: String { session.settings.text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        if let book = session.book {
            BookReader(book: book, line: line, close: close)
        } else {
            other
        }
    }

    private var other: some View {
        VStack(spacing: 0) {
            if session.medium == nil {
                Spacer()
                if !line.isEmpty {
                    Text(line)
                        .font(.system(size: 28, weight: .semibold, design: .serif))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 36)
                }
                if let missing = session.missingFile {
                    Text("Can't find \(missing.path)")
                        .font(.caption).foregroundStyle(.red).padding(.top, 14)
                }
                Spacer()
            } else {
                if !line.isEmpty {
                    Text(line)
                        .font(.system(size: 17, weight: .semibold, design: .serif))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 20).padding(.top, 30).padding(.bottom, 10)
                } else {
                    Color.clear.frame(height: 28)
                }
                Divider()
                medium
            }
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea()
    }

    @ViewBuilder private var medium: some View {
        if let player = session.playerView {
            Hosted(view: player)
        } else if let image = session.image {
            Image(nsImage: image).resizable().scaledToFit().padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text("Couldn't open this file.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if session.medium == .video || session.medium == .audio {
                Text("Starts at \(BrakeSession.clock(session.bookmarkedSeconds))").monospacedDigit().foregroundStyle(.secondary)
                Button("Start Here Next Time") { session.startHere() }
            }
            Spacer()
            Button("Close") { close() }.keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }
}

/// A PDF or EPUB shown like Apple Books: paper backdrop, one page or an open two-page spread
/// depending on the window's shape, a red ribbon on the bookmarked page, highlight and text-size
/// controls, and a scrubber.
private struct BookReader: View {
    @ObservedObject var book: BookController
    let line: String
    let close: () -> Void
    @State private var hovering = false
    @State private var scrub: Double?
    @State private var showText = false

    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { geo in pages(in: geo.size) }
                .padding(book.contentPadding)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Paper.color)
        .ignoresSafeArea()
        .onHover { hovering = $0 }
    }

    private var header: some View {
        VStack(spacing: 6) {
            ZStack {
                Text(book.title.uppercased())
                    .font(.system(size: 11, weight: .medium)).kerning(1.2)
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, 150)
                HStack(spacing: 4) {
                    Spacer()
                    highlightMenu
                    textButton
                    Button { book.bookmarkHere() } label: {
                        Image(systemName: book.bookmarkShowing ? "bookmark.fill" : "bookmark")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(book.bookmarkShowing ? Color(red: 0.82, green: 0.16, blue: 0.15) : .secondary)
                            .frame(width: 30, height: 24).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(book.bookmarkShowing ? "Brake opens here" : "Bookmark this page — Brake opens here next time (⌘D)")
                }
                .padding(.trailing, 12)
            }
            .frame(height: 28)
            .padding(.top, 2)
            if !line.isEmpty {
                Text(line)
                    .font(.system(size: 16, weight: .semibold, design: .serif))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        }
        .padding(.bottom, 4)
    }

    private var highlightMenu: some View {
        Menu {
            ForEach(HighlightColor.allCases, id: \.self) { c in
                Button { book.highlightSelection(c) } label: { Label { Text(c.title) } icon: { Image(nsImage: c.swatch) } }
            }
        } label: {
            Image(systemName: "highlighter")
        } primaryAction: {
            book.highlightSelection(.yellow)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 30, height: 24)
        .disabled(!book.hasSelection)
        .opacity(book.hasSelection ? 1 : 0.35)
        .help("Highlight the selected text (⌃⌘H) — select text first. Right-click a highlight to change or remove it.")
    }

    private var textButton: some View {
        Button { showText.toggle() } label: {
            Text("Aa").font(.system(size: 15, weight: .medium, design: .serif)).foregroundStyle(.secondary)
                .frame(width: 30, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(book.isEPUB ? "Font and text size (⌘+ / ⌘−)" : "Zoom (⌘+ / ⌘− / ⌘0, or pinch)")
        .popover(isPresented: $showText, arrowEdge: .bottom) { TextOptions(book: book) }
    }

    private func pages(in size: CGSize) -> some View {
        let twoUp = book.wantsTwoUp(in: size)
        return ZStack(alignment: .topLeading) {
            Hosted(view: book.contentView)
            if let r = book.ribbon {
                BookmarkRibbon(width: 20)
                    .offset(x: r.maxX - 20 * 1.9, y: max(0, r.minY) - 3)
                    .allowsHitTesting(false)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if let message = book.message {
                Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(30)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                chevron("chevron.left", enabled: book.canGoBack) { book.previous() }
                Spacer()
                chevron("chevron.right", enabled: book.canGoForward) { book.next() }
            }
            .frame(maxHeight: .infinity)
        }
        .clipped()
        .onAppear { book.setTwoUp(twoUp) }
        .onChange(of: twoUp) { book.setTwoUp($0) }
    }

    private func chevron(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 26, height: 70).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(hovering && enabled ? 0.8 : 0)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .disabled(!enabled)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button { book.goToBookmark() } label: {
                Label("Back to Bookmark", systemImage: "bookmark.fill")
            }
            .buttonStyle(.borderless)
            .opacity(book.bookmarkShowing || book.message != nil ? 0 : 1)
            .disabled(book.bookmarkShowing || book.message != nil)
            if book.sliderRange.upperBound > book.sliderRange.lowerBound {
                Slider(value: Binding(get: { scrub ?? book.sliderValue }, set: { scrub = $0 }), in: book.sliderRange) { editing in
                    if !editing, let s = scrub {
                        book.goToSlider(s)
                        scrub = nil
                    }
                }
                .controlSize(.small)
            } else {
                Spacer()
            }
            Text(scrub.map(book.sliderLabel) ?? book.positionLabel)
                .font(.callout).monospacedDigit().foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .frame(minWidth: 130, maxWidth: 300, alignment: .trailing)
            Button("Close") { close() }.keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 12)
    }
}

/// The "Aa" popover: font and size for an EPUB, zoom for a PDF.
private struct TextOptions: View {
    @ObservedObject var book: BookController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let epub = book as? EpubBookController {
                HStack(spacing: 0) {
                    Button { book.textSize(-1) } label: { Text("A").font(.system(size: 13, design: .serif)).frame(maxWidth: .infinity, minHeight: 30) }
                    Divider().frame(height: 22)
                    Button { book.textSize(1) } label: { Text("A").font(.system(size: 21, design: .serif)).frame(maxWidth: .infinity, minHeight: 30) }
                }
                .buttonStyle(.plain)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.07)))
                Text("\(epub.fontSize) pt").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Divider()
                ForEach(BrakeFont.all) { f in
                    Button { book.setFont(f.name); book.objectWillChange.send() } label: {
                        HStack {
                            Text(f.name).font(f.swiftUI(size: 15))
                            Spacer()
                            if epub.fontName == f.name { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } else if let pdf = book as? PDFBookController {
                HStack(spacing: 10) {
                    Button { book.textSize(-1); book.objectWillChange.send() } label: { Image(systemName: "minus.magnifyingglass") }
                    Text("\(pdf.zoomPercent)%").monospacedDigit().frame(minWidth: 48)
                    Button { book.textSize(1); book.objectWillChange.send() } label: { Image(systemName: "plus.magnifyingglass") }
                    Button("Fit") { book.textSize(0); book.objectWillChange.send() }
                }
                Text("PDF text is fixed, so zoom to make it bigger. Pinch works too.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 230)
    }
}

/// Puts an existing AppKit view into SwiftUI (the session owns it, so it survives re-renders).
private struct Hosted: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
