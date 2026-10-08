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
    var question = "What's this video about?"
    let onSave: (String?, String) -> Void
    let onCancel: () -> Void
    /// Only for a recording that just finished: throw it away (asks first).
    var onDiscard: (() -> Void)?

    @State private var tags: [String]
    @State private var tag: String?
    @State private var note: String
    @State private var newTag = ""
    @FocusState private var noteFocused: Bool

    init(title: String, question: String = "What's this video about?", tags: [String], tag: String?, note: String,
         onSave: @escaping (String?, String) -> Void, onCancel: @escaping () -> Void, onDiscard: (() -> Void)? = nil) {
        self.title = title
        self.question = question
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
                Text(question).font(.headline)
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

final class DashboardTab: ObservableObject {
    @Published var kind = MediaKind.video
}

/// Media Capture's dashboard: Videos, Selfies and Recordings, each a Kanban board with one column per tag
/// (tags are shared) plus Untagged, newest first. Drag a card to another column to retag it. Videos also have
/// the quick-play slots on top; recordings show their transcript.
struct VideoDashboardView: View {
    @ObservedObject var plugin: VideoNotesPlugin
    @ObservedObject var tab: DashboardTab
    @ObservedObject var state: AppState
    @ObservedObject var recorder: VideoRecorder
    @ObservedObject var meeting: MeetingRecorder

    @State private var search = ""

    var body: some View {
        // Read here (this view observes the config) and handed down, so the board redraws the moment the order changes.
        let tags = plugin.allTags
        let columns: [String?] = plugin.settings.untaggedLast ? tags + [nil] : [nil] + tags
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                if plugin.arrangingTags {
                    TagOrderPanel(plugin: plugin, tags: tags, untaggedLast: plugin.settings.untaggedLast)
                        .frame(width: 240)
                    Divider()
                }
                MediaBoard(plugin: plugin, store: plugin.store(tab.kind), kind: tab.kind, columns: columns, search: search,
                           recorder: recorder, meeting: meeting)
                    .id(tab.kind)
            }
        }
        .frame(minWidth: 760, minHeight: 460)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $tab.kind) {
                ForEach(MediaKind.allCases) { kind in
                    Label("\(kind.title) \(plugin.store(kind).videos.count)", systemImage: kind.symbol).tag(kind)
                }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Spacer(minLength: 12)
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(tab.kind == .audio ? "Search notes, tags, transcripts" : "Search notes and tags", text: $search)
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.12)))
            .frame(maxWidth: 240)
            if tab.kind != .selfie {
                VolumeSlider(plugin: plugin, compact: true)
                    .help("Playback volume on top of your Mac's volume")
            }
            Toggle(isOn: $plugin.arrangingTags) { Label("Tag Order", systemImage: "list.number") }
                .toggleStyle(.button)
                .help("Show or hide the tag order panel: rank the tags, important ones first")
            CaptureButton(plugin: plugin, kind: tab.kind, recorder: recorder, meeting: meeting)
            Menu {
                Button("New Tag…") { plugin.promptNewTag() }
                Button(plugin.arrangingTags ? "Hide Tag Order" : "Show Tag Order") { plugin.arrangingTags.toggle() }
                Divider()
                if tab.kind == .video { Button("Compress All Videos") { plugin.compressAll() } }
                if tab.kind == .audio { Button("Transcribe a Recording Again…") { plugin.transcribeAgain() } }
                Button("Show \(tab.kind.title) in Finder") { plugin.revealLibrary(tab.kind) }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

/// Record / Take Selfie / Record Meeting, or Stop while that kind is recording.
private struct CaptureButton: View {
    let plugin: VideoNotesPlugin
    let kind: MediaKind
    @ObservedObject var recorder: VideoRecorder
    @ObservedObject var meeting: MeetingRecorder

    var body: some View {
        let (title, symbol, actionID, stop): (String, String, String, Bool) = switch kind {
        case .video: recorder.isRecording ? ("Stop", "stop.fill", "stop", true) : ("Record", "record.circle", "record", false)
        case .selfie: ("Take Selfie", "camera", "selfie", false)
        case .audio: meeting.isRecording ? ("Stop", "stop.fill", "meeting_stop", true) : ("Record Meeting", "waveform.circle", "meeting", false)
        }
        Button { plugin.action(actionID).map(plugin.perform) } label: { Label(title, systemImage: symbol) }
            .buttonStyle(.borderedProminent).tint(kind == .selfie ? .accentColor : .red)
            .help(stop ? "Stop recording (\(plugin.shortcutText(actionID)))" : "\(title) (\(plugin.shortcutText(actionID)))")
    }
}

/// One library: empty state, or (videos only) the quick-play strip and the tag columns.
private struct MediaBoard: View {
    let plugin: VideoNotesPlugin
    @ObservedObject var store: VideoStore
    let kind: MediaKind
    /// Tag columns in dashboard order; nil is Untagged.
    let columns: [String?]
    let search: String
    @ObservedObject var recorder: VideoRecorder
    @ObservedObject var meeting: MeetingRecorder

    var body: some View {
        if store.videos.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                HStack {
                    Text("\(store.videos.count) \(kind.noun)\(store.videos.count == 1 ? "" : "s") · \(formattedSize(store.totalSize))")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.top, 10)
                if kind == .video {
                    QuickSlotStrip(plugin: plugin, store: store)
                        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 4)
                }
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(columns, id: \.self) { column in
                            let tags = columns.compactMap { $0 }
                            let rank = column.flatMap { tags.firstIndex(of: $0) }
                            VideoColumn(plugin: plugin, store: store, kind: kind, tag: column, search: search,
                                        rank: rank.map { $0 + 1 }, isLast: rank == tags.count - 1)
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
    }

    private var emptyState: some View {
        let (title, hint): (String, String) = switch kind {
        case .video: ("No videos yet", "Press \(plugin.shortcutText("record")) anywhere to record one.")
        case .selfie: ("No selfies yet", "Press \(plugin.shortcutText("selfie")) to see yourself, and again to take the photo.")
        case .audio: ("No recordings yet", "Press \(plugin.shortcutText("meeting")) to record a meeting; it's transcribed when you stop.")
        }
        return VStack(spacing: 12) {
            Image(systemName: kind.symbol).font(.system(size: 44)).foregroundStyle(.tertiary)
            Text(title).font(.title3.weight(.semibold))
            Text(hint).foregroundStyle(.secondary)
            CaptureButton(plugin: plugin, kind: kind, recorder: recorder, meeting: meeting).controlSize(.large)
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
            guard let file = dropped.first else { return false }
            store.setSlot(slot, for: file)
            return true
        } isTargeted: { targeted = $0 }
    }
}

/// The Tag Order panel at the left of the dashboard: the tags in column order, ranked, with ↑ / ↓ on every row.
/// The board next to it follows immediately. Right-click a row for top / bottom / delete. Shown or hidden only from
/// the header's Tag Order button, so it can't be closed by accident.
private struct TagOrderPanel: View {
    let plugin: VideoNotesPlugin
    let tags: [String]
    let untaggedLast: Bool
    @State private var newTag = ""

    var body: some View {
        let counts = plugin.tagCounts
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Tag Order").font(.headline)
                Text("Columns follow this order. Put the important ones on top.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(Array(tags.enumerated()), id: \.element) { index, tag in
                        TagOrderRow(plugin: plugin, tag: tag, rank: index + 1, count: counts[tag] ?? 0,
                                    isFirst: index == 0, isLast: index == tags.count - 1)
                    }
                    if tags.isEmpty {
                        Text("No tags yet. Add one below.").font(.caption).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, minHeight: 40)
                    }
                }
                .padding(.horizontal, 10)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    TextField("New tag", text: $newTag).textFieldStyle(.roundedBorder).onSubmit(add)
                    Button("Add", action: add).disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Button { plugin.sortTagsByUse() } label: {
                    Label("Sort by Most Used", systemImage: "arrow.up.arrow.down").frame(maxWidth: .infinity)
                }
                .help("Busiest tags first")
                Toggle("Untagged as the last column", isOn: Binding(get: { untaggedLast },
                                                                    set: { v in try? plugin.update { $0.untaggedLast = v } }))
            }
            .controlSize(.small)
            .padding(14)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func add() {
        plugin.addTag(newTag)
        newTag = ""
    }
}

