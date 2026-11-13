import AppKit
import PDFKit
import SwiftUI

/// A PDF opened as a book: page images (cached) and page shapes, shared by the reader and the
/// Settings page picker. Pages are 1-based everywhere.
@MainActor
final class BrakeBook {
    let url: URL
    let document: PDFDocument
    var pageCount: Int { document.pageCount }
    private let cache = NSCache<NSString, NSImage>()

    init?(url: URL) {
        guard let doc = PDFDocument(url: url), doc.pageCount > 0 else { return nil }
        self.url = url
        document = doc
        cache.countLimit = 80
    }

    var title: String {
        let t = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? url.deletingPathExtension().lastPathComponent : t
    }

    func clamp(_ page: Int) -> Int { min(max(1, page), pageCount) }

    /// Width ÷ height of a page as it is displayed (rotation included).
    func aspect(_ page: Int) -> CGFloat {
        guard let p = document.page(at: clamp(page) - 1) else { return 0.7 }
        let b = p.bounds(for: .cropBox)
        let rotated = p.rotation % 180 != 0
        let w = rotated ? b.height : b.width, h = rotated ? b.width : b.height
        return h > 0 ? w / h : 0.7
    }

    /// The page rendered `pixelHeight` tall. Heights are bucketed so small resizes reuse the cache.
    func image(_ page: Int, pixelHeight: CGFloat) -> NSImage? {
        guard page >= 1, page <= pageCount, let p = document.page(at: page - 1) else { return nil }
        let h = min(3000, max(64, (pixelHeight / 64).rounded(.up) * 64))
        let key = "\(page)@\(Int(h))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let img = p.thumbnail(of: NSSize(width: h * aspect(page), height: h), for: .cropBox)
        cache.setObject(img, forKey: key)
        return img
    }

    // MARK: Spreads (two pages side by side, cover on its own, like a printed book)

    /// The first (left) page of the spread that shows `page`.
    func spreadStart(_ page: Int, twoUp: Bool) -> Int {
        let p = clamp(page)
        guard twoUp, p > 1 else { return p }
        return p % 2 == 0 ? p : p - 1
    }

    func spread(_ page: Int, twoUp: Bool) -> [Int] {
        let s = spreadStart(page, twoUp: twoUp)
        guard twoUp, s > 1, s + 1 <= pageCount else { return [s] }
        return [s, s + 1]
    }

    func next(_ page: Int, twoUp: Bool) -> Int? {
        let s = spreadStart(page, twoUp: twoUp)
        let n = !twoUp ? s + 1 : (s == 1 ? 2 : s + 2)
        return n <= pageCount ? n : nil
    }

    func previous(_ page: Int, twoUp: Bool) -> Int? {
        let s = spreadStart(page, twoUp: twoUp)
        guard s > 1 else { return nil }
        return twoUp ? spreadStart(s - 1, twoUp: true) : s - 1
    }
}

/// The red ribbon that hangs over the top edge of a bookmarked page.
/// Red for the bookmark Brake opens at; slate blue for an ordinary one.
struct BookmarkRibbon: View {
    static let shownColor = Color(red: 0.82, green: 0.16, blue: 0.15)
    static let plainColor = Color(red: 0.33, green: 0.47, blue: 0.68)

    var width: CGFloat = 20
    var color: Color = BookmarkRibbon.shownColor

    var body: some View {
        RibbonShape()
            .fill(LinearGradient(colors: [color, color.opacity(0.78)], startPoint: .leading, endPoint: .trailing))
            .frame(width: width, height: width * 2.4)
            .shadow(color: .black.opacity(0.28), radius: 1.5, x: 0, y: 1)
            .accessibilityLabel("Bookmarked")
    }
}

private struct RibbonShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY - r.width * 0.45))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// One page as paper: rendered image, soft shadow, and the ribbon when it is the bookmark.
struct BookPageView: View {
    let book: BrakeBook
    let page: Int
    let size: CGSize
    var bookmarked = false
    var ribbonWidth: CGFloat = 20
    /// Which side of a spread the page sits on, for the shading toward the spine.
    var spine: HorizontalEdge? = nil
    @Environment(\.displayScale) private var scale

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let img = book.image(page, pixelHeight: size.height * scale) {
                    Image(nsImage: img).resizable().interpolation(.high)
                } else {
                    Color.white
                }
            }
            .frame(width: size.width, height: size.height)
            .overlay(spineShade)
            if bookmarked {
                BookmarkRibbon(width: ribbonWidth).offset(x: -ribbonWidth * 0.9, y: -3)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(width: size.width, height: size.height)
        .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 2)
    }

    @ViewBuilder private var spineShade: some View {
        if let spine {
            LinearGradient(colors: [.black.opacity(0.16), .black.opacity(0.04), .clear],
                           startPoint: spine == .leading ? .leading : .trailing,
                           endPoint: spine == .leading ? .trailing : .leading)
                .frame(width: min(40, size.width * 0.1))
                .frame(maxWidth: .infinity, alignment: spine == .leading ? .leading : .trailing)
                .allowsHitTesting(false)
        }
    }
}

/// Settings: pick the bookmark by looking at the pages — a large preview of the bookmarked page
/// and a strip of every page to click.
struct BrakePagePicker: View {
    let book: BrakeBook
    let bookmark: Int
    let pick: (Int) -> Void

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 18) {
                Button { pick(book.clamp(bookmark - 1)) } label: { Image(systemName: "chevron.left").font(.title2) }
                    .buttonStyle(.borderless).disabled(bookmark <= 1).help("Previous page")
                BookPageView(book: book, page: bookmark, size: previewSize, bookmarked: true, ribbonWidth: 16)
                    .padding(.top, 4)
                Button { pick(book.clamp(bookmark + 1)) } label: { Image(systemName: "chevron.right").font(.title2) }
                    .buttonStyle(.borderless).disabled(bookmark >= book.pageCount).help("Next page")
            }
            .frame(maxWidth: .infinity)
            Text("Opens at page \(bookmark) of \(book.pageCount)").font(.callout).monospacedDigit()
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: true) {
                    LazyHStack(alignment: .top, spacing: 10) {
                        ForEach(1...book.pageCount, id: \.self) { p in
                            PageThumb(book: book, page: p, selected: p == bookmark).onTapGesture { pick(p) }.id(p)
                        }
                    }
                    .padding(.horizontal, 6).padding(.vertical, 8)
                }
                .frame(height: 132)
                .onAppear { proxy.scrollTo(bookmark, anchor: .center) }
                .onChange(of: bookmark) { p in withAnimation { proxy.scrollTo(p, anchor: .center) } }
            }
        }
    }

    private var previewSize: CGSize {
        let h: CGFloat = 280
        return CGSize(width: h * book.aspect(bookmark), height: h)
    }
}

private struct PageThumb: View {
    let book: BrakeBook
    let page: Int
    let selected: Bool

    var body: some View {
        let h: CGFloat = 92
        VStack(spacing: 4) {
            BookPageView(book: book, page: page, size: CGSize(width: h * book.aspect(page), height: h),
                         bookmarked: selected, ribbonWidth: 9)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.accentColor, lineWidth: selected ? 2.5 : 0).padding(-3))
            Text("\(page)").font(.caption2).monospacedDigit()
                .foregroundStyle(selected ? Color.accentColor : .secondary)
        }
        .contentShape(Rectangle())
        .help("Open at page \(page)")
    }
}
