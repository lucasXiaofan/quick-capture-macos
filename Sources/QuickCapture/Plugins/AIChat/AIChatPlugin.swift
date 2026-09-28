import AppKit
import SwiftUI

struct AIChatSettings: PluginSettings {
    /// "claude:<model>" or "codex:<model>".
    var defaultModel = "claude:sonnet"
    /// Empty means the home folder.
    var workingDirectory = ""
    /// "read_only", "edit" (edit files, sandboxed commands, web search) or "full" (no sandbox).
    var permissions = "edit"
    /// Empty means find it automatically.
    var claudePath = ""
    var codexPath = ""

    enum CodingKeys: String, CodingKey {
        case defaultModel = "default_model", workingDirectory = "working_directory", permissions
        case claudePath = "claude_path", codexPath = "codex_path"
    }

    func path(for provider: Provider) -> String { provider == .claude ? claudePath : codexPath }
}

/// A quick, temporary chat with whichever coding agent is installed (Claude Code or Codex).
@MainActor
final class AIChatPlugin: ObservableObject, Plugin {
    nonisolated static let pluginID = "ai_chat"

    let id = AIChatPlugin.pluginID
    let name = "AI Chat"
    let summary = "A quick, temporary chat with Claude Code or Codex. It can search the web and read and edit files in a folder you choose."
    let symbol = "bubble.left.and.text.bubble.right"
    let actions = [
        PluginAction(id: "toggle", title: "Show / Hide AI Chat", symbol: "bubble.left.and.text.bubble.right",
                     defaultShortcut: "<ctrl>+<alt>+<space>"),
        PluginAction(id: "new_chat", title: "New AI Chat", symbol: "square.and.pencil", defaultShortcut: nil),
    ]

    let detector = AgentDetector()
    private var window: ChatWindowController?

    var settings: AIChatSettings { state.settings(AIChatSettings.self, for: id) }

    var workingDirectory: URL {
        let path = (settings.workingDirectory as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        if !path.isEmpty, FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    func update(_ change: (inout AIChatSettings) -> Void) throws {
        try state.updateSettings(AIChatSettings.self, for: id, change)
    }

    func perform(_ action: PluginAction) {
        let controller = window ?? ChatWindowController(plugin: self)
        window = controller
        switch action.id {
        case "new_chat":
            controller.newChat()
            controller.show()
        default:
            controller.toggle()
        }
    }

    func defaultSettings() -> [String: JSONValue] { encodeDefaults(AIChatSettings.self) }

    func validate(_ config: AppConfig) throws {
        let s = try config.settings(AIChatSettings.self, for: id)
        guard ["read_only", "edit", "full"].contains(s.permissions) else {
            throw AppError("ai_chat.permissions must be \"read_only\", \"edit\" or \"full\".")
        }
        guard ChatModel.parse(s.defaultModel) != nil else {
            throw AppError("ai_chat.default_model must look like \"claude:sonnet\" or \"codex:gpt-6-luna\".")
        }
    }

    func activate() { Task { await detectAgents() } }

    func deactivate() {
        window?.close()
        window = nil
    }

    func configDidChange() { window?.configDidChange() }

    func detectAgents(force: Bool = false) async {
        await detector.detect(settings: settings, force: force)
        objectWillChange.send()
        window?.configDidChange()
    }

    var setupIssues: [String] {
        detector.hasRun && !detector.detecting && detector.installs.isEmpty
            ? ["AI Chat needs Claude Code or Codex installed."] : []
    }

    func setupView() -> AnyView? { AIChatSetupSteps(plugin: self, detector: detector).eraseToAnyView() }
    func settingsView() -> AnyView? { AIChatSettingsSections(plugin: self, detector: detector, state: state).eraseToAnyView() }
}

extension View {
    func eraseToAnyView() -> AnyView { AnyView(self) }
}

// MARK: - Views

private struct AIChatSetupSteps: View {
    @ObservedObject var plugin: AIChatPlugin
    @ObservedObject var detector: AgentDetector

    var body: some View {
        VStack(spacing: 10) {
            ForEach(Provider.allCases, id: \.self) { provider in
                let install = detector.installs[provider]
                StepRow(done: install != nil, symbol: "terminal", title: provider.displayName,
                        detail: detector.detecting && install == nil ? "Looking…"
                            : install.map { "Found \($0.version.isEmpty ? "" : $0.version + " ")at \($0.path)" }
                            ?? "Not found. \(provider.installHint)",
                        optional: true) {
                    EmptyView()
                }
            }
            HStack {
                Spacer()
                Button("Detect Again") { Task { await plugin.detectAgents(force: true) } }.disabled(detector.detecting)
            }
        }
    }
}

private struct AIChatSettingsSections: View {
    @ObservedObject var plugin: AIChatPlugin
    @ObservedObject var detector: AgentDetector
    @ObservedObject var state: AppState
    @State private var error: String?

    var body: some View {
        let settings = plugin.settings
        Section("Chat") {
            Picker("Default model", selection: binding(\.defaultModel)) {
                let models = detector.models(including: settings.defaultModel)
                if !models.contains(where: { $0.key == settings.defaultModel }) {
                    Text(settings.defaultModel + " (not installed)").tag(settings.defaultModel)
                }
                ForEach(models, id: \.key) { Text("\($0.label) · \($0.provider.displayName)").tag($0.key) }
            }
            LabeledContent("Working folder") {
                HStack {
                    Text(plugin.workingDirectory.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Button("Choose…") { chooseFolder() }
                }
            }
            Picker("Permissions", selection: binding(\.permissions)) {
                Text("Read only — read files, search the web").tag("read_only")
                Text("Edit — also edit files and run sandboxed commands").tag("edit")
                Text("Full access — no sandbox (use with care)").tag("full")
            }
        }
        Section {
            TextField("Claude Code CLI", text: binding(\.claudePath), prompt: Text("find automatically"))
            TextField("Codex CLI", text: binding(\.codexPath), prompt: Text("find automatically"))
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
        } header: {
            Text("Advanced")
        } footer: {
            Text("The chat runs your installed Claude Code or Codex with your own sign-in. Conversations aren't saved by this app; each CLI keeps its usual session history.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use Folder"
        panel.directoryURL = plugin.workingDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        apply { $0.workingDirectory = url.path }
    }

    private func apply(_ change: (inout AIChatSettings) -> Void) {
        let before = plugin.settings
        do { try plugin.update(change); error = nil } catch { self.error = error.localizedDescription }
        let after = plugin.settings
        if before.claudePath != after.claudePath || before.codexPath != after.codexPath {
            Task { await plugin.detectAgents(force: true) }
        }
    }

    private func binding(_ key: WritableKeyPath<AIChatSettings, String>) -> Binding<String> {
        Binding(get: { plugin.settings[keyPath: key] }, set: { value in apply { $0[keyPath: key] = value } })
    }
}
