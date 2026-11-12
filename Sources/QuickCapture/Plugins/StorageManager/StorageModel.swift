import AppKit

struct DiskUsage {
    var total: Int64 = 0
    /// Free right now.
    var free: Int64 = 0
    /// Free plus what macOS gives back when it needs room (purgeable caches, snapshots): what Finder calls "available".
    var availableWithPurgeable: Int64 = 0
    var purgeable: Int64 { max(0, availableWithPurgeable - free) }
    var used: Int64 { total - availableWithPurgeable }
}

struct FolderEntry: Identifiable {
    let id: String          // full path
    let name: String
    let isDir: Bool
    var size: Int64?
    var locked = false
}

/// Scan results and cleaning for the Storage Manager window.
@MainActor
final class StorageModel: ObservableObject {
    @Published private(set) var items: [StorageItem] = []
    @Published private(set) var disk = DiskUsage()
    @Published private(set) var trashSize: Int64 = 0
    @Published private(set) var scanning = false
    @Published private(set) var scanned = 0
    @Published private(set) var total = 0
    @Published private(set) var cleaning = false
    @Published var selected = Set<String>()
    @Published var lastMessage: String?

    // Explorer
    @Published var explorerPath = StorageCatalog.home
    @Published private(set) var entries: [FolderEntry] = []
    @Published private(set) var exploring = false

    unowned let plugin: StorageManagerPlugin
    private var scanTask: Task<Void, Never>?
    private var exploreTask: Task<Void, Never>?

    init(plugin: StorageManagerPlugin) { self.plugin = plugin }

    // MARK: Disk

