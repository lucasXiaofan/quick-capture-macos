import Foundation

/// How careful the app is with an item.
enum StorageTier: String {
    /// Regenerates by itself (caches). Emptied right away.
    case safe
    /// Environments, models, big folders you chose. Moved to the Trash so you can put them back.
    case review
    /// Never offered for cleaning.
    case protected
}

enum StorageMethod {
    /// Delete what is inside the folder, keep the folder.
    case empty
    case trash
    case command([String])
}

struct StorageItem: Identifiable {
    let id: String
    let group: String
    let name: String
    let desc: String
    let paths: [String]
    let tier: StorageTier
    var method: StorageMethod
    /// Name of an app that should be closed before cleaning (cache of a running app).
    var app: String?
    /// Shows file age ("untouched for 8 months") - helps decide on environments and models.
    var showsAge = false
    /// Found by scanning, not part of the fixed list: hidden when smaller than `min_discovered_mb`.
    var discovered = false

    // Filled in by a scan.
    var size: Int64?
    var modified: Date?
    var exists = true
}

/// What can be cleaned on this Mac. Everything is looked up at runtime (nothing assumes a user,
/// an app or a folder layout); a fixed list covers well-known caches, scans find the rest.
enum StorageCatalog {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    static func h(_ rel: String) -> String { home + "/" + rel }

    static let defaultProjectRoots = ["Documents", "Developer", "Projects", "Code", "code", "src", "Desktop", "dev", "repos", "github_repos"]

    static func condaBases() -> [String] {
        [h("miniconda3"), h("anaconda3"), h("miniforge3"), h("mambaforge"), h(".conda"), h("opt/miniconda3"),
         "/opt/homebrew/Caskroom/miniconda/base", "/opt/homebrew/anaconda3", "/opt/miniconda3", "/opt/anaconda3"]
            .filter { FileManager.default.fileExists(atPath: $0 + "/bin/conda") || FileManager.default.fileExists(atPath: $0 + "/envs") }
    }

    /// Protected by default: shown so you see why they are big, never offered for cleaning.
    static let builtInProtected: [(String, String, String)] = [
        ("Keychains", "Saved passwords and certificates.", "Library/Keychains"),
        ("SSH keys", "~/.ssh", ".ssh"),
        ("Photos & Pictures", "Your photos.", "Pictures"),
        ("iCloud Drive", "Synced documents; manage in System Settings → Apple ID → iCloud.", "Library/Mobile Documents"),
        ("Messages", "Your message history and attachments.", "Library/Messages"),
        ("Chrome profile", "Bookmarks, passwords, extensions.", "Library/Application Support/Google/Chrome"),
        ("iOS Simulators", "Remove through Xcode → Settings → Platforms.", "Library/Developer/CoreSimulator"),
        ("Docker / OrbStack data", "Containers and images. Use `docker system prune`.", "Library/Containers/com.docker.docker"),
        ("OrbStack data", "Your containers, images and volumes live in one disk image. Use `docker system prune` or OrbStack's settings.", "Library/Group Containers/HUAQ24HBR6.dev.orbstack"),
        ("Ollama models", "Use `ollama rm <model>`; deleting blobs by hand breaks them.", ".ollama/models"),
        ("macOS wallpapers", "Managed by macOS (System Settings → Wallpaper).", "Library/Application Support/com.apple.wallpaper"),
    ]

