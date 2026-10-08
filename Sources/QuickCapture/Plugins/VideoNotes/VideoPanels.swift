import AVFoundation
import AppKit
import SwiftUI

/// Borderless panels can't take key presses unless they say so.
final class KeyPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    var closeWhenResigned = false

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    override func resignKey() {
        super.resignKey()
        if closeWhenResigned { orderOut(nil) }
    }
}

/// Lays tags out left to right, wrapping to new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, point) in zip(subviews, arrange(bounds.width, subviews).points) {
            subview.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (points: [CGPoint], size: CGSize) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        var points: [CGPoint] = []
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (points, CGSize(width: maxX, height: y + rowHeight))
    }
}

/// Shown after a recording (and from "Edit"): pick an existing tag or type a new one, add a note.
struct VideoPromptView: View {
    let title: String
    let onSave: (String?, String) -> Void
    let onCancel: () -> Void
    /// Only for a recording that just finished: throw it away (asks first).
    var onDiscard: (() -> Void)?

    @State private var tags: [String]
    @State private var tag: String?
    @State private var note: String
    @State private var newTag = ""
    @FocusState private var noteFocused: Bool

    init(title: String, tags: [String], tag: String?, note: String,
         onSave: @escaping (String?, String) -> Void, onCancel: @escaping () -> Void, onDiscard: (() -> Void)? = nil) {
        self.title = title
        self.onSave = onSave
        self.onCancel = onCancel
        self.onDiscard = onDiscard
        _tags = State(initialValue: tags)
        _tag = State(initialValue: tag)
        _note = State(initialValue: note)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("What's this video about?").font(.headline)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            FlowLayout(spacing: 6) {
                ForEach(tags, id: \.self) { name in
                    let selected = tag == name
                    Button { tag = selected ? nil : name } label: {
                        Text(name)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(selected ? Color.accentColor : Color.secondary.opacity(0.15), in: Capsule())
                            .foregroundStyle(selected ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                TextField("New tag", text: $newTag).onSubmit(addTag)
                Button("Add", action: addTag).disabled(trimmedNewTag.isEmpty)
            }
            TextField("Note (optional)", text: $note).focused($noteFocused).onSubmit(save)
            HStack {
                if let onDiscard {
                    Button("Discard…", role: .destructive, action: onDiscard)
                        .keyboardShortcut(.delete, modifiers: .command)
                        .help("Throw this recording away (⌘⌫)")
                }
                Spacer()
                Button("Skip", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 380)
        .onAppear { noteFocused = true }
    }

    private var trimmedNewTag: String { newTag.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func addTag() {
        let name = trimmedNewTag
        guard !name.isEmpty else { return }
        if !tags.contains(name) { tags.append(name) }
        tag = name
        newTag = ""
    }

    private func save() {
        addTag()
        onSave(tag, note.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// The quick-play list: press 1–5 to play that video, Esc to close.
struct QuickPlayView: View {
    let videos: [VideoItem?]
    let play: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(videos.enumerated()), id: \.offset) { index, item in
                Button { play(index + 1) } label: {
                    HStack(spacing: 10) {
                        Text("\(index + 1)")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .frame(width: 24, height: 24)
                            .background(Color.secondary.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
                        if let item {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title).lineLimit(1)
                                Text([item.tag, formattedSize(item.size)].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            Text("Empty slot").foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(item == nil)
            }
            Text("Press 1–5 to play · esc to close").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 380)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
    }
}

/// Kanban board: quick-play slots on top, then one column per tag (plus Untagged), newest video first.
/// Drag a card to another column to retag it, or onto a slot to make it a quick-play video.
struct VideoDashboardView: View {
    let plugin: VideoNotesPlugin
    @ObservedObject var store: VideoStore
    @ObservedObject var state: AppState
    @ObservedObject var recorder: VideoRecorder

    @State private var managingTags = false
    @State private var search = ""

    private var columns: [String?] { [nil] + plugin.allTags.map { Optional($0) } }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if store.videos.isEmpty {
                emptyState
            } else {
                QuickSlotStrip(plugin: plugin, store: store)
                    .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 4)
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(columns, id: \.self) { column in
                            VideoColumn(plugin: plugin, store: store, tag: column, search: search)
                        }
                        Button { plugin.promptNewTag() } label: {
                            Label("New Tag", systemImage: "plus")
                                .frame(width: 140, height: 44)
                                .background(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5]))
                                    .foregroundStyle(.tertiary))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $managingTags) { ManageTagsView(plugin: plugin, store: store, state: state) { managingTags = false } }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Video Notes").font(.title3.weight(.semibold))
                Text("\(store.videos.count) video\(store.videos.count == 1 ? "" : "s") · \(formattedSize(store.totalSize))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search notes and tags", text: $search).textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.12)))
            .frame(maxWidth: 240)
            VolumeSlider(plugin: plugin, compact: true)
                .help("Playback volume on top of your Mac's volume")
            recordButton
            Menu {
                Button("New Tag…") { plugin.promptNewTag() }
                Button("Manage Tags…") { managingTags = true }
                Divider()
                Button("Compress All Videos") { plugin.compressAll() }
                Button("Show in Finder") { plugin.revealLibrary() }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    @ViewBuilder private var recordButton: some View {
        if recorder.isRecording {
            Button { plugin.action("stop").map(plugin.perform) } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent).tint(.red)
        } else {
            Button { plugin.action("record").map(plugin.perform) } label: {
                Label("Record", systemImage: "record.circle")
            }
            .buttonStyle(.borderedProminent).tint(.red)
            .help("Record a new video (\(plugin.shortcutText("record")))")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "video.badge.plus").font(.system(size: 44)).foregroundStyle(.tertiary)
            Text("No videos yet").font(.title3.weight(.semibold))
            Text("Press \(plugin.shortcutText("record")) anywhere to record one.").foregroundStyle(.secondary)
            recordButton.controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The five quick-play videos. Click to play; drop a card here to assign it.
private struct QuickSlotStrip: View {
    let plugin: VideoNotesPlugin
    @ObservedObject var store: VideoStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Quick Play").font(.subheadline.weight(.semibold))
                Text("\(plugin.shortcutText("quick_play")), then 1–5 · drop a video on a slot")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                ForEach(1...VideoStore.slotCount, id: \.self) { slot in
                    QuickSlotTile(plugin: plugin, store: store, slot: slot)
                }
            }
        }
    }
}

private struct QuickSlotTile: View {
    let plugin: VideoNotesPlugin
    @ObservedObject var store: VideoStore
    let slot: Int
    @State private var targeted = false

    var body: some View {
        let item = store.video(slot: slot)
        HStack(spacing: 8) {
            Text("\(slot)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .frame(width: 20, height: 20)
                .background(Circle().fill(item == nil ? Color.secondary.opacity(0.2) : Color.accentColor))
                .foregroundStyle(item == nil ? Color.secondary : Color.white)
            if let item {
                Thumbnail(store: store, item: item).frame(width: 48, height: 27).clipShape(RoundedRectangle(cornerRadius: 4))
                Text(item.title).font(.caption).lineLimit(2)
            } else {
                Text("Empty").font(.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 46)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.secondary.opacity(targeted ? 0.25 : 0.08)))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.2),
                          style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: item == nil && !targeted ? [4] : [])))
        .contentShape(Rectangle())
        .onTapGesture { if let item { plugin.play(item) } }
        .help(item.map { "Play “\($0.title)”" } ?? "Drag a video here")
        .contextMenu {
            if let item {
                Button("Play") { plugin.play(item) }
                Button("Clear Slot") { store.setSlot(nil, for: item.file) }
            }
        }
        .dropDestination(for: String.self) { dropped, _ in
            guard let file = dropped.first(where: { !$0.hasPrefix(VideoColumn.tagPrefix) }) else { return false }
            store.setSlot(slot, for: file)
            return true
        } isTargeted: { targeted = $0 }
    }
}

