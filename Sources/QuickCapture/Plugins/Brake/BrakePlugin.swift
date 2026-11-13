import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// An EPUB bookmark: a chapter (1-based, in reading order) and how far into it (0…1).
struct BrakeBookmark: Codable, Equatable, Identifiable {
    var id = BrakeSettings.newID()
    var chapter = 1
    var progress = 0.0

    init(chapter: Int, progress: Double) {
        self.chapter = chapter
        self.progress = progress
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? BrakeSettings.newID()
        chapter = try c.decodeIfPresent(Int.self, forKey: .chapter) ?? 1
        progress = try c.decodeIfPresent(Double.self, forKey: .progress) ?? 0
    }
}

/// One thing Brake can show — a PDF or EPUB book, video, audio file or image — with its own place to open at.
struct BrakeSource: Codable, Equatable, Identifiable {
    var id = BrakeSettings.newID()
    /// "~" is allowed.
    var path = ""
    /// PDF page to open at (1-based) — the bookmark.
    var page = 1
    /// PDF zoom, relative to fitting the page in the window (1 = fit).
    var pdfZoom = 1.0
    /// Where video or audio starts playing.
    var startSeconds = 0.0
    /// EPUB bookmarks. One of them (`shownBookmark`) is where Brake opens; without one it opens at the start.
    var bookmarks: [BrakeBookmark] = []
    var shownBookmark: String?

    enum CodingKeys: String, CodingKey {
        case id, path, page, bookmarks
        case pdfZoom = "pdf_zoom", startSeconds = "start_seconds", shownBookmark = "shown_bookmark"
    }

    init(path: String) { self.path = path }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? BrakeSettings.newID()
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        page = try c.decodeIfPresent(Int.self, forKey: .page) ?? 1
        pdfZoom = try c.decodeIfPresent(Double.self, forKey: .pdfZoom) ?? 1
        startSeconds = try c.decodeIfPresent(Double.self, forKey: .startSeconds) ?? 0
        bookmarks = try c.decodeIfPresent([BrakeBookmark].self, forKey: .bookmarks) ?? []
        shownBookmark = try c.decodeIfPresent(String.self, forKey: .shownBookmark)
    }

    var fileURL: URL? {
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return p.isEmpty ? nil : URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
    }

    var medium: BrakeMedium? { fileURL.flatMap(BrakeMedium.init) }

    /// The EPUB bookmark Brake opens at, if one is chosen.
    var shown: BrakeBookmark? { bookmarks.first { $0.id == shownBookmark } }
}

struct BrakeSettings: PluginSettings {
    /// Everything Brake can show. `current` (a source id) is the one it shows; no match shows only `text`.
    var sources: [BrakeSource] = []
    var current = ""
    /// EPUB text: a font name from `BrakeFont.all` ("Original" keeps the book's own) and its size in points.
    var font = "Iowan Old Style"
    var fontSize = 20
    /// A line shown above the medium, or on its own when there is no file.
    var text = "Stop. Breathe. Is this what you really want to be doing right now?"
    /// Start video/audio as soon as the window opens.
    var autoplay = true

    enum CodingKeys: String, CodingKey {
        case sources, current, font, text, autoplay
        case fontSize = "font_size"
    }