    func refreshDisk() {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        disk = DiskUsage(total: Int64(v?.volumeTotalCapacity ?? 0), free: Int64(v?.volumeAvailableCapacity ?? 0),
                         availableWithPurgeable: v?.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    // MARK: Cleanup scan

    func scan() {
        scanTask?.cancel()
        refreshDisk()
        let s = plugin.settings
        let roots = s.projectRoots.map { ($0 as NSString).expandingTildeInPath }
        let fixed = StorageCatalog.fixedItems(extraPaths: s.extraPaths, protectedPaths: s.protectedPaths)
        let minBytes = Int64(s.minDiscoveredMB) * 1_048_576
        scanning = true; scanned = 0; total = 0
        scanTask = Task { [weak self] in
            let found = await StorageCatalog.discover(projectRoots: roots)
            guard let self, !Task.isCancelled else { return }
            var all = (fixed + found).filter { item in item.paths.contains { FileManager.default.fileExists(atPath: $0) } }
            self.total = all.count
            self.items = all
            self.selected = self.selected.filter { id in all.contains { $0.id == id } }
            // Measure with a few `du` at a time.
            var next = 0
            await withTaskGroup(of: (Int, Int64, Date?).self) { group in
                func launch() {
                    guard next < all.count else { return }
                    let i = next; next += 1
                    let item = all[i]
                    group.addTask {
                        var sum: Int64 = 0
                        var mod: Date?
                        for p in item.paths where FileManager.default.fileExists(atPath: p) {
                            sum += await StorageOps.size(of: p)
                            if let m = StorageOps.newestModification(p) { mod = max(mod ?? .distantPast, m) }
                        }
                        return (i, sum, mod)
                    }
                }
                for _ in 0..<4 { launch() }
                for await (i, size, mod) in group {
                    if Task.isCancelled { group.cancelAll(); break }
                    all[i].size = size; all[i].modified = mod
                    self.scanned += 1
                    if self.scanned % 3 == 0 || self.scanned == all.count { self.items = all }
                    launch()
                }
            }
            guard !Task.isCancelled else { return }
            // Drop empty folders and small discovered ones.
            self.items = all.filter { ($0.size ?? 0) > 0 && (!$0.discovered || ($0.size ?? 0) >= minBytes) }
            self.trashSize = await StorageOps.size(of: StorageCatalog.h(".Trash"))
            self.refreshDisk()
            self.scanning = false
        }
    }

    var groups: [(name: String, items: [StorageItem])] {
        let order = ["Caches", "App caches", "Environments", "AI models", "Backups", "Your folders", "Protected"]
        let by = Dictionary(grouping: items, by: \.group)
        return by.keys.sorted { (order.firstIndex(of: $0) ?? 99, $0) < (order.firstIndex(of: $1) ?? 99, $1) }.map { k in
            (k, by[k]!.sorted { ($0.size ?? 0) > ($1.size ?? 0) })
        }
    }

    var selectedBytes: Int64 { items.filter { selected.contains($0.id) }.reduce(0) { $0 + ($1.size ?? 0) } }
    var safeItems: [StorageItem] { items.filter { $0.tier == .safe } }

    func selectAllSafe() { selected.formUnion(safeItems.map(\.id)) }

    // MARK: Cleaning

    func cleanSelected() {
        let chosen = items.filter { selected.contains($0.id) && $0.tier != .protected }
        guard !chosen.isEmpty else { return }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.localizedName))
        let blocked = chosen.filter { $0.app.map(running.contains) ?? false }
        let todo = chosen.filter { c in !blocked.contains { $0.id == c.id } }
        let deleted = todo.filter { $0.tier == .safe }, trashed = todo.filter { $0.tier == .review }
        let alert = NSAlert()
        alert.messageText = "Clean \(todo.count) item\(todo.count == 1 ? "" : "s") (about \(Fmt.bytes(todo.reduce(0) { $0 + ($1.size ?? 0) })))?"
        var lines: [String] = []
        if !deleted.isEmpty { lines.append("Emptied now: " + deleted.map(\.name).joined(separator: ", ")) }
        if !trashed.isEmpty { lines.append("Moved to the Trash (put back from there; space returns after Empty Trash): " + trashed.map(\.name).joined(separator: ", ")) }
        if !blocked.isEmpty { lines.append("Skipped, quit first: " + blocked.map { "\($0.name) (\($0.app ?? ""))" }.joined(separator: ", ")) }
        alert.informativeText = lines.joined(separator: "\n\n")
        alert.addButton(withTitle: "Clean")
        alert.addButton(withTitle: "Cancel")
        guard !todo.isEmpty, alert.runModal() == .alertFirstButtonReturn else {
            if todo.isEmpty { lastMessage = "Quit the apps first: " + blocked.compactMap(\.app).joined(separator: ", ") }
            return
        }
        let prot = plugin.settings.protectedPaths
        cleaning = true
        Task {
            var freed: Int64 = 0, failures: [String] = []
            for item in todo {
                do { freed += try await StorageOps.clean(item, protectedPaths: prot); selected.remove(item.id) }
                catch { failures.append("\(item.name): \(error.localizedDescription)") }
            }
            cleaning = false
            sizeCache = [:]
            let trashedBytes = trashed.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
            let emptiedBytes = max(0, freed - trashedBytes)
            lastMessage = (emptiedBytes > 0 ? "Freed \(Fmt.bytes(emptiedBytes)). " : "")
                + (trashedBytes > 0 ? "\(Fmt.bytes(trashedBytes)) is in the Trash: free space only grows after Empty Trash. " : "")
                + (failures.isEmpty ? "" : "\n" + failures.joined(separator: "\n"))
            Toast.show("Cleaned \(Fmt.bytes(freed))")
            scan()
        }
    }