private struct TagOrderRow: View {
    let plugin: VideoNotesPlugin
    let tag: String
    let rank: Int
    let count: Int
    let isFirst: Bool
    let isLast: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            RankBadge(rank: rank)
            VStack(alignment: .leading, spacing: 0) {
                Text(tag).font(.callout.weight(.medium)).lineLimit(1)
                Text("\(count) item\(count == 1 ? "" : "s")").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                arrow("chevron.up", "Move up", disabled: isFirst) { plugin.moveTags([tag], .up) }
                arrow("chevron.down", "Move down", disabled: isLast) { plugin.moveTags([tag], .down) }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor).opacity(hovering ? 1 : 0.7)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(hovering ? 0.35 : 0.15)))
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Move to Top") { plugin.moveTags([tag], .top) }.disabled(isFirst)
            Button("Move to Bottom") { plugin.moveTags([tag], .bottom) }.disabled(isLast)
            Divider()
            Button("Delete Tag…", role: .destructive) { plugin.deleteTags([tag]) }
        }
    }

    private func arrow(_ symbol: String, _ help: String, disabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold)).frame(width: 24, height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(disabled ? 0 : 0.12)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? Color.secondary.opacity(0.3) : Color.primary)
        .disabled(disabled)
        .help(help)
    }
}

