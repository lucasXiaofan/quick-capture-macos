import Foundation

struct VideoItem: Codable, Identifiable, Equatable {
    var file: String
    var tag: String?
    var note = ""
    var created: Date
    /// Quick-play slot 1…5.
    var slot: Int?
    /// Already run through `VideoCompressor`.
    var compressed = false
    /// `VideoCompressor.version` it was compressed with; older ones can be compressed again.
    var compressionVersion = 0
    /// Screen + camera recording (compressed with the screen target).
    var screen = false
    /// Bytes on disk; read from the file, not stored in the index.
    var size: Int64 = 0

    var id: String { file }
    var displayName: String { (file as NSString).deletingPathExtension }
    var title: String { note.isEmpty ? displayName : note }

    enum CodingKeys: String, CodingKey { case file, tag, note, created, slot, compressed, screen
        case compressionVersion = "compression_version"
    }

    init(file: String, created: Date) {
        self.file = file
        self.created = created
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        file = try c.decode(String.self, forKey: .file)
        tag = try c.decodeIfPresent(String.self, forKey: .tag)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        slot = try c.decodeIfPresent(Int.self, forKey: .slot)
        compressed = try c.decodeIfPresent(Bool.self, forKey: .compressed) ?? false
        screen = try c.decodeIfPresent(Bool.self, forKey: .screen) ?? false
        compressionVersion = try c.decodeIfPresent(Int.self, forKey: .compressionVersion) ?? (compressed ? 1 : 0)
    }
}

/// The videos in the library folder plus an `index.json` next to them holding tag, note and quick slot.
@MainActor
final class VideoStore: ObservableObject {
    static let slotCount = 5
    private static let extensions: Set<String> = ["mov", "mp4", "m4v"]

    @Published private(set) var videos: [VideoItem] = []   // newest first
    /// Files being compressed right now.
    @Published private(set) var busy: Set<String> = []
    private(set) var directory: URL?

    var totalSize: Int64 { videos.reduce(0) { $0 + $1.size } }

    func video(_ file: String) -> VideoItem? { videos.first { $0.file == file } }
    func video(slot: Int) -> VideoItem? { videos.first { $0.slot == slot } }
    func url(_ item: VideoItem) -> URL? { directory?.appendingPathComponent(item.file) }

    /// Reads the folder: files without an entry become untagged videos, entries without a file disappear.
    func load(from dir: URL) {
        directory = dir
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var saved: [String: VideoItem] = [:]
        if let data = try? Data(contentsOf: indexURL(dir)),
           let index = try? Self.decoder.decode(Index.self, from: data) {
            for v in index.videos { saved[v.file] = v }
        }
        let keys: [URLResourceKey] = [.fileSizeKey, .creationDateKey]
        let urls = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
        videos = urls.filter { Self.extensions.contains($0.pathExtension.lowercased()) }.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            var item = saved[url.lastPathComponent]
                ?? VideoItem(file: url.lastPathComponent, created: values?.creationDate ?? Date())
            item.size = Int64(values?.fileSize ?? 0)
            return item
        }.sorted { $0.created > $1.created }
    }

    func setBusy(_ file: String, _ on: Bool) {
        if on { busy.insert(file) } else { busy.remove(file) }
    }

    func update(_ file: String, _ change: (inout VideoItem) -> Void) {
        guard let i = videos.firstIndex(where: { $0.file == file }) else { return }
        change(&videos[i])
        save()
    }

    /// One video per slot: giving a slot to a video takes it from the previous owner.
    func setSlot(_ slot: Int?, for file: String) {
        for i in videos.indices where videos[i].slot == slot && slot != nil { videos[i].slot = nil }
        update(file) { $0.slot = slot }
    }

    /// Videos with any of these tags become untagged; nothing is deleted.
    func clearTags(_ names: Set<String>) {
        for i in videos.indices where videos[i].tag.map(names.contains) == true { videos[i].tag = nil }
        save()
    }

    func delete(_ file: String) throws {
        guard let dir = directory else { return }
        try FileManager.default.trashItem(at: dir.appendingPathComponent(file), resultingItemURL: nil)
        videos.removeAll { $0.file == file }
        save()
    }

    // MARK: Persistence

    private struct Index: Codable { var videos: [VideoItem] }

    private func indexURL(_ dir: URL) -> URL { dir.appendingPathComponent("index.json") }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func save() {
        guard let dir = directory else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(Index(videos: videos)) { try? data.write(to: indexURL(dir), options: .atomic) }
    }
}

func formattedSize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