    func emptyTrash() {
        let alert = NSAlert()
        alert.messageText = "Empty the Trash (\(Fmt.bytes(trashSize)))?"
        alert.informativeText = "This permanently deletes everything in the Trash."
        alert.addButton(withTitle: "Empty Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            _ = try? await Shell.run("/usr/bin/osascript", ["-e", "tell application \"Finder\" to empty trash"], timeout: 180)
            trashSize = await StorageOps.size(of: StorageCatalog.h(".Trash"))
            refreshDisk()
            Toast.show("Trash emptied")
        }
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // MARK: Mole (optional third-party cleaner)

    func moleAvailable() async -> Bool { await LoginEnvironment.shared.find("mo") != nil }

    func molePreview() async -> String {
        guard let mo = await LoginEnvironment.shared.find("mo") else { return "Mole (`mo`) is not installed." }
        let env = await LoginEnvironment.shared.environment(for: mo)
        guard let r = try? await Shell.run(mo, ["clean", "--dry-run"], environment: env, timeout: 240) else { return "Mole preview failed." }
        let text = (r.stdout + r.stderr).replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        return String(text.suffix(12000))
    }

    // MARK: Explorer

    /// Folder sizes already measured, so going back (or up) is instant. Cleared by Rescan and by Cleanup.
    private var sizeCache: [String: Int64] = [:]

    func explore(_ path: String, refresh: Bool = false) {
        exploreTask?.cancel()          // kills the du still running for the folder we are leaving
        explorerPath = path
        if refresh { for k in sizeCache.keys where k.hasPrefix(path + "/") { sizeCache[k] = nil } }
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: path)) ?? []).sorted()
        var list: [FolderEntry] = names.map { n in
            var isDir: ObjCBool = false
            let full = path + "/" + n
            fm.fileExists(atPath: full, isDirectory: &isDir)
            var e = FolderEntry(id: full, name: n, isDir: isDir.boolValue, size: sizeCache[full])
            e.locked = StorageOps.isUnreadable(full)
            return e
        }
        func publish() { self.entries = list.sorted { ($0.size ?? -1) > ($1.size ?? -1) } }
        publish()
        let todo = list.indices.filter { list[$0].size == nil }
        exploring = !todo.isEmpty
        guard !todo.isEmpty else { return }
        exploreTask = Task { [weak self] in
            await withTaskGroup(of: (Int, Int64).self) { group in
                for i in todo {
                    let p = list[i].id
                    group.addTask { (i, await StorageOps.size(of: p)) }   // waits for a free slot (4 at a time)
                }
                var done = 0
                for await (i, size) in group {
                    guard let self, !Task.isCancelled else { group.cancelAll(); return }
                    list[i].size = size
                    self.sizeCache[list[i].id] = size
                    done += 1
                    if done % 3 == 0 { publish() }
                }
            }
            guard let self, !Task.isCancelled, self.explorerPath == path else { return }
            publish()
            self.exploring = false
        }
    }

    func trashFromExplorer(_ e: FolderEntry) {
        let prot = plugin.settings.protectedPaths
        if let why = StorageOps.refusal(for: e.id, protectedPaths: prot) {
            lastMessage = "Won't touch \(e.name): \(why)"
            return
        }
        let alert = NSAlert()
        alert.messageText = "Move \(e.name) (\(Fmt.bytes(e.size ?? 0))) to the Trash?"
        alert.informativeText = e.id
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: e.id), resultingItemURL: nil)
            entries.removeAll { $0.id == e.id }
            // Keep the cache honest: the folder lost this much, and so did everything above it.
            sizeCache[e.id] = nil
            var up = (e.id as NSString).deletingLastPathComponent
            while up.count > 1 { if let v = sizeCache[up] { sizeCache[up] = max(0, v - (e.size ?? 0)) }; up = (up as NSString).deletingLastPathComponent }
            refreshDisk()
        } catch { lastMessage = error.localizedDescription }
    }
}

enum Fmt {
    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    static func age(_ date: Date?) -> String? {
        guard let date else { return nil }
        let days = Int(Date().timeIntervalSince(date) / 86400)
        if days < 30 { return nil }
        return days < 365 ? "untouched \(days / 30) mo" : String(format: "untouched %.1f yr", Double(days) / 365)
    }
}