/// The tag's place in the order: shown in the Tag Order panel and on its column, so the two are easy to match.
struct RankBadge: View {
    let rank: Int

    var body: some View {
        Text("\(rank)")
            .font(.system(size: 11, weight: .bold, design: .rounded)).monospacedDigit()
            .frame(minWidth: 20, minHeight: 20)
            .background(Circle().fill(Color.accentColor))
            .foregroundStyle(.white)
    }
}

struct VideoColumn: View {
    let plugin: VideoNotesPlugin
    @ObservedObject var store: VideoStore
    var kind = MediaKind.video
    let tag: String?
    var search = ""
    /// Place in the tag order (1 = first); nil for Untagged.
    var rank: Int?
    var isLast = false
    @State private var targeted = false

    var body: some View {
        let all = store.videos.filter { $0.tag == tag }
        let query = search.trimmingCharacters(in: .whitespaces)
        let items = query.isEmpty ? all : all.filter {
            $0.title.localizedCaseInsensitiveContains(query) || ($0.tag ?? "").localizedCaseInsensitiveContains(query)
                || (store.transcripts[$0.file]?.localizedCaseInsensitiveContains(query) ?? false)
        }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if let rank { RankBadge(rank: rank) } else { Circle().fill(Color.secondary).frame(width: 8, height: 8).padding(.horizontal, 6) }
                Text(tag ?? "Untagged").font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("\(all.count)")
                    .font(.caption2.weight(.semibold)).monospacedDigit()
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formattedSize(all.reduce(0) { $0 + $1.size })).font(.caption2).foregroundStyle(.tertiary)
                if let tag, let rank {
                    HStack(spacing: 0) {
                        Button { plugin.moveTags([tag], .up) } label: { Image(systemName: "chevron.left").frame(width: 18, height: 18) }
                            .disabled(rank == 1).help("Move this column left")
                        Button { plugin.moveTags([tag], .down) } label: { Image(systemName: "chevron.right").frame(width: 18, height: 18) }
                            .disabled(isLast).help("Move this column right")
                    }
                    .buttonStyle(.borderless).font(.system(size: 10, weight: .bold))
                }
                if let tag {
                    Menu {
                        Button("Move to Front") { plugin.moveTags([tag], .top) }
                        Button("Move Left") { plugin.moveTags([tag], .up) }
                        Button("Move Right") { plugin.moveTags([tag], .down) }
                        Button("Move to End") { plugin.moveTags([tag], .bottom) }
                        Divider()
                        Button("Show Tag Order Panel") { plugin.arrangingTags = true }
                        Divider()
                        Button("Delete Tag…", role: .destructive) { plugin.deleteTags([tag]) }
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
            }
            .padding(.horizontal, 2)
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(items) { item in
                        if kind == .audio {
                            RecordingCard(plugin: plugin, store: store, item: item, query: query)
                        } else {
                            VideoCard(plugin: plugin, store: store, kind: kind, item: item)
                        }
                    }
                    if items.isEmpty {
                        Text(query.isEmpty ? "Drop \(kind.noun)s here" : "No matches")
                            .font(.caption).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, minHeight: 60)
                    }
                }
            }
        }
        .padding(10)
        .frame(width: all.isEmpty ? 190 : 260)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(targeted ? 0.2 : 0.07)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(targeted ? Color.accentColor : .clear, lineWidth: 2))
        .dropDestination(for: String.self) { dropped, _ in
            for file in dropped { store.update(file) { $0.tag = tag } }
            return !dropped.isEmpty
        } isTargeted: { targeted = $0 }
    }
}

