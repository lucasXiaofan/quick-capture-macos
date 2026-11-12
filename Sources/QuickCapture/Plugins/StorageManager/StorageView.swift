import AppKit
import SwiftUI

struct StorageView: View {
    @ObservedObject var model: StorageModel
    @State private var tab = 0
    @State private var mole: String?
    @State private var hasMole = false

    var body: some View {
        VStack(spacing: 0) {
            header.padding([.horizontal, .top], 20).padding(.bottom, 12)
            Picker("", selection: $tab) {
                Text("Cleanup").tag(0)
                Text("Explore").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 220).padding(.bottom, 10)
            Divider()
            if tab == 0 { cleanup } else { explorer }
        }
        .frame(minWidth: 700, minHeight: 520)
        .task { hasMole = await model.moleAvailable() }
        .onChange(of: tab) { t in if t == 1 && model.entries.isEmpty { model.explore(model.explorerPath) } }
        .sheet(item: Binding(get: { mole.map { Wrapper(text: $0) } }, set: { if $0 == nil { mole = nil } })) { w in
            VStack(alignment: .leading) {
                Text("Mole preview (nothing deleted)").font(.headline)
                ScrollView { Text(w.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack { Spacer(); Button("Close") { mole = nil }.keyboardShortcut(.cancelAction) }
            }.padding(20).frame(width: 640, height: 480)
        }
    }

    private struct Wrapper: Identifiable { let text: String; var id: String { text } }

    // MARK: Header

    private var header: some View {
        let d = model.disk
        let frac = d.total > 0 ? Double(d.used) / Double(d.total) : 0
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading) {
                    Text("\(Fmt.bytes(d.free)) free").font(.title2.bold())
                    Text("\(Fmt.bytes(d.used)) used of \(Fmt.bytes(d.total))" + (d.purgeable > 1_000_000_000 ? " · plus \(Fmt.bytes(d.purgeable)) purgeable that macOS frees when needed" : ""))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.emptyTrash() } label: { Label("Empty Trash (\(Fmt.bytes(model.trashSize)))", systemImage: "trash") }
                    .disabled(model.trashSize == 0)
                if hasMole {
                    Button("Mole Preview") { Task { mole = await model.molePreview() } }
                }
                Button { if tab == 0 { model.scan() } else { model.explore(model.explorerPath, refresh: true) } } label: { Label("Rescan", systemImage: "arrow.clockwise") }.disabled(tab == 0 && model.scanning)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.25))
                    RoundedRectangle(cornerRadius: 4).fill(frac > 0.9 ? Color.red : frac > 0.8 ? Color.orange : Color.blue)
                        .frame(width: geo.size.width * frac)
                }
            }.frame(height: 14)
            if model.scanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.total == 0 ? "Looking around…" : "Measuring \(model.scanned) of \(model.total)…").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let m = model.lastMessage {
                HStack(alignment: .top) {
                    Text(m).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { model.lastMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }
            }
        }
    }

    // MARK: Cleanup

    private var cleanup: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14, pinnedViews: []) {
                    ForEach(model.groups, id: \.name) { g in
                        let sum = g.items.reduce(0) { $0 + ($1.size ?? 0) }
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(g.name).font(.headline)
                                Text(Fmt.bytes(sum)).font(.callout).foregroundStyle(.secondary)
                                Spacer()
                                if g.name != "Protected" {
                                    Button("Select all") { model.selected.formUnion(g.items.map(\.id)) }.buttonStyle(.link).font(.caption)
                                }
                            }
                            if g.name == "Protected" {
                                Text("Big, but not offered for cleaning.").font(.caption).foregroundStyle(.secondary)
                            }
                            let maxSize = Double(g.items.compactMap(\.size).max() ?? 1)
                            ForEach(g.items) { item in row(item, maxSize: maxSize) }
                        }
                    }
                    if model.items.isEmpty && !model.scanning {
                        Text("Nothing found.").foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
            Divider()
            HStack {
                Button("Select All Safe") { model.selectAllSafe() }.disabled(model.safeItems.isEmpty)
                Button("Clear Selection") { model.selected = [] }.disabled(model.selected.isEmpty)
                Spacer()
                Text("\(model.selected.count) selected · \(Fmt.bytes(model.selectedBytes))").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                Button("Clean Selected…") { model.cleanSelected() }
                    .buttonStyle(.borderedProminent).disabled(model.selected.isEmpty || model.cleaning || model.scanning)
            }
            .padding(12)
        }
    }

    private func row(_ item: StorageItem, maxSize: Double) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if item.tier == .protected {
                Image(systemName: "lock.fill").foregroundStyle(.secondary).frame(width: 18)
            } else {
                Toggle("", isOn: Binding(get: { model.selected.contains(item.id) },
                                         set: { if $0 { model.selected.insert(item.id) } else { model.selected.remove(item.id) } }))
                    .toggleStyle(.checkbox).labelsHidden()
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name)
                    if item.tier == .safe { chip("safe", .green) } else if item.tier == .review { chip("→ Trash", .orange) }
                    if item.showsAge, let age = Fmt.age(item.modified) { chip(age, .gray) }
                    if let app = item.app { chip("quit \(app)", .gray) }
                }
                Text(item.desc).font(.caption).foregroundStyle(.secondary)
                Text(item.paths.first.map { $0.replacingOccurrences(of: StorageCatalog.home, with: "~") } ?? "")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(item.size.map(Fmt.bytes) ?? "…").font(.callout.monospacedDigit())
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.6))
                        .frame(width: geo.size.width * CGFloat((Double(item.size ?? 0)) / max(maxSize, 1)))
                }.frame(width: 80, height: 4)
            }
            Button { item.paths.first.map(model.reveal) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless).help("Show in Finder")
        }
        .padding(.vertical, 3)
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 9, weight: .medium)).padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule()).foregroundStyle(color == .gray ? .secondary : color)
    }

    // MARK: Explore

    private var explorer: some View {
        let home = StorageCatalog.home
        let path = model.explorerPath
        let parent = (path as NSString).deletingLastPathComponent
        let maxSize = Double(model.entries.compactMap(\.size).max() ?? 1)
        return VStack(spacing: 0) {
            HStack {
                Button { model.explore(parent) } label: { Image(systemName: "chevron.up") }
                    .disabled(path == home || !path.hasPrefix(home))
                Text(path.replacingOccurrences(of: home, with: "~")).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.head)
                Spacer()
                if model.exploring { ProgressView().controlSize(.small) }
                Button("Home") { model.explore(home) }
                Button("Library") { model.explore(home + "/Library") }
            }.padding(12)
            Divider()
            List(model.entries) { e in
                HStack {
                    Image(systemName: e.isDir ? "folder.fill" : "doc").foregroundStyle(e.isDir ? Color.accentColor : .secondary).frame(width: 20)
                    Text(e.name).lineLimit(1)
                    Spacer()
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.5))
                            .frame(width: geo.size.width * CGFloat(Double(e.size ?? 0) / max(maxSize, 1)))
                    }.frame(width: 100, height: 5)
                    Text(e.locked ? "no access" : (e.size == 0 && e.isDir ? "empty" : e.size.map(Fmt.bytes) ?? "…")).font(.callout.monospacedDigit()).frame(width: 80, alignment: .trailing)
                    Button { model.reveal(e.id) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless).help("Show in Finder")
                    Button { model.trashFromExplorer(e) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Move to Trash")
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { if e.isDir { model.explore(e.id) } }
            }
            Text("Double-click a folder to open it. Moving to the Trash is blocked for protected folders and anything outside your home folder.")
                .font(.caption).foregroundStyle(.secondary).padding(8)
        }
    }
}