    /// Before Brake had several sources, one file and its bookmark sat at the top level.
    private enum LegacyKeys: String, CodingKey {
        case path, page, chapter
        case chapterProgress = "chapter_progress", pdfZoom = "pdf_zoom", startSeconds = "start_seconds"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sources = try c.decodeIfPresent([BrakeSource].self, forKey: .sources) ?? []
        current = try c.decodeIfPresent(String.self, forKey: .current) ?? ""
        font = try c.decodeIfPresent(String.self, forKey: .font) ?? "Iowan Old Style"
        fontSize = try c.decodeIfPresent(Int.self, forKey: .fontSize) ?? 20
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? BrakeSettings().text
        autoplay = try c.decodeIfPresent(Bool.self, forKey: .autoplay) ?? true
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        let path = (try? legacy.decodeIfPresent(String.self, forKey: .path)) ?? nil
        if sources.isEmpty, let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var s = BrakeSource(path: path)
            s.id = "legacy"
            s.page = max(1, ((try? legacy.decodeIfPresent(Int.self, forKey: .page)) ?? nil) ?? 1)
            s.pdfZoom = ((try? legacy.decodeIfPresent(Double.self, forKey: .pdfZoom)) ?? nil) ?? 1
            s.startSeconds = ((try? legacy.decodeIfPresent(Double.self, forKey: .startSeconds)) ?? nil) ?? 0
            if s.medium == .epub {
                let chapter = ((try? legacy.decodeIfPresent(Int.self, forKey: .chapter)) ?? nil) ?? 1
                let progress = ((try? legacy.decodeIfPresent(Double.self, forKey: .chapterProgress)) ?? nil) ?? 0
                var mark = BrakeBookmark(chapter: max(1, chapter), progress: min(1, max(0, progress)))
                mark.id = "legacy"
                s.bookmarks = [mark]
                s.shownBookmark = mark.id
            }
            sources = [s]
            current = s.id
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sources, forKey: .sources)
        try c.encode(current, forKey: .current)
        try c.encode(font, forKey: .font)
        try c.encode(fontSize, forKey: .fontSize)
        try c.encode(text, forKey: .text)
        try c.encode(autoplay, forKey: .autoplay)
        // Saving never removes keys from config.json, so blank the old one: it would otherwise come back as a source.
        var legacy = encoder.container(keyedBy: LegacyKeys.self)
        try legacy.encode("", forKey: .path)
    }

    var currentSource: BrakeSource? { sources.first { $0.id == current } }

    static func newID() -> String { String(UUID().uuidString.prefix(8)).lowercased() }
}

enum BrakeMedium: Equatable {
    case pdf, epub, video, audio, image

    init?(_ url: URL) {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return nil }
        if type.conforms(to: .pdf) { self = .pdf }
        else if type.conforms(to: .epub) { self = .epub }
        else if type.conforms(to: .image) { self = .image }
        else if type.conforms(to: .audio) { self = .audio }
        else if type.conforms(to: .movie) || type.conforms(to: .audiovisualContent) { self = .video }
        else { return nil }
    }

    var label: String {
        switch self {
        case .pdf: return "PDF"
        case .epub: return "EPUB"
        case .video: return "Video"
        case .audio: return "Audio"
        case .image: return "Image"
        }
    }
}

/// "Pull back from the brink": one shortcut (or wheel slice) shows the single reminder you picked in
/// advance — a book at a set page, a video or audio clip from a set second, an image, or a line of text.
@MainActor
final class BrakePlugin: ObservableObject, Plugin {
    nonisolated static let pluginID = "brake"

    let id = BrakePlugin.pluginID
    let name = "Brake"
    let summary = "One shortcut shows the reminder you picked in advance: a PDF or EPUB book at a bookmark, a video, audio, image or a line. Keep several and choose which one shows."
    let symbol = "hand.raised.fill"
    var enabledByDefault: Bool { false }
    let actions = [
        PluginAction(id: "show", title: "Show Brake", symbol: "hand.raised.fill", defaultShortcut: nil),
    ]

    private var window: BrakeWindow?

    var settings: BrakeSettings { state.settings(BrakeSettings.self, for: id) }
    func update(_ change: (inout BrakeSettings) -> Void) throws {
        try state.updateSettings(BrakeSettings.self, for: id, change)
    }

    func perform(_ action: PluginAction) {
        guard action.id == "show" else { return }
        show()
    }