/// Reorder (drag rows), add, and delete tags; deleting asks first and keeps the videos.
private struct ManageTagsView: View {
    let plugin: VideoNotesPlugin
    @ObservedObject var store: VideoStore
    @ObservedObject var state: AppState
    let close: () -> Void
    @State private var selection = Set<String>()
    @State private var newTag = ""

    var body: some View {
        let tags = plugin.allTags
        VStack(alignment: .leading, spacing: 12) {
            Text("Tags").font(.headline)
            Text("Drag to reorder (the dashboard follows). Select several to delete them together.")
                .font(.caption).foregroundStyle(.secondary)
            List(selection: $selection) {
                ForEach(tags, id: \.self) { tag in
                    HStack {
                        Text(tag)
                        Spacer()
                        Text("\(store.videos.filter { $0.tag == tag }.count)").foregroundStyle(.secondary)
                    }
                }
                .onMove { source, destination in
                    var next = tags
                    next.move(fromOffsets: source, toOffset: destination)
                    plugin.setTags(next)
                }
            }
            .frame(height: 220)
            HStack {
                TextField("New tag", text: $newTag).onSubmit(add)
                Button("Add", action: add).disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                Button("Delete Selected…", role: .destructive) {
                    if plugin.deleteTags(tags.filter(selection.contains)) { selection = [] }
                }
                .disabled(selection.isEmpty)
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private func add() {
        plugin.addTag(newTag)
        newTag = ""
    }
}

struct VideoColumn: View {
    let plugin: VideoNotesPlugin
    @ObservedObject var store: VideoStore
    let tag: String?
    var search = ""
    @State private var targeted = false
    static let tagPrefix = "tag:"

    var body: some View {
        let all = store.videos.filter { $0.tag == tag }
        let query = search.trimmingCharacters(in: .whitespaces)
        let items = query.isEmpty ? all : all.filter {
            $0.title.localizedCaseInsensitiveContains(query) || ($0.tag ?? "").localizedCaseInsensitiveContains(query)
        }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(tag == nil ? Color.secondary : Color.accentColor).frame(width: 8, height: 8)
                Text(tag ?? "Untagged").font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("\(all.count)")
                    .font(.caption2.weight(.semibold)).monospacedDigit()
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formattedSize(all.reduce(0) { $0 + $1.size })).font(.caption2).foregroundStyle(.tertiary)
                if let tag {
                    Menu {
                        Button("Delete Tag…", role: .destructive) { plugin.deleteTags([tag]) }
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
            }
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
            .modifier(TagDrag(tag: tag))
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(items) { VideoCard(plugin: plugin, store: store, item: $0) }
                    if items.isEmpty {
                        Text(query.isEmpty ? "Drop videos here" : "No matches")
                            .font(.caption).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, minHeight: 60)
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 260)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(targeted ? 0.2 : 0.07)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(targeted ? Color.accentColor : .clear, lineWidth: 2))
        .dropDestination(for: String.self) { dropped, _ in
            for item in dropped {
                if item.hasPrefix(Self.tagPrefix) {
                    if let tag { plugin.moveTag(String(item.dropFirst(Self.tagPrefix.count)), to: tag) }
                } else {
                    store.update(item) { $0.tag = tag }
                }
            }
            return !dropped.isEmpty
        } isTargeted: { targeted = $0 }
    }
}

/// Column headers of real tags can be dragged onto another column to reorder.
private struct TagDrag: ViewModifier {
    let tag: String?