    /// The fixed part: well-known folders. Items whose folder does not exist are left out after the scan.
    static func fixedItems(extraPaths: [String], protectedPaths: [String]) -> [StorageItem] {
        var out: [StorageItem] = []
        func cache(_ id: String, _ name: String, _ desc: String, _ paths: [String], app: String? = nil,
                   tier: StorageTier = .safe, group: String = "Caches") {
            out.append(StorageItem(id: "cache-" + id, group: group, name: name, desc: desc, paths: paths, tier: tier,
                                   method: tier == .safe ? .empty : .trash, app: app))
        }
        cache("uv", "uv package cache", "Python wheels and builds cached by uv. Re-downloaded on demand.", [h(".cache/uv")])
        cache("pip", "pip cache", "Downloaded wheels. Re-downloaded on demand.", [h("Library/Caches/pip")])
        cache("npm", "npm cache", "Re-downloaded on demand.", [h(".npm/_cacache")])
        cache("yarn", "Yarn cache", "Re-downloaded on demand.", [h("Library/Caches/Yarn"), h(".cache/yarn")])
        cache("pnpm", "pnpm store", "Shared package store; `pnpm install` refills it.", [h("Library/pnpm/store"), h(".local/share/pnpm/store")], tier: .review)
        cache("cargo", "Cargo registry cache", "Downloaded crates and git checkouts; re-fetched when building.", [h(".cargo/registry"), h(".cargo/git")], tier: .review)
        cache("gradle", "Gradle caches", "Re-downloaded on the next build.", [h(".gradle/caches")])
        cache("cocoapods", "CocoaPods cache", "Re-downloaded on demand.", [h("Library/Caches/CocoaPods")])
        cache("brew", "Homebrew downloads", "Old bottles and downloads.", [h("Library/Caches/Homebrew")])
        cache("chrome", "Chrome cache", "Browser cache only, not your profile. Quit Chrome first.", [h("Library/Caches/Google")], app: "Google Chrome")
        cache("spotify", "Spotify cache", "Streamed-audio cache. Quit Spotify first.", [h("Library/Caches/com.spotify.client")], app: "Spotify")
        cache("derived", "Xcode DerivedData", "Build output; Xcode rebuilds it.", [h("Library/Developer/Xcode/DerivedData")])
        cache("devsupport", "Xcode iOS DeviceSupport", "Debug symbols for devices you plugged in; re-created on reconnect.", [h("Library/Developer/Xcode/iOS DeviceSupport")])
        cache("archives", "Xcode Archives", "App archives you built. Keep the ones you may need to submit or symbolicate.", [h("Library/Developer/Xcode/Archives")], tier: .review)
        cache("playwright", "Playwright browsers", "Test browsers; reinstall with `playwright install`.", [h("Library/Caches/ms-playwright"), h("Library/Caches/ms-playwright-go")], tier: .review)
        cache("chroma", "Chroma embedding model cache", "ONNX embedding model; re-downloaded on use.", [h(".cache/chroma")])
        cache("logs", "User logs", "Diagnostic logs apps wrote. Safe to remove.", [h("Library/Logs")])
        cache("backups", "iPhone / iPad backups", "Local device backups made by Finder. You lose them unless they are also in iCloud.",
              [h("Library/Application Support/MobileSync/Backup")], tier: .review, group: "Backups")

        for base in condaBases() {
            cache("condapkgs-" + base, "Conda package cache", "Tarballs of installed packages (`conda clean --all`). \(base)", [base + "/pkgs"])
        }

        // Models.
        func model(_ id: String, _ name: String, _ desc: String, _ path: String) {
            out.append(StorageItem(id: id, group: "AI models", name: name, desc: desc, paths: [path], tier: .review,
                                   method: .trash, showsAge: true))
        }
        for root in [h(".lmstudio/models"), h(".cache/lm-studio/models")] {
            for pub in subfolders(root) {
                for m in subfolders(pub) {
                    model("lms-" + m, "LM Studio: " + (m as NSString).lastPathComponent,
                          "Local model installed through LM Studio. Download it again from LM Studio any time.", m)
                }
            }
        }
        for m in subfolders(h(".cache/huggingface/hub")) {
            let n = (m as NSString).lastPathComponent
            guard n.hasPrefix("models--") || n.hasPrefix("datasets--") || n.hasPrefix("spaces--") else { continue }
            let pretty = n.replacingOccurrences(of: "models--", with: "model: ").replacingOccurrences(of: "datasets--", with: "dataset: ")
                .replacingOccurrences(of: "--", with: "/")
            model("hf-" + n, "Hugging Face " + pretty, "Hugging Face cache. Re-downloaded on demand.", m)
        }
        if FileManager.default.fileExists(atPath: h(".cache/whisper")) {
            model("whisper", "Whisper models", "Speech models in ~/.cache/whisper. Re-downloaded on use.", h(".cache/whisper"))
        }

        // Environments.
        for base in condaBases() {
            for e in subfolders(base + "/envs") {
                let n = (e as NSString).lastPathComponent
                out.append(StorageItem(id: "conda-\(base)-\(n)", group: "Environments", name: "conda env: \(n)",
                                       desc: "Conda environment. Removed with `conda env remove`.", paths: [e], tier: .review,
                                       method: .command([base + "/bin/conda", "env", "remove", "-y", "-p", e]), showsAge: true))
            }
        }

        // Folders you added yourself.
        for p in extraPaths where FileManager.default.fileExists(atPath: p) {
            out.append(StorageItem(id: "custom-" + p, group: "Your folders", name: (p as NSString).lastPathComponent,
                                   desc: "Added by you. Moved to the Trash.", paths: [p], tier: .review, method: .trash, showsAge: true))
        }

        // Protected.
        for (name, why, rel) in builtInProtected {
            out.append(StorageItem(id: "prot-" + rel, group: "Protected", name: name, desc: why, paths: [h(rel)], tier: .protected, method: .trash))
        }
        for p in protectedPaths {
            out.append(StorageItem(id: "prot-user-" + p, group: "Protected", name: (p as NSString).lastPathComponent,
                                   desc: "Protected by you.", paths: [p], tier: .protected, method: .trash))
        }
        return out
    }

