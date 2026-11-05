import AppKit
import SwiftUI

struct ReadAloudSettings: PluginSettings {
    /// Python with mlx-audio installed. Empty: look in <data>/venv, then conda/miniforge envs, then python3.
    var pythonPath = ""
    var voice = "af_heart"
    var speed = 1.0
    /// MLX memory limit and the hard cap on the engine's footprint (it exits when over; restarts on demand).
    var memoryLimitGB = 3.0
    /// Saved audio (also the "same text again" cache) is pruned, oldest first, above this size.
    var audioLimitMB = 500.0
    /// Minutes without a request before the engine exits and gives its memory back (0 = keep it running).
    var idleMinutes = 10.0

    enum CodingKeys: String, CodingKey {
        case pythonPath = "python_path", voice, speed, memoryLimitGB = "memory_limit_gb",
             audioLimitMB = "audio_limit_mb", idleMinutes = "idle_minutes"
    }
}

/// Screenshot → text (Apple Vision) → speech (Kokoro-82M on MLX, local). All files live in one folder:
/// <data>/models (model weights, HF_HOME) and <data>/audio (saved readings), so both can be cleared here.
@MainActor
final class ReadAloudPlugin: ObservableObject, Plugin {
    nonisolated static let pluginID = "read_aloud"

    let id = ReadAloudPlugin.pluginID
    let name = "Read Aloud"
    let summary = "Select part of the screen and hear its text, read by a local Kokoro voice (Apple Silicon, MLX)."
    let symbol = "speaker.wave.2.bubble"
    var enabledByDefault: Bool { false }
    let actions = [
        PluginAction(id: "read", title: "Read Screenshot Aloud", symbol: "text.viewfinder", defaultShortcut: nil),
        PluginAction(id: "clipboard", title: "Read Clipboard Aloud", symbol: "doc.on.clipboard", defaultShortcut: nil),
        PluginAction(id: "stop", title: "Stop Reading", symbol: "stop.circle", defaultShortcut: nil),
    ]

    private let engine = ReadAloudEngine()
    private var busy = false
    @Published private(set) var python: String?
    @Published private(set) var pythonChecked = false
    @Published private(set) var sizes: (models: Int64, audio: Int64) = (0, 0)

    var settings: ReadAloudSettings { state.settings(ReadAloudSettings.self, for: id) }
    func update(_ change: (inout ReadAloudSettings) -> Void) throws {
        try state.updateSettings(ReadAloudSettings.self, for: id, change)
    }
    func defaultSettings() -> [String: JSONValue] { encodeDefaults(ReadAloudSettings.self) }

    func validate(_ config: AppConfig) throws {
        let s = try config.settings(ReadAloudSettings.self, for: id)
        if s.memoryLimitGB < 1.5 { throw AppError("read_aloud.memory_limit_gb must be at least 1.5 (Kokoro peaks near 2.6 GB on long chunks; below that MLX just runs slower).") }
        if s.speed < 0.5 || s.speed > 2 { throw AppError("read_aloud.speed must be between 0.5 and 2.") }
    }

    nonisolated static var dataDir: URL { Paths.data(for: pluginID) }
    nonisolated static var modelsDir: URL { dataDir.appendingPathComponent("models", isDirectory: true) }
    nonisolated static var audioDir: URL { dataDir.appendingPathComponent("audio", isDirectory: true) }

    var isReady: Bool { python != nil || !pythonChecked }
    var setupIssues: [String] {
        var issues: [String] = []
        if pythonChecked && python == nil { issues.append("Read Aloud needs a Python with mlx-audio (see its Settings page).") }
        if !state.screenGranted { issues.append("Screen Recording permission is needed for screenshots.") }
        return issues
    }

    func activate() {
        engine.onStatus = { Toast.show($0, symbol: "speaker.slash", isError: true) }
        Task { await locatePython() }
    }

    func deactivate() { engine.shutdown() }

    func configDidChange() {
        // New limits/voice apply on the next start; restart only if the engine isn't busy speaking.
        if engine.isRunning && !engine.isPlaying { engine.shutdown() }
        Task { await locatePython() }
    }

    func showsInMenu(_ action: PluginAction) -> Bool { action.id != "stop" || engine.isPlaying }