    /// Opens fresh every time, so it always starts at the bookmark rather than where you last stopped.
    func show() {
        let s = settings
        if s.currentSource == nil && s.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Toast.show("Brake: add a file or write a line in Settings → Brake.")
            return
        }
        window?.close()
        let session = BrakeSession(settings: s, plugin: self)
        let w = BrakeWindow(session: session)
        w.onClose = { [weak self, weak w] in
            session.stop()
            guard let w else { return }
            if self?.window === w { self?.window = nil }
            // Focus goes back to the app you were in; other Quick Capture windows (the selfie camera…) stay put.
            AppWindows.hidden(w)
        }
        window = w
        AppWindows.show(w)
        session.start()
    }

    /// Makes another source the one Brake shows, and opens it if the window is up.
    func makeCurrent(_ id: String, reopen: Bool = false) {
        do { try update { $0.current = id } } catch { Toast.show(error.localizedDescription); return }
        if reopen { show() }
    }

    func updateSource(_ id: String, _ change: @escaping (inout BrakeSource) -> Void) throws {
        try update { s in
            guard let i = s.sources.firstIndex(where: { $0.id == id }) else { return }
            change(&s.sources[i])
        }
    }

    func deactivate() {
        window?.close()
        window = nil
    }

    func defaultSettings() -> [String: JSONValue] { encodeDefaults(BrakeSettings.self) }

    func validate(_ config: AppConfig) throws {
        let s = try config.settings(BrakeSettings.self, for: id)
        if !(10...48).contains(s.fontSize) { throw AppError("brake.font_size goes from 10 to 48.") }
        for src in s.sources {
            let name = src.fileURL?.lastPathComponent ?? "a source"
            if src.fileURL == nil { throw AppError("brake.sources: every source needs a path.") }
            if src.page < 1 { throw AppError("brake.sources (\(name)): page starts at 1.") }
            if src.startSeconds < 0 { throw AppError("brake.sources (\(name)): start_seconds can't be negative.") }
            if !(0.25...5).contains(src.pdfZoom) { throw AppError("brake.sources (\(name)): pdf_zoom goes from 0.25 to 5.") }
            for m in src.bookmarks {
                if m.chapter < 1 { throw AppError("brake.sources (\(name)): a bookmark's chapter starts at 1.") }
                if !(0...1).contains(m.progress) { throw AppError("brake.sources (\(name)): a bookmark's progress goes from 0 to 1.") }
            }
            if let url = src.fileURL, BrakeMedium(url) == nil {
                throw AppError("brake.sources: “\(url.lastPathComponent)” isn't a PDF, EPUB, video, audio file or image.")
            }
        }
        if Set(s.sources.map(\.id)).count != s.sources.count { throw AppError("brake.sources: two sources share an id.") }
    }

    /// Adds files as new sources. The first one becomes the one shown when nothing is shown yet.
    func addFiles() {
        let panel = NSOpenPanel()
        panel.message = "Add things Brake can show: PDF or EPUB books, videos, audio clips or images."
        panel.prompt = "Add"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.pdf, .epub, .movie, .audiovisualContent, .audio, .image]
        panel.treatsFilePackagesAsDirectories = false
        if let url = settings.currentSource?.fileURL { panel.directoryURL = url.deletingLastPathComponent() }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = panel.urls.map { url in url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path }
        do {
            try update { s in
                var firstAdded: String?
                for path in paths {
                    if let existing = s.sources.first(where: { $0.path == path }) { firstAdded = firstAdded ?? existing.id; continue }
                    let src = BrakeSource(path: path)
                    s.sources.append(src)
                    firstAdded = firstAdded ?? src.id
                }
                if s.currentSource == nil, let firstAdded { s.current = firstAdded }
            }
        } catch {
            Toast.show(error.localizedDescription)
        }
    }

    func removeSource(_ id: String) {
        do {
            try update { s in
                s.sources.removeAll { $0.id == id }
                if s.current == id { s.current = s.sources.first?.id ?? "" }
            }
        } catch { Toast.show(error.localizedDescription) }
    }

    func overviewView() -> AnyView? {
        AnyView(Section { Button("Show Brake Now") { [weak self] in self?.show() } })
    }

    func settingsView() -> AnyView? { AnyView(BrakeSettingsSections(plugin: self, state: state)) }
}