    func body(content: Content) -> some View {
        if let tag { content.draggable(VideoColumn.tagPrefix + tag) } else { content }
    }
}

private struct VideoCard: View {
    let plugin: VideoNotesPlugin
    @ObservedObject var store: VideoStore
    let item: VideoItem
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay { Thumbnail(store: store, item: item) }
                .overlay {
                    if hovering {
                        ZStack {
                            Color.black.opacity(0.25)
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 34)).foregroundStyle(.white).shadow(radius: 4)
                        }
                    }
                }
                .clipped()
            .overlay(alignment: .topLeading) {
                if let slot = item.slot {
                    Text("\(slot)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.accentColor)).foregroundStyle(.white)
                        .padding(6).help("Quick play \(slot)")
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let duration = Thumbnails.shared.duration(for: item) {
                    Text(duration)
                        .font(.caption2.weight(.medium)).monospacedDigit()
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.6))).foregroundStyle(.white)
                        .padding(6)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { plugin.play(item) }

            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.callout.weight(.medium)).lineLimit(2)
                    Text("\(item.created.formatted(date: .abbreviated, time: .shortened)) · \(formattedSize(item.size))")
                        .font(.caption2).foregroundStyle(.secondary)
                    if store.busy.contains(item.file) {
                        Label("Compressing…", systemImage: "hourglass").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Menu { actions } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .opacity(hovering ? 1 : 0.4)
            }
            .padding(8)
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(hovering ? 0.4 : 0.2)))
        .shadow(color: .black.opacity(hovering ? 0.12 : 0.04), radius: hovering ? 6 : 2, y: 1)
        .onHover { hovering = $0 }
        .draggable(item.file)
        .contextMenu { actions }
    }

    @ViewBuilder private var actions: some View {
        Button("Play") { plugin.play(item) }
        Button("Open in QuickTime Player") { plugin.openInDefaultPlayer(item) }
        Button("Edit Tag & Note…") { plugin.edit(item.file) }
        Menu("Quick Play Slot") {
            ForEach(1...VideoStore.slotCount, id: \.self) { slot in
                Button("\(slot)\(item.slot == slot ? " ✓" : "")") { store.setSlot(slot, for: item.file) }
            }
            if item.slot != nil { Divider(); Button("None") { store.setSlot(nil, for: item.file) } }
        }
        if item.compressionVersion < VideoCompressor.version && !store.busy.contains(item.file) {
            Button(item.compressed ? "Compress Again (smaller)" : "Compress") { plugin.compress(item.file) }
        }
        Button("Show in Finder") { plugin.reveal(item) }
        Divider()
        Button("Move to Trash", role: .destructive) { plugin.delete(item) }
    }
}

