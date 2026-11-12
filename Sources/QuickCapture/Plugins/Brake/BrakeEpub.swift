import AppKit
import CryptoKit
import Foundation

/// An EPUB unpacked into Brake's cache: chapters in reading order, with titles from the table of
/// contents. Apple Books' own `.epub` folders are read in place.
final class EpubBook: @unchecked Sendable {
    let source: URL
    /// The folder the chapter files live under (web view read access).
    let root: URL
    let chapters: [URL]
    let titles: [String]
    let title: String

    private init(source: URL, root: URL, chapters: [URL], titles: [String], title: String) {
        self.source = source
        self.root = root
        self.chapters = chapters
        self.titles = titles
        self.title = title
    }

    /// Unpacks (once per file version) and reads the package. Slow for big books: call off the main thread.
    static func open(_ url: URL) throws -> EpubBook {
        let root = try unpacked(url)
        let container = try xml(root.appendingPathComponent("META-INF/container.xml"))
        guard let opfPath = try container.nodes(forXPath: "//*[local-name()='rootfile']/@full-path").first?.stringValue else {
            throw AppError("“\(url.lastPathComponent)” has no package file — is it a real EPUB?")
        }
        let opfURL = root.appendingPathComponent(opfPath)
        let opf = try xml(opfURL)
        let base = opfURL.deletingLastPathComponent()

        var manifest: [String: (url: URL, type: String, props: String)] = [:]
        for item in try opf.nodes(forXPath: "//*[local-name()='manifest']/*[local-name()='item']") {
            guard let e = item as? XMLElement, let id = e.attribute(forName: "id")?.stringValue,
                  let href = e.attribute(forName: "href")?.stringValue, let u = resolve(href, against: base) else { continue }
            manifest[id] = (u, e.attribute(forName: "media-type")?.stringValue ?? "", e.attribute(forName: "properties")?.stringValue ?? "")
        }
        let chapters = try opf.nodes(forXPath: "//*[local-name()='spine']/*[local-name()='itemref']").compactMap { node -> URL? in
            guard let e = node as? XMLElement, let id = e.attribute(forName: "idref")?.stringValue, let item = manifest[id] else { return nil }
            return item.type.contains("html") || item.url.pathExtension.lowercased().hasPrefix("htm") || item.url.pathExtension.lowercased() == "xhtml"
                ? item.url : nil
        }
        guard !chapters.isEmpty else { throw AppError("“\(url.lastPathComponent)” has no chapters to show.") }

        // Table of contents: EPUB 3 nav document, else the EPUB 2 NCX.
        var toc: [String: String] = [:]
        func add(_ href: String?, _ label: String?, base: URL) {
            guard let href, let label = label?.collapsedWhitespace, !label.isEmpty,
                  let u = resolve(String(href.split(separator: "#", maxSplits: 1).first ?? ""), against: base) else { return }
            if toc[u.path] == nil { toc[u.path] = label }
        }
        if let nav = manifest.values.first(where: { $0.props.split(separator: " ").contains("nav") }), let doc = try? xml(nav.url) {
            for a in (try? doc.nodes(forXPath: "//*[local-name()='nav']//*[local-name()='a']")) ?? [] {
                add((a as? XMLElement)?.attribute(forName: "href")?.stringValue, a.stringValue, base: nav.url.deletingLastPathComponent())
            }
        }
        if toc.isEmpty, let ncx = manifest.values.first(where: { $0.type == "application/x-dtbncx+xml" }), let doc = try? xml(ncx.url) {
            for p in (try? doc.nodes(forXPath: "//*[local-name()='navPoint']")) ?? [] {
                let label = try? p.nodes(forXPath: "./*[local-name()='navLabel']").first?.stringValue
                let src = try? p.nodes(forXPath: "./*[local-name()='content']/@src").first?.stringValue
                add(src, label, base: ncx.url.deletingLastPathComponent())
            }
        }
        var titles: [String] = []
        for (i, c) in chapters.enumerated() {
            if let t = toc[c.path], isTitle(t) { titles.append(t); continue }
            let doc = try? html(c)
            let headings = ["//*[local-name()='body']//*[local-name()='h1' or local-name()='h2' or local-name()='h3']", "//*[local-name()='title']"]
                .flatMap { (try? doc?.nodes(forXPath: $0)) ?? [] }
                .compactMap { $0.stringValue?.collapsedWhitespace }
            titles.append(headings.first(where: isTitle).map { String($0.prefix(80)) } ?? (i == 0 ? "Beginning" : "Section \(i + 1)"))
        }
        let bookTitle = (try? opf.nodes(forXPath: "//*[local-name()='metadata']/*[local-name()='title']").first?.stringValue)?
            .collapsedWhitespace
        return EpubBook(source: url, root: root, chapters: chapters, titles: titles,
                        title: bookTitle.flatMap { isTitle($0) ? $0 : nil } ?? url.deletingPathExtension().lastPathComponent)
    }