    func perform(_ action: PluginAction) {
        switch action.id {
        case "stop": engine.stop()
        case "clipboard":
            guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
                Toast.show("The clipboard has no text.", symbol: "doc.on.clipboard", isError: true); return
            }
            Task { if await startEngine() { engine.speak(text, voice: settings.voice, speed: settings.speed) } }
        default:
            guard !busy else { return }
            busy = true
            Task { defer { busy = false }; await readScreenshot() }
        }
    }

    func menuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if let last = engine.lastAudio { items.append(ClosureMenuItem("Replay Last Reading", symbol: "arrow.counterclockwise") { [weak self] in self?.engine.replay(last) }) }
        items.append(ClosureMenuItem("Open Read Aloud Folder", symbol: "folder") { NSWorkspace.shared.open(Self.dataDir) })
        return items
    }

    // MARK: Flow

    private func readScreenshot() async {
        if !CGPreflightScreenCaptureAccess() {
            state.refreshPermissions(); state.showSettings?(id)
            Toast.show("Screen Recording permission is needed for screenshots.", symbol: "lock", isError: true); return
        }
        let engineStarted = Task { await startEngine() }   // loads the model while the region is being selected
        let shot = FileManager.default.temporaryDirectory.appendingPathComponent("qc-readaloud-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: shot) }
        _ = try? await Shell.run("/usr/sbin/screencapture", ["-i", "-x", "-o", shot.path], timeout: 600)
        guard let size = (try? shot.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0 else { return }  // Esc
        do {
            let text = try await ScreenOCR.text(in: shot)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                Toast.show("No text found in the selection.", symbol: "text.viewfinder", isError: true); return
            }
            guard await engineStarted.value else { return }
            engine.speak(text, voice: settings.voice, speed: settings.speed)
        } catch {
            Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle", isError: true)
        }
    }

    private func startEngine() async -> Bool {
        if engine.isRunning { return true }
        guard let python = await locatePython() else {
            state.showSettings?(id)
            Toast.show("Read Aloud needs a Python with mlx-audio — see its Settings page.", symbol: "speaker.slash", isError: true)
            return false
        }
        guard let script = Paths.resource("kokoro_server.py", plugin: id) else {
            Toast.show("kokoro_server.py is missing from the app bundle.", isError: true); return false
        }
        let s = settings
        try? FileManager.default.createDirectory(at: Self.modelsDir, withIntermediateDirectories: true)
        var env = await LoginEnvironment.shared.environment(for: python)
        env["HF_HOME"] = Self.modelsDir.path
        env["PYTHONUNBUFFERED"] = "1"
        let args = ["--models-dir", Self.modelsDir.path, "--audio-dir", Self.audioDir.path,
                    "--voice", s.voice, "--speed", String(s.speed), "--mem-limit-gb", String(s.memoryLimitGB),
                    "--audio-limit-mb", String(s.audioLimitMB), "--idle-exit", String(s.idleMinutes * 60)]
        do { try engine.start(.init(python: python, script: script.path, args: args, env: env)); return true } catch {
            Toast.show("Could not start the Read Aloud engine: \(error.localizedDescription)", isError: true); return false
        }
    }

    /// First Python that can `import mlx_audio`. Checked once per setting change; generic locations only.
    @discardableResult
    func locatePython() async -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var candidates: [String] = []
        let custom = (settings.pythonPath as NSString).expandingTildeInPath
        if !custom.isEmpty { candidates.append(custom) }
        else {
            candidates.append(Self.dataDir.appendingPathComponent("venv/bin/python").path)
            let bases = ["\(home)/miniconda3", "\(home)/miniforge3", "\(home)/anaconda3", "\(home)/mambaforge",
                         "/opt/homebrew/Caskroom/miniconda/base", "/opt/homebrew/Caskroom/miniforge/base",
                         "/opt/miniconda3", "/opt/anaconda3"]
            for base in bases {
                let envs = (base as NSString).appendingPathComponent("envs")
                for env in ((try? fm.contentsOfDirectory(atPath: envs)) ?? []).sorted() {
                    candidates.append("\(envs)/\(env)/bin/python")
                }
                candidates.append("\(base)/bin/python")
            }
            if let p3 = await LoginEnvironment.shared.find("python3") { candidates.append(p3) }
        }
        var found: String?
        for c in candidates where fm.isExecutableFile(atPath: c) {
            if let out = try? await Shell.run(c, ["-c", "import mlx_audio, misaki"], timeout: 30), out.status == 0 {
                found = c; break
            }
        }
        python = found
        pythonChecked = true
        return found
    }

    // MARK: Storage

    func refreshSizes() {
        Task.detached {
            let m = Self.folderSize(Self.modelsDir), a = Self.folderSize(Self.audioDir)
            await MainActor.run { self.sizes = (m, a) }
        }
    }

    nonisolated static func folderSize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e { total += Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0) }
        return total
    }

    func clear(_ url: URL) {
        engine.shutdown()
        try? FileManager.default.removeItem(at: url)
        refreshSizes()
    }

    func choosePython() {
        let panel = NSOpenPanel()
        panel.message = "Choose a python executable that has mlx-audio installed (e.g. <env>/bin/python)."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? update { $0.pythonPath = url.path }
    }

    func setupView() -> AnyView? { AnyView(ReadAloudSetup(plugin: self, state: state)) }
    func settingsView() -> AnyView? { AnyView(ReadAloudSettingsView(plugin: self, state: state)) }
}