/// A video's first frame, loaded in the background and cached by file and size (compression changes both).
private struct Thumbnail: View {
    @ObservedObject var store: VideoStore
    let item: VideoItem
    @ObservedObject private var cache = Thumbnails.shared

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.15)
            if let image = cache.image(for: item) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "video").foregroundStyle(.tertiary)
            }
        }
        .task(id: Thumbnails.key(item)) {
            if let url = store.url(item) { await cache.load(item, url: url) }
        }
    }
}

@MainActor
final class Thumbnails: ObservableObject {
    static let shared = Thumbnails()
    @Published private var images: [String: NSImage] = [:]
    @Published private var durations: [String: Double] = [:]
    private var loading: Set<String> = []

    nonisolated static func key(_ item: VideoItem) -> String { "\(item.file)#\(item.size)" }

    func image(for item: VideoItem) -> NSImage? { images[Self.key(item)] }

    func duration(for item: VideoItem) -> String? {
        guard let seconds = durations[Self.key(item)], seconds.isFinite else { return nil }
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    func load(_ item: VideoItem, url: URL) async {
        let key = Self.key(item)
        guard images[key] == nil, !loading.contains(key) else { return }
        loading.insert(key)
        defer { loading.remove(key) }
        let asset = AVURLAsset(url: url)
        if let duration = try? await asset.load(.duration) { durations[key] = duration.seconds }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 520, height: 520)
        let time = CMTime(seconds: min(1, (durations[key] ?? 0) / 2), preferredTimescale: 600)
        if let (cg, _) = try? await generator.image(at: time) {
            images[key] = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
    }
}