    /// A heading worth showing: has letters and isn't a converter's leftover file name.
    private static func isTitle(_ s: String) -> Bool {
        let lower = s.lowercased()
        return s.contains(where: { $0.isLetter }) && !["pdf", "html", "htm", "xhtml", "doc", "docx"].contains(where: { lower.hasSuffix("." + $0) })
    }

    /// Plain text of a chapter, for the Settings preview.
    func text(chapter: Int) -> String {
        guard chapters.indices.contains(chapter),
              let doc = try? Self.html(chapters[chapter]),
              let body = try? doc.nodes(forXPath: "//*[local-name()='body']").first else { return "" }
        return body.stringValue?.collapsedWhitespace ?? ""
    }

    // MARK: Files

    /// The book's private folder in Brake's data: one per file, refreshed when the file changes.
    static func key(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8))
        let hex = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        let name = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "/", with: "-")
        return "\(name.prefix(40))-\(hex)"
    }

    private static func unpacked(_ url: URL) throws -> URL {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { throw AppError("Can't find \(url.path)") }
        if isDir.boolValue { return url }
        let fm = FileManager.default
        let dir = Paths.data(for: BrakePlugin.pluginID).appendingPathComponent("epub", isDirectory: true)
            .appendingPathComponent(key(for: url), isDirectory: true)
        let attrs = try fm.attributesOfItem(atPath: url.path)
        let stamp = "\((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)-\((attrs[.size] as? NSNumber)?.intValue ?? 0)"
        let stampFile = dir.appendingPathComponent(".brake-stamp")
        if (try? String(contentsOf: stampFile)) == stamp { return dir }
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-qq", "-o", url.path, "-d", dir.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard fm.fileExists(atPath: dir.appendingPathComponent("META-INF/container.xml").path) else {
            try? fm.removeItem(at: dir)
            throw AppError("Couldn't unpack “\(url.lastPathComponent)” — is it a real EPUB?")
        }
        try stamp.write(to: stampFile, atomically: true, encoding: .utf8)
        return dir
    }

    private static func resolve(_ href: String, against base: URL) -> URL? {
        guard !href.isEmpty else { return nil }
        let decoded = href.removingPercentEncoding ?? href
        return base.appendingPathComponent(decoded).standardizedFileURL
    }

    private static func xml(_ url: URL) throws -> XMLDocument {
        try XMLDocument(contentsOf: url, options: [])
    }

    private static func html(_ url: URL) throws -> XMLDocument {
        if let doc = try? XMLDocument(contentsOf: url, options: []) { return doc }
        return try XMLDocument(contentsOf: url, options: [.documentTidyHTML])
    }
}

/// EPUB highlights live beside Brake's settings (an EPUB is a zip we don't rewrite).
struct EpubHighlight: Codable, Equatable {
    var id: String
    var chapter: Int
    /// Character offsets into the chapter's text.
    var start: Int
    var end: Int
    var color: HighlightColor
    var text: String
}

@MainActor
final class EpubHighlightStore {
    private let file: URL
    private(set) var items: [EpubHighlight] = []

    init(book: URL) {
        file = Paths.data(for: BrakePlugin.pluginID).appendingPathComponent("highlights", isDirectory: true)
            .appendingPathComponent(EpubBook.key(for: book) + ".json")
        if let data = try? Data(contentsOf: file), let list = try? JSONDecoder().decode([EpubHighlight].self, from: data) {
            items = list
        }
    }

    func inChapter(_ c: Int) -> [EpubHighlight] { items.filter { $0.chapter == c } }

    func add(_ h: EpubHighlight) { items.append(h); write() }
    func remove(_ id: String) { items.removeAll { $0.id == id }; write() }
    func recolor(_ id: String, _ c: HighlightColor) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].color = c
        write()
    }

    private func write() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(items).write(to: file, options: .atomic)
        } catch {
            Toast.show("Couldn't save highlights: \(error.localizedDescription)")
        }
    }
}

extension String {
    var collapsedWhitespace: String {
        split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