    /// Environments and big caches found by looking around. Runs off the main thread.
    static func discover(projectRoots: [String]) async -> [StorageItem] {
        var out: [StorageItem] = []
        let fm = FileManager.default
        for root in projectRoots where fm.fileExists(atPath: root) {
            let args = [root, "-maxdepth", "5", "(", "-name", ".git", "-o", "-name", "Library", "-o", "-name", ".Trash", "-o", "-name", "site-packages", ")",
                        "-prune", "-o", "(", "-name", "node_modules", "-o", "-name", ".venv", "-o", "-name", "venv", ")", "-type", "d", "-print", "-prune"]
            guard let r = try? await Shell.run("/usr/bin/find", args, timeout: 60) else { continue }
            for line in r.stdout.split(separator: "\n").map(String.init) {
                let name = (line as NSString).lastPathComponent
                // "venv" is also an ordinary folder name: only believe it when it has pyvenv.cfg.
                if name != "node_modules", !fm.fileExists(atPath: line + "/pyvenv.cfg") { continue }
                let proj = ((line as NSString).deletingLastPathComponent as NSString).lastPathComponent
                let isNode = name == "node_modules"
                out.append(StorageItem(id: "env-" + line, group: "Environments", name: "\(proj)/\(name)",
                                       desc: isNode ? "JS dependencies; `npm install` restores them." : "Python virtualenv. Recreate it from requirements if needed.",
                                       paths: [line], tier: .review, method: .trash, showsAge: true, discovered: true))
            }
        }
        // Every folder in ~/Library/Caches that has grown big.
        for c in subfolders(h("Library/Caches")) {
            let n = (c as NSString).lastPathComponent
            out.append(StorageItem(id: "libcache-" + n, group: "App caches", name: n, desc: "Cache folder in ~/Library/Caches. Apps rebuild it; quit the app first.",
                                   paths: [c], tier: .review, method: .trash, discovered: true))
        }
        return out
    }

    static func subfolders(_ path: String) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: path) else { return [] }
        return names.filter { !$0.hasPrefix(".") || $0 == ".cache" }.sorted().map { path + "/" + $0 }.filter {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue
        }
    }
}

/// Measuring and the safety rules for deleting.
enum StorageOps {
    /// Size in bytes. At most 4 `du` run at once across the whole app, and a `du` is killed the moment its
    /// task is cancelled (you navigated away or rescanned), so nothing piles up in the background.
    /// If `du` gives nothing, the folder is walked directly, skipping what macOS won't let us read.
    static func size(of path: String) async -> Int64 {
        await DuLimiter.shared.acquire()
        defer { Task { await DuLimiter.shared.release() } }
        if Task.isCancelled { return 0 }
        let out = await runDu(path)
        if Task.isCancelled { return 0 }
        if let first = out.split(whereSeparator: { $0 == "\t" || $0 == "\n" }).first, let kb = Int64(first) { return kb * 1024 }
        return walk(path)
    }

