import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BrakeSettings: PluginSettings {
    /// The one thing to show: a PDF or EPUB book, video, audio file or image. Empty shows only `text`. "~" is allowed.
    var path = ""
    /// PDF page to open at (1-based) — the bookmark.
    var page = 1
    /// EPUB bookmark: the chapter (1-based, in reading order) and how far into it (0…1).
    var chapter = 1
    var chapterProgress = 0.0
    /// EPUB text: a font name from `BrakeFont.all` ("Original" keeps the book's own) and its size in points.
    var font = "Iowan Old Style"
    var fontSize = 20
    /// PDF zoom, relative to fitting the page in the window (1 = fit).
    var pdfZoom = 1.0
    /// Where video or audio starts playing.
    var startSeconds = 0.0
    /// A line shown above the medium, or on its own when there is no file.
    var text = "Stop. Breathe. Is this what you really want to be doing right now?"
    /// Start video/audio as soon as the window opens.
    var autoplay = true

    enum CodingKeys: String, CodingKey {
        case path, page, chapter, font, text, autoplay
        case chapterProgress = "chapter_progress", fontSize = "font_size", pdfZoom = "pdf_zoom"
        case startSeconds = "start_seconds"
    }

    var fileURL: URL? {
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return p.isEmpty ? nil : URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
    }
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
    let summary = "One shortcut shows the reminder you picked in advance: a PDF or EPUB book at a set page, a video, audio, image or a line."
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
        if s.fileURL == nil && s.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Toast.show("Brake: choose a file or write a line in Settings → Brake.")
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

    func deactivate() {
        window?.close()
        window = nil
    }

    func defaultSettings() -> [String: JSONValue] { encodeDefaults(BrakeSettings.self) }

    func validate(_ config: AppConfig) throws {
        let s = try config.settings(BrakeSettings.self, for: id)
        if s.page < 1 { throw AppError("brake.page starts at 1.") }
        if s.startSeconds < 0 { throw AppError("brake.start_seconds can't be negative.") }
        if s.chapter < 1 { throw AppError("brake.chapter starts at 1.") }
        if !(0...1).contains(s.chapterProgress) { throw AppError("brake.chapter_progress goes from 0 to 1.") }
        if !(10...48).contains(s.fontSize) { throw AppError("brake.font_size goes from 10 to 48.") }
        if !(0.25...5).contains(s.pdfZoom) { throw AppError("brake.pdf_zoom goes from 0.25 to 5.") }
        if let url = s.fileURL, BrakeMedium(url) == nil {
            throw AppError("brake.path: “\(url.lastPathComponent)” isn't a PDF, EPUB, video, audio file or image.")
        }
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.message = "Choose the one thing Brake shows: a PDF or EPUB book, a video, an audio clip or an image."
        panel.prompt = "Use This"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf, .epub, .movie, .audiovisualContent, .audio, .image]
        panel.treatsFilePackagesAsDirectories = false
        if let url = settings.fileURL { panel.directoryURL = url.deletingLastPathComponent() }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
        do {
            try update { s in
                if s.path != path { s.page = 1; s.chapter = 1; s.chapterProgress = 0; s.startSeconds = 0; s.pdfZoom = 1 }
                s.path = path
            }
        } catch {
            Toast.show(error.localizedDescription)
        }
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

    var body: some View {
        let s = plugin.settings
        let medium = s.fileURL.flatMap(BrakeMedium.init)
        Section("What to show") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.fileURL?.lastPathComponent ?? "No file — only the line below")
                    if let url = s.fileURL {
                        Text((medium?.label ?? "Unsupported") + " · " + url.deletingLastPathComponent().path)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        if !FileManager.default.fileExists(atPath: url.path) {
                            Text("File not found").font(.caption).foregroundStyle(.red)
                        }
                    }
                }
                Spacer()
                Button(s.fileURL == nil ? "Choose File…" : "Change…") { plugin.chooseFile() }
                if s.fileURL != nil { Button("Remove") { set { $0.path = "" } } }
            }
            if medium == .pdf || medium == .epub {
                Text("In the Brake window: ← → turn pages, the bookmark icon (⌘D) moves the bookmark, select text and click the highlighter (⌃⌘H) to highlight.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if medium == .video || medium == .audio {
                HStack {
                    Text("Start at")
                    TextField("seconds", value: Binding(get: { s.startSeconds }, set: { v in set { $0.startSeconds = max(0, v) } }),
                              format: .number)
                        .frame(width: 80)
                    Text("seconds (\(BrakeSession.clock(s.startSeconds)))").foregroundStyle(.secondary)
                }
                Toggle("Play as soon as it opens", isOn: Binding(get: { s.autoplay }, set: { v in set { $0.autoplay = v } }))
            }
        }
        if medium == .pdf, let url = s.fileURL, FileManager.default.fileExists(atPath: url.path) {
            Section("Bookmark") {
                BrakeBookmarkPicker(url: url, page: s.page) { p in set { $0.page = p } }.id(url)
            }
            Section("Reading") {
                HStack {
                    Text("Zoom")
                    Spacer()
                    Text(s.pdfZoom == 1 ? "Fit to window" : "\(Int((s.pdfZoom * 100).rounded()))% of fit").foregroundStyle(.secondary)
                    if s.pdfZoom != 1 { Button("Reset") { set { $0.pdfZoom = 1 } } }
                }
                Text("PDF text can't change font; zoom in the Brake window with ⌘+ / ⌘− or a pinch, and Brake keeps it. Highlights are saved into the PDF, so Preview shows them too.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if medium == .epub, let url = s.fileURL, FileManager.default.fileExists(atPath: url.path) {
            Section("Bookmark") {
                BrakeChapterPicker(url: url, settings: s) { c, p in set { $0.chapter = c; $0.chapterProgress = p } }.id(url)
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
        Section("Line") {
            TextField("Shown above the file, or on its own", text: Binding(get: { s.text }, set: { v in set { $0.text = v } }),
                      axis: .vertical)
                .lineLimit(2...5)
            Text("Esc closes the Brake window. Add “Show Brake” to the Radial Wheel in Settings → Radial Wheel.")
                .font(.caption).foregroundStyle(.secondary)
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

/// EPUB bookmark: pick a chapter from the table of contents and see how its text opens, in the
/// font and size you read in.
private struct BrakeChapterPicker: View {
    let url: URL
    let settings: BrakeSettings
    let pick: (Int, Double) -> Void
    @StateObject private var loader: Loader

    init(url: URL, settings: BrakeSettings, pick: @escaping (Int, Double) -> Void) {
        self.url = url
        self.settings = settings
        self.pick = pick
        _loader = StateObject(wrappedValue: Loader(url: url))
    }

    var body: some View {
        if let book = loader.book {
            let current = min(max(0, settings.chapter - 1), book.chapters.count - 1)
            HStack(alignment: .top, spacing: 16) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(book.titles.indices, id: \.self) { i in
                                Button { pick(i + 1, 0) } label: {
                                    HStack(spacing: 8) {
                                        Text("\(i + 1)").font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 24, alignment: .trailing)
                                        Text(book.titles[i]).lineLimit(1)
                                        Spacer()
                                        if i == current { Image(systemName: "bookmark.fill").foregroundStyle(.red) }
                                    }
                                    .padding(.vertical, 5).padding(.horizontal, 6)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(i == current ? Color.accentColor.opacity(0.15) : .clear))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .id(i)
                            }
                        }
                    }
                    .frame(width: 250, height: 300)
                    .onAppear { proxy.scrollTo(current, anchor: .center) }
                }
                VStack(spacing: 8) {
                    preview(book, chapter: current)
                    HStack {
                        Text(settings.chapterProgress > 0
                             ? "\(Int((settings.chapterProgress * 100).rounded()))% into the chapter"
                             : "Start of the chapter")
                            .font(.caption).foregroundStyle(.secondary)
                        if settings.chapterProgress > 0 {
                            Button("Start of Chapter") { pick(current + 1, 0) }.controlSize(.small)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        } else if let error = loader.error {
            Text(error).foregroundStyle(.secondary)
        } else {
            ProgressView().frame(maxWidth: .infinity)
        }
    }

    private func preview(_ book: EpubBook, chapter: Int) -> some View {
        let text = loader.text(chapter)
        let start = text.index(text.startIndex, offsetBy: Int(Double(text.count) * settings.chapterProgress), limitedBy: text.endIndex) ?? text.startIndex
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
            BookmarkRibbon(width: 14).offset(x: -14, y: -3)
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