private let installHint = "python3.11 -m venv \"\(ReadAloudPlugin.dataDir.path)/venv\" && \"\(ReadAloudPlugin.dataDir.path)/venv/bin/pip\" install mlx-audio misaki[en] soundfile"

private struct ReadAloudSetup: View {
    @ObservedObject var plugin: ReadAloudPlugin
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 10) {
            StepRow(done: plugin.python != nil, symbol: "terminal", title: "Python with mlx-audio",
                    detail: plugin.python ?? (plugin.pythonChecked ? "Not found. Install into this plugin's folder (deletable with it):\n\(installHint)" : "Looking…")) {
                HStack {
                    Button("Choose…") { plugin.choosePython() }
                    Button("Check Again") { Task { await plugin.locatePython() } }
                }
            }
            StepRow(done: state.screenGranted, symbol: "rectangle.dashed.badge.record", title: "Screen Recording",
                    detail: state.screenGranted ? "Granted — only the region you select is captured." : "Needed for screenshots.") {
                if !state.screenGranted { Button("Grant Access…") { state.requestScreenRecording() } }
            }
        }
    }
}

private struct ReadAloudSettingsView: View {
    @ObservedObject var plugin: ReadAloudPlugin
    @ObservedObject var state: AppState

    private func mb(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

    var body: some View {
        Section("Voice") {
            TextField("Voice (Kokoro id, e.g. af_heart, bf_emma, zf_xiaobei)", text: Binding(
                get: { plugin.settings.voice }, set: { v in try? plugin.update { $0.voice = v } }))
            Stepper(value: Binding(get: { plugin.settings.speed }, set: { v in try? plugin.update { $0.speed = v } }),
                    in: 0.5...2, step: 0.1) { Text(String(format: "Speed %.1f×", plugin.settings.speed)) }
        }
        Section("Memory") {
            Stepper(value: Binding(get: { plugin.settings.memoryLimitGB }, set: { v in try? plugin.update { $0.memoryLimitGB = v } }),
                    in: 1.5...16, step: 0.5) { Text(String(format: "Memory limit %.1f GB", plugin.settings.memoryLimitGB)) }
            Stepper(value: Binding(get: { plugin.settings.idleMinutes }, set: { v in try? plugin.update { $0.idleMinutes = v } }),
                    in: 0...120, step: 5) {
                Text(plugin.settings.idleMinutes == 0 ? "Keep the voice loaded" : "Unload the voice after \(Int(plugin.settings.idleMinutes)) idle min")
            }
            Text("The engine caps MLX's buffer cache, clears it after each reading, and exits if its footprint passes the limit.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Storage") {
            LabeledContent("Model (Kokoro-82M)", value: mb(plugin.sizes.models))
            LabeledContent("Saved audio", value: mb(plugin.sizes.audio))
            Stepper(value: Binding(get: { plugin.settings.audioLimitMB }, set: { v in try? plugin.update { $0.audioLimitMB = v } }),
                    in: 50...5000, step: 50) { Text("Keep at most \(Int(plugin.settings.audioLimitMB)) MB of audio") }
            HStack {
                Button("Show in Finder") { NSWorkspace.shared.open(ReadAloudPlugin.dataDir) }
                Button("Delete Saved Audio") { plugin.clear(ReadAloudPlugin.audioDir) }
                Button("Delete Model") { plugin.clear(ReadAloudPlugin.modelsDir) }
            }
            Text("The model downloads again (≈340 MB) on the next reading.").font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { plugin.refreshSizes() }
        ReadAloudSetup(plugin: plugin, state: state)
    }
}