    private final class ProcessBox: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false
        func set(_ p: Process) -> Bool { lock.lock(); defer { lock.unlock() }; if cancelled { return false }; process = p; return true }
        func kill() { lock.lock(); cancelled = true; let p = process; lock.unlock(); if let p, p.isRunning { p.terminate() } }
    }

    private static func runDu(_ path: String) async -> String {
        let box = ProcessBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/du")
                p.arguments = ["-sk", path]
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                p.standardInput = FileHandle.nullDevice
                p.terminationHandler = { _ in
                    cont.resume(returning: String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
                }
                guard box.set(p) else { cont.resume(returning: ""); return }
                do { try p.run() } catch { cont.resume(returning: ""); return }
                DispatchQueue.global().asyncAfter(deadline: .now() + 300) { box.kill() }
            }
        } onCancel: { box.kill() }
    }

    private static func walk(_ path: String) -> Int64 {
        let url = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return 0 }
        var sum: Int64 = 0
        for case let f as URL in e {
            if Task.isCancelled { break }
            guard let v = try? f.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            sum += Int64(v.totalFileAllocatedSize ?? 0)
        }
        return sum
    }

    /// True when the folder itself can't be listed (macOS privacy protection): its size is unknown, not zero.
    static func isUnreadable(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return false }
        return (try? FileManager.default.contentsOfDirectory(atPath: path)) == nil
    }

    static func newestModification(_ path: String) -> Date? {
        let fm = FileManager.default
        let own = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        let kids = (try? fm.contentsOfDirectory(atPath: path)) ?? []
        let newest = kids.prefix(500).compactMap { (try? fm.attributesOfItem(atPath: path + "/" + $0))?[.modificationDate] as? Date }.max()
        return [own, newest].compactMap { $0 }.max()
    }

    /// Cleaning is limited to places inside your home folder (or a conda install), at least two levels
    /// down, never a protected folder or something that contains one.
    static func refusal(for path: String, protectedPaths: [String]) -> String? {
        let real = (path as NSString).resolvingSymlinksInPath
        let roots = [StorageCatalog.home] + StorageCatalog.condaBases()
        guard let root = roots.first(where: { real.hasPrefix($0 + "/") }) else { return "Outside your home folder." }
        let depth = real.dropFirst(root.count + 1).split(separator: "/").count
        if depth < 2 && root == StorageCatalog.home { return "Too close to the top of your home folder." }
        let prot = StorageCatalog.builtInProtected.map { StorageCatalog.h($0.2) } + protectedPaths
        for p in prot where real == p || real.hasPrefix(p + "/") || p.hasPrefix(real + "/") { return "Contains or is inside a protected folder (\(p))." }
        return nil
    }

    /// Returns the bytes freed (or moved to the Trash).
    static func clean(_ item: StorageItem, protectedPaths: [String]) async throws -> Int64 {
        guard item.tier != .protected else { throw AppError("Protected.") }
        let fm = FileManager.default
        var freed: Int64 = 0
        for p in item.paths where fm.fileExists(atPath: p) {
            if let why = refusal(for: p, protectedPaths: protectedPaths) { throw AppError("Refused \(p): \(why)") }
            freed += await size(of: p)
            switch item.method {
            case .command(let argv):
                let r = try await Shell.run(argv[0], Array(argv.dropFirst()), environment: await LoginEnvironment.shared.environment(for: argv[0]), timeout: 600)
                if r.status != 0 { throw AppError(String((r.stderr.isEmpty ? r.stdout : r.stderr).suffix(300))) }
            case .trash:
                try fm.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: nil)
            case .empty:
                for e in try fm.contentsOfDirectory(atPath: p) { try? fm.removeItem(atPath: p + "/" + e) }
            }
        }
        return freed
    }
}

/// Lets a few `du` run at a time; the rest wait their turn.
actor DuLimiter {
    static let shared = DuLimiter()
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func acquire() async {
        if running < 4 { running += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        if waiters.isEmpty { running -= 1 } else { waiters.removeFirst().resume() }
    }
}