private struct BrakeSettingsSections: View {
    @ObservedObject var plugin: BrakePlugin
    @ObservedObject var state: AppState

    private func set(_ change: @escaping (inout BrakeSettings) -> Void) {
        do { try plugin.update(change) } catch { Toast.show(error.localizedDescription) }
    }

    private func setSource(_ id: String, _ change: @escaping (inout BrakeSource) -> Void) {
        do { try plugin.updateSource(id, change) } catch { Toast.show(error.localizedDescription) }
    }

    var body: some View {
        let s = plugin.settings
        let src = s.currentSource
        let medium = src?.medium
        Section {
            ForEach(s.sources) { source in
                SourceRow(source: source, current: source.id == s.current,
                          choose: { plugin.makeCurrent(source.id) }, remove: { plugin.removeSource(source.id) })
            }
            SourceRow(source: nil, current: src == nil, choose: { plugin.makeCurrent("") }, remove: {})
            HStack {
                Button("Add Files…") { plugin.addFiles() }
                Spacer()
            }
        } header: {
            Text("What to show")
        } footer: {
            Text("Keep as many as you like; the one with the filled circle is what Brake shows. Switch from the Brake window too, with the menu at its top left.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if let src, let url = src.fileURL {
            let exists = FileManager.default.fileExists(atPath: url.path)
            if medium == .video || medium == .audio {
                Section("Playback") {
                    HStack {
                        Text("Start at")
                        TextField("seconds", value: Binding(get: { src.startSeconds }, set: { v in setSource(src.id) { $0.startSeconds = max(0, v) } }),
                                  format: .number)
                            .frame(width: 80)
                        Text("seconds (\(BrakeSession.clock(src.startSeconds)))").foregroundStyle(.secondary)
                    }
                    Toggle("Play as soon as it opens", isOn: Binding(get: { s.autoplay }, set: { v in set { $0.autoplay = v } }))
                }
            }
            if medium == .pdf, exists {
                Section {
                    BrakeBookmarkPicker(url: url, page: src.page) { p in setSource(src.id) { $0.page = p } }.id(url)
                } header: {
                    Text("Bookmark")
                } footer: {
                    Text("In the Brake window: ← → turn pages, the bookmark icon (⌘D) moves the bookmark, select text and click the highlighter (⌃⌘H) to highlight.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Reading") {
                    HStack {
                        Text("Zoom")
                        Spacer()
                        Text(src.pdfZoom == 1 ? "Fit to window" : "\(Int((src.pdfZoom * 100).rounded()))% of fit").foregroundStyle(.secondary)
                        if src.pdfZoom != 1 { Button("Reset") { setSource(src.id) { $0.pdfZoom = 1 } } }
                    }
                    Text("PDF text can't change font; zoom in the Brake window with ⌘+ / ⌘− or a pinch, and Brake keeps it. Highlights are saved into the PDF, so Preview shows them too.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if medium == .epub, exists {
                Section {
                    BrakeEpubBookmarks(url: url, source: src, settings: s) { change in setSource(src.id, change) }.id(url)
                } header: {
                    Text("Bookmarks")
                } footer: {
                    Text("Bookmark pages while you read (the bookmark icon, ⌘D), then make one the bookmark Brake opens at (the pin, ⇧⌘D). Choosing another keeps the old one as an ordinary bookmark.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Reading") {
                    Picker("Font", selection: Binding(get: { s.font }, set: { v in set { $0.font = v } })) {
                        ForEach(BrakeFont.all) { f in Text(f.name).tag(f.name) }
                    }
                    Stepper(value: Binding(get: { s.fontSize }, set: { v in set { $0.fontSize = min(48, max(10, v)) } }), in: 10...48, step: 2) {
                        Text("Text size \(s.fontSize) pt")
                    }
                    Text("Highlights are kept in Brake's data folder (an EPUB isn't rewritten). Change font and size in the window too, with “Aa” or ⌘+ / ⌘−.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        Section("Line") {
            TextField("Shown above the file, or on its own", text: Binding(get: { s.text }, set: { v in set { $0.text = v } }),
                      axis: .vertical)
                .lineLimit(2...5)
            Text("Esc closes the Brake window. Add “Show Brake” to the Radial Wheel in Settings → Radial Wheel.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// One row of the source list: a radio to make it the one shown, its name and kind, and Remove.
/// `source` nil is the "only the line" row.
private struct SourceRow: View {
    let source: BrakeSource?
    let current: Bool
    let choose: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: choose) {
                Image(systemName: current ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15)).foregroundStyle(current ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(current ? "Brake shows this" : "Show this in Brake")
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(source?.fileURL?.lastPathComponent ?? "No file — only the line").lineLimit(1).truncationMode(.middle)
                if let url = source?.fileURL {
                    Text((source?.medium?.label ?? "Unsupported") + " · " + url.deletingLastPathComponent().path)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    if !FileManager.default.fileExists(atPath: url.path) {
                        Text("File not found").font(.caption).foregroundStyle(.red)
                    }
                }
            }
            Spacer()
            if source != nil {
                Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("Remove from Brake (the file stays)")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: choose)
    }

    private var symbol: String {
        switch source?.medium {
        case .pdf: return "doc.richtext"
        case .epub: return "book"
        case .video: return "film"
        case .audio: return "waveform"
        case .image: return "photo"
        case nil: return "text.quote"
        }
    }
}

/// Loads the book once per file and shows the page picker for it.
private struct BrakeBookmarkPicker: View {
    let url: URL
    let page: Int
    let pick: (Int) -> Void
    @StateObject private var loader: Loader

    init(url: URL, page: Int, pick: @escaping (Int) -> Void) {
        self.url = url
        self.page = page
        self.pick = pick
        _loader = StateObject(wrappedValue: Loader(url: url))
    }

    var body: some View {
        if let book = loader.book {
            BrakePagePicker(book: book, bookmark: book.clamp(page), pick: pick)
        } else {
            Text("Couldn't open this PDF.").foregroundStyle(.secondary)
        }
    }

    @MainActor final class Loader: ObservableObject {
        let book: BrakeBook?
        init(url: URL) { book = BrakeBook(url: url) }
    }
}

/// EPUB bookmarks: every bookmark with its chapter and place, a radio to make one the bookmark Brake
/// opens at, and a preview of how that page opens in your font and size.
private struct BrakeEpubBookmarks: View {
    let url: URL
    let source: BrakeSource
    let settings: BrakeSettings
    let change: (@escaping (inout BrakeSource) -> Void) -> Void
    @StateObject private var loader: Loader

    init(url: URL, source: BrakeSource, settings: BrakeSettings, change: @escaping (@escaping (inout BrakeSource) -> Void) -> Void) {
        self.url = url
        self.source = source
        self.settings = settings
        self.change = change
        _loader = StateObject(wrappedValue: Loader(url: url))
    }

    private var marks: [BrakeBookmark] {
        source.bookmarks.sorted { ($0.chapter, $0.progress) < ($1.chapter, $1.progress) }
    }

    var body: some View {
        if let book = loader.book {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            if marks.isEmpty {
                                Text("No bookmarks yet. Bookmark a page in the Brake window (⌘D), or add a chapter below.")
                                    .font(.callout).foregroundStyle(.secondary).padding(6)
                            }
                            ForEach(marks) { m in row(book, m) }
                        }
                    }
                    .frame(width: 270, height: 260)
                    Menu("Bookmark a Chapter") {
                        ForEach(book.titles.indices, id: \.self) { i in
                            Button("\(i + 1). \(book.titles[i])") { add(chapter: i + 1) }
                        }
                    }
                    .fixedSize()
                }
                VStack(spacing: 8) {
                    let shown = source.shown
                    preview(book, chapter: min(max(0, (shown?.chapter ?? 1) - 1), book.chapters.count - 1), progress: shown?.progress ?? 0)
                    Text(shown == nil ? "No bookmark chosen — Brake opens at the start of the book." : "Brake opens here")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
            }
        } else if let error = loader.error {
            Text(error).foregroundStyle(.secondary)
        } else {
            ProgressView().frame(maxWidth: .infinity)
        }
    }

    private func row(_ book: EpubBook, _ m: BrakeBookmark) -> some View {
        let shown = m.id == source.shownBookmark
        let i = min(max(0, m.chapter - 1), book.titles.count - 1)
        return HStack(spacing: 8) {
            Button {
                let id = m.id
                change { $0.shownBookmark = $0.shownBookmark == id ? nil : id }
            } label: {
                Image(systemName: shown ? "pin.fill" : "pin")
                    .foregroundStyle(shown ? Color(red: 0.82, green: 0.16, blue: 0.15) : .secondary)
                    .frame(width: 18)
            }
            .buttonStyle(.plain)
            .help(shown ? "Brake opens here — click to stop" : "Make this the bookmark Brake opens at")
            VStack(alignment: .leading, spacing: 1) {
                Text(book.titles[i]).lineLimit(1)
                Text(m.progress > 0 ? "Chapter \(m.chapter) · \(Int((m.progress * 100).rounded()))% in" : "Chapter \(m.chapter) · start")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            Button {
                let id = m.id
                change { s in
                    s.bookmarks.removeAll { $0.id == id }
                    if s.shownBookmark == id { s.shownBookmark = nil }
                }
            } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                .buttonStyle(.plain).help("Delete this bookmark")
        }
        .padding(.vertical, 5).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 5).fill(shown ? Color.accentColor.opacity(0.15) : .clear))
    }

    private func add(chapter: Int) {
        change { s in
            guard !s.bookmarks.contains(where: { $0.chapter == chapter && $0.progress == 0 }) else { return }
            s.bookmarks.append(BrakeBookmark(chapter: chapter, progress: 0))
        }
    }

    private func preview(_ book: EpubBook, chapter: Int, progress: Double) -> some View {
        let text = loader.text(chapter)
        let start = text.index(text.startIndex, offsetBy: Int(Double(text.count) * progress), limitedBy: text.endIndex) ?? text.startIndex
        let snippet = String(text[start...].prefix(700))
        return ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 10) {
                Text(book.titles[chapter]).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(snippet.isEmpty ? "(No text in this part — maybe a picture.)" : (start > text.startIndex ? "… " : "") + snippet)
                    .font(BrakeFont.named(settings.font).swiftUI(size: CGFloat(settings.fontSize) * 0.6))
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(18)
            .frame(width: 220, height: 300, alignment: .topLeading)
            .background(Paper.color)
            .clipped()
            .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
            if source.shown != nil { BookmarkRibbon(width: 14).offset(x: -14, y: -3) }
        }
    }

    @MainActor final class Loader: ObservableObject {
        @Published var book: EpubBook?
        @Published var error: String?
        private var texts: [Int: String] = [:]

        init(url: URL) {
            Task { [weak self] in
                let result = await Task.detached(priority: .userInitiated) { Result { try EpubBook.open(url) } }.value
                switch result {
                case .success(let b): self?.book = b
                case .failure(let e): self?.error = e.localizedDescription
                }
            }
        }

        func text(_ chapter: Int) -> String {
            if let t = texts[chapter] { return t }
            let t = book?.text(chapter: chapter) ?? ""
            texts[chapter] = t
            return t
        }
    }
}
