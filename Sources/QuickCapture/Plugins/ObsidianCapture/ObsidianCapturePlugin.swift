import AppKit
import SwiftUI

enum CaptureAction: String, CaseIterable {
    case image, text, diary_image, diary_text

    var isImage: Bool { self == .image || self == .diary_image }
    var forcesDiary: Bool { self == .diary_image || self == .diary_text }
}

struct ObsidianSettings: PluginSettings {
    var vault = ""
    var obsidian = "/Applications/Obsidian.app/Contents/MacOS/obsidian"
    var diaryFolder = "Daily"
    var diaryFormat = "YYYY-MM-DD"
    var template = ""
    var destinationMode = "current"

    enum CodingKeys: String, CodingKey {
        case vault, obsidian, template
        case diaryFolder = "diary_folder", diaryFormat = "diary_format", destinationMode = "destination_mode"
    }

    var vaultURL: URL? {
        vault.isEmpty ? nil : URL(fileURLWithPath: (vault as NSString).expandingTildeInPath).standardizedFileURL
    }
    var diaryOnly: Bool { destinationMode == "diary" }

    /// Imports Daily Notes folder/template/format from the vault's own settings.
    mutating func importDailyNotesSettings() {
        guard let vault = vaultURL,
              let data = try? Data(contentsOf: vault.appendingPathComponent(".obsidian/daily-notes.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        diaryFolder = (json["folder"] as? String) ?? ""
        if let t = json["template"] as? String, !t.isEmpty { template = t.hasSuffix(".md") ? t : t + ".md" }
        if let f = json["format"] as? String, !f.isEmpty { diaryFormat = f }
    }
}

enum CLIStatus: Equatable {
    case unknown, checking, ok, failed(String)
}

/// Screenshot or text capture into the active Obsidian note (at the cursor) or today's diary.
@MainActor
final class ObsidianCapturePlugin: ObservableObject, Plugin {
    nonisolated static let pluginID = "obsidian_capture"
    static let recovery = Paths.home.appendingPathComponent("recovery", isDirectory: true)

    let id = ObsidianCapturePlugin.pluginID
    let name = "Obsidian Capture"
    let summary = "Screenshot or jot a note into the active Obsidian note, at the cursor, or into today's diary."
    let symbol = "camera.viewfinder"
    /// On for new users only if Obsidian is installed.
    var enabledByDefault: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "md.obsidian") != nil }
    let actions = [
        PluginAction(id: CaptureAction.image.rawValue, title: "Screenshot → Current Note", symbol: "camera.viewfinder",
                     defaultShortcut: "<cmd>+<shift>+i"),
        PluginAction(id: CaptureAction.text.rawValue, title: "Note → Current Note", symbol: "square.and.pencil",
                     defaultShortcut: "<cmd>+<shift>+j"),
        PluginAction(id: CaptureAction.diary_image.rawValue, title: "Screenshot → Today's Diary", symbol: "camera.viewfinder",
                     defaultShortcut: "<cmd>+<shift>+<alt>+i"),
        PluginAction(id: CaptureAction.diary_text.rawValue, title: "Note → Today's Diary", symbol: "square.and.pencil",
                     defaultShortcut: "<cmd>+<shift>+<alt>+j"),
    ]

    @Published var cli: CLIStatus = .unknown
    private lazy var capture = CaptureController(plugin: self)

    var settings: ObsidianSettings { state.settings(ObsidianSettings.self, for: id) }
    var isSetUp: Bool { settings.vaultURL != nil }

    func perform(_ action: PluginAction) {
        guard let capture = CaptureAction(rawValue: action.id) else { return }
        self.capture.run(capture)
    }

    func update(_ change: (inout ObsidianSettings) -> Void) throws {
        try state.updateSettings(ObsidianSettings.self, for: id, change)
    }

    func defaultSettings() -> [String: JSONValue] { encodeDefaults(ObsidianSettings.self) }