/// A video or selfie: thumbnail on top, click to play (videos) or open in Preview (selfies).
private struct VideoCard: View {
    let plugin: VideoNotesPlugin
    @ObservedObject var store: VideoStore
    var kind = MediaKind.video
    let item: VideoItem
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .aspectRatio(kind == .selfie ? 4 / 3 : 16 / 9, contentMode: .fit)
                .overlay { Thumbnail(store: store, item: item) }
                .overlay {
                    if hovering {
                        ZStack {
                            Color.black.opacity(0.25)
                            Image(systemName: kind == .selfie ? "arrow.up.left.and.arrow.down.right.circle.fill" : "play.circle.fill")
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
            .onTapGesture { plugin.play(item, kind: kind) }

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
        if kind == .selfie {
            Button("Open in Preview") { plugin.play(item, kind: kind) }
            Button("Edit Tag & Note…") { plugin.edit(item.file, kind: kind) }
            Button("Show in Finder") { plugin.reveal(item, kind: kind) }
            Divider()
            Button("Move to Trash", role: .destructive) { plugin.delete(item, kind: kind) }
        } else {
            videoActions
        }
    }

    @ViewBuilder private var videoActions: some View {
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

/// A meeting recording and its transcript together: play the audio, open the transcript, and see its
/// first lines (or the lines matching the search).
private struct RecordingCard: View {
    @ObservedObject var plugin: VideoNotesPlugin
    @ObservedObject var store: VideoStore
    let item: VideoItem
    var query = ""
    @ObservedObject private var cache = Thumbnails.shared
    @State private var hovering = false

    var body: some View {
        let busy = plugin.transcribing.contains(item.file)
        let hasTranscript = store.transcripts[item.file] != nil
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "waveform").font(.system(size: 16, weight: .semibold)).foregroundStyle(.tint)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(0.12)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.callout.weight(.medium)).lineLimit(2)
                    Text(([item.created.formatted(date: .abbreviated, time: .shortened), cache.duration(for: item), formattedSize(item.size)] as [String?])
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Menu { actions } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .opacity(hovering ? 1 : 0.4)
            }
            if busy {
                Label(hasTranscript ? "Transcribing again…" : "Compressing & transcribing…", systemImage: "hourglass")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let lines = preview, !lines.isEmpty {
                Text(lines).font(.caption).foregroundStyle(.secondary).lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
                    .contentShape(Rectangle())
                    .onTapGesture { plugin.openTranscript(item) }
                    .help("Open the transcript")
            } else if !busy && !hasTranscript {
                Text("No transcript").font(.caption).foregroundStyle(.tertiary)
            }
            HStack(spacing: 8) {
                Button { plugin.play(item, kind: .audio) } label: { Label("Play", systemImage: "play.fill") }
                Button { plugin.openTranscript(item) } label: { Label("Transcript", systemImage: "doc.text") }
                    .disabled(!hasTranscript)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(hovering ? 0.4 : 0.2)))
        .shadow(color: .black.opacity(hovering ? 0.12 : 0.04), radius: hovering ? 6 : 2, y: 1)
        .onHover { hovering = $0 }
        .draggable(item.file)
        .contextMenu { actions }
        .task(id: Thumbnails.key(item)) {
            if let url = store.url(item) { await cache.load(item, url: url) }
        }
    }

    /// The transcript's lines after its header: the ones matching the search, or the first few.
    private var preview: String? {
        guard let text = store.transcripts[item.file] else { return nil }
        let lines = text.split(whereSeparator: \.isNewline).dropFirst(2).map(String.init).filter { !$0.isEmpty }
        let shown = query.isEmpty ? Array(lines.prefix(4)) : Array(lines.filter { $0.localizedCaseInsensitiveContains(query) }.prefix(4))
        return (shown.isEmpty ? Array(lines.prefix(4)) : shown).joined(separator: "\n")
    }

    @ViewBuilder private var actions: some View {
        Button("Play") { plugin.play(item, kind: .audio) }
        Button("Open Transcript") { plugin.openTranscript(item) }.disabled(store.transcripts[item.file] == nil)
        Button("Edit Tag & Note…") { plugin.edit(item.file, kind: .audio) }
        Button("Transcribe Again") { plugin.transcribeAgain(item) }.disabled(plugin.transcribing.contains(item.file))
        Button("Open in QuickTime Player") { plugin.openInDefaultPlayer(item, kind: .audio) }
        Button("Show in Finder") { plugin.reveal(item, kind: .audio) }
        Divider()
        Button("Move to Trash", role: .destructive) { plugin.delete(item, kind: .audio) }
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
                Image(systemName: store.kind.symbol).foregroundStyle(.tertiary)
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
        if MediaKind.selfie.extensions.contains(url.pathExtension.lowercased()) {
            // Photos: a downscaled copy, decoded off the main thread.
            let image = await Task.detached { () -> CGImage? in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 520,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ] as CFDictionary)
            }.value
            if let image { images[key] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)) }
            return
        }
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