    func validate(_ config: AppConfig) throws {
        let s = try config.settings(ObsidianSettings.self, for: id)
        guard ["current", "diary"].contains(s.destinationMode) else {
            throw AppError("destination_mode must be \"current\" or \"diary\".")
        }
    }

    func activate() { Task { await checkCLI() } }

    var isReady: Bool { isSetUp }

    var setupIssues: [String] {
        var issues: [String] = []
        if !isSetUp { issues.append("Choose your Obsidian vault.") }
        if !state.screenGranted { issues.append("Screen Recording permission is needed for screenshots.") }
        return issues
    }

    func openSetup() { state.showSettings?(id) }

    // MARK: Menu

    func menuItems() -> [NSMenuItem] {
        let current = settings
        let dest = NSMenuItem(title: "Main Shortcuts Save To", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (title, mode) in [("Current Note (at cursor)", "current"), ("Today's Diary", "diary")] {
            let item = ClosureMenuItem(title) { [weak self] in try? self?.update { $0.destinationMode = mode } }
            item.state = current.destinationMode == mode ? .on : .off
            sub.addItem(item)
        }
        dest.submenu = sub
        var items: [NSMenuItem] = [dest]

        let today = ClosureMenuItem("Open Today's Diary") { [weak self] in self?.openDiary() }
        today.isEnabled = isSetUp
        items.append(today)

        return items
    }

    /// The main screenshot and note shortcuts (they follow "Main Shortcuts Save To").
    func primaryActions() -> [PluginAction] { [CaptureAction.image, .text].compactMap { action($0.rawValue) } }

    func menuAlerts() -> [NSMenuItem] {
        let recoveryCount = (try? FileManager.default.contentsOfDirectory(atPath: Self.recovery.path))?
            .filter { $0.hasSuffix(".md") }.count ?? 0
        guard recoveryCount > 0 else { return [] }
        return [ClosureMenuItem("Unsaved Captures (\(recoveryCount))…", symbol: "exclamationmark.triangle") {
            NSWorkspace.shared.open(Self.recovery)
        }]
    }

    private func openDiary() {
        let config = settings
        guard let vault = config.vaultURL else { return }
        let path = VaultLayout(config: config, vault: vault, now: Date()).diaryPath
        var c = URLComponents(string: "obsidian://open")!
        c.queryItems = [URLQueryItem(name: "vault", value: vault.lastPathComponent),
                        URLQueryItem(name: "file", value: path)]
        if FileManager.default.fileExists(atPath: vault.appendingPathComponent(path).path), let url = c.url {
            NSWorkspace.shared.open(url)
        } else {
            Toast.show("No diary yet today — it's created on your first capture.", symbol: "calendar")
        }
    }

    // MARK: Vault & Obsidian connection

    func chooseVault() {
        let panel = NSOpenPanel()
        panel.message = "Choose your Obsidian vault folder (the folder that contains .obsidian)."
        panel.prompt = "Use This Vault"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = settings.vaultURL ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent(".obsidian").path) else {
            let alert = NSAlert()
            alert.messageText = "That folder isn't an Obsidian vault"
            alert.informativeText = "Choose the vault's top folder — the one that contains the hidden .obsidian folder."
            alert.runModal()
            return
        }
        try? update {
            $0.vault = url.path
            $0.importDailyNotesSettings()
        }
        Task { await checkCLI() }
    }

    func checkCLI() async {
        guard isSetUp else { cli = .failed("Choose a vault first."); return }
        cli = .checking
        do {
            _ = try await ObsidianBridge(config: settings).call("ping")
            cli = .ok
        } catch {
            cli = .failed(ObsidianBridge.isRunning ? error.localizedDescription
                          : "Obsidian isn't running. Captures still work — they go to today's diary file.")
        }
    }

    func setupView() -> AnyView? { AnyView(ObsidianSetupSteps(plugin: self, state: state)) }
    func settingsView() -> AnyView? { AnyView(ObsidianSettingsSections(plugin: self, state: state)) }
}

// MARK: - Views

private struct ObsidianSetupSteps: View {
    @ObservedObject var plugin: ObsidianCapturePlugin
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 10) {
            StepRow(done: plugin.isSetUp, symbol: "folder", title: "Obsidian vault",
                    detail: plugin.settings.vaultURL?.path ?? "Choose the vault where captures are saved.") {
                Button(plugin.isSetUp ? "Change…" : "Choose Vault…") { plugin.chooseVault() }
            }
            StepRow(done: state.screenGranted, symbol: "rectangle.dashed.badge.record", title: "Screen Recording",
                    detail: state.screenGranted ? "Granted — only the region you select is captured."
                        : state.screenRequested
                        ? "Turn on “\(appName)” in System Settings, then relaunch."
                        : "Needed to take screenshots of the area you select. Nothing is recorded or uploaded.") {
                if !state.screenGranted {
                    HStack {
                        Button(state.screenRequested ? "Open Settings" : "Grant Access…") { state.requestScreenRecording() }
                        if state.screenRequested { Button("Relaunch") { state.relaunch() } }
                    }
                }
            }
            StepRow(done: plugin.cli == .ok, symbol: "terminal", title: "Obsidian connection",
                    detail: cliDetail, optional: true) {
                HStack {
                    if !ObsidianBridge.isRunning, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "md.obsidian") {
                        Button("Open Obsidian") {
                            NSWorkspace.shared.open(app)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { Task { await plugin.checkCLI() } }
                        }
                    }
                    Button("Check") { Task { await plugin.checkCLI() } }.disabled(plugin.cli == .checking)
                }
            }
        }
        .task { await plugin.checkCLI() }
    }

    private var appName: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Quick Capture" }

    private var cliDetail: String {
        switch plugin.cli {
        case .ok: return "Connected — captures go to your cursor in the active note."
        case .checking: return "Checking…"
        case .failed(let message): return message
        case .unknown: return "Enable Obsidian → Settings → General → Command line interface so captures land at your cursor."
        }
    }
}

private struct ObsidianSettingsSections: View {
    @ObservedObject var plugin: ObsidianCapturePlugin
    @ObservedObject var state: AppState
    @State private var error: String?

    var body: some View {
        Section {
            LabeledContent("Vault") {
                HStack {
                    Text(plugin.settings.vaultURL?.path ?? "Not chosen").lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Button("Choose…") { plugin.chooseVault() }
                }
            }
            Picker("Main shortcuts save to", selection: binding(\.destinationMode)) {
                Text("Current note, at cursor").tag("current")
                Text("Today's diary").tag("diary")
            }
        }
        Section {
            TextField("Diary folder", text: binding(\.diaryFolder), prompt: Text("vault root"))
            TextField("Diary file name format", text: binding(\.diaryFormat), prompt: Text("YYYY-MM-DD"))
            TextField("Diary template", text: binding(\.template), prompt: Text("none — a dated heading"))
            Button("Import from Obsidian's Daily Notes settings") { apply { $0.importDailyNotesSettings() } }
        } header: {
            Text("Fallback diary")
        } footer: {
            Text("If no note is open in Obsidian, captures go to the bottom of today's diary, which is created from the template if missing.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Advanced") {
            TextField("Obsidian CLI", text: binding(\.obsidian))
            Button("Open recovery folder") {
                try? FileManager.default.createDirectory(at: ObsidianCapturePlugin.recovery, withIntermediateDirectories: true)
                NSWorkspace.shared.open(ObsidianCapturePlugin.recovery)
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
        }
    }

    private func apply(_ change: (inout ObsidianSettings) -> Void) {
        do { try plugin.update(change); error = nil } catch { self.error = error.localizedDescription }
    }

    private func binding(_ key: WritableKeyPath<ObsidianSettings, String>) -> Binding<String> {
        Binding(get: { plugin.settings[keyPath: key] }, set: { value in apply { $0[keyPath: key] = value } })
    }
}
