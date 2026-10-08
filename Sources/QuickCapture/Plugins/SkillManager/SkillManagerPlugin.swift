import AppKit
import SwiftUI
import WebKit

struct SkillManagerSettings: PluginSettings {
    /// Folders searched for skills (a skill is a folder with a SKILL.md, up to three levels down).
    var folders = SkillStore.defaultFolders
    /// Also list the skills that ship with Claude Code and Codex.
    var showBuiltin = false

    enum CodingKeys: String, CodingKey { case folders, showBuiltin = "show_builtin" }
}

/// A dashboard of the agent skills on this Mac: browse, read, edit and create them.
@MainActor
final class SkillManagerPlugin: ObservableObject, Plugin {
    nonisolated static let pluginID = "skill_manager"

    let id = SkillManagerPlugin.pluginID
    let name = "Skill Manager"
    let summary = "See every Claude Code and Codex skill you have, read their files, edit them, and create new ones."
    let symbol = "books.vertical"
    var enabledByDefault: Bool { false }
    let actions = [
        PluginAction(id: "dashboard", title: "Open Skill Manager", symbol: "books.vertical", defaultShortcut: "<ctrl>+<alt>+k"),
    ]

    private var dashboard: SkillDashboardController?

    var settings: SkillManagerSettings { state.settings(SkillManagerSettings.self, for: id) }

    func update(_ change: (inout SkillManagerSettings) -> Void) throws {
        try state.updateSettings(SkillManagerSettings.self, for: id, change)
    }

    func perform(_ action: PluginAction) {
        guard action.id == "dashboard" else { return }
        if dashboard == nil { dashboard = SkillDashboardController(plugin: self) }
        dashboard?.show()
    }

    func deactivate() {
        dashboard?.close()
        dashboard = nil
    }

    func configDidChange() { dashboard?.rescan() }

    func defaultSettings() -> [String: JSONValue] { encodeDefaults(SkillManagerSettings.self) }

    func validate(_ config: AppConfig) throws {
        let s = try config.settings(SkillManagerSettings.self, for: id)
        if s.folders.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            throw AppError("skill_manager.folders can't contain empty paths.")
        }
    }

    /// Asks for a folder and adds it to the scanned folders.
    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.prompt = "Add Folder"
        panel.message = "Choose a folder that contains skills (for example a project's .claude/skills)."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = SkillStore.tilde(url.standardizedFileURL.path)
        guard !settings.folders.contains(path) else { return }
        do { try update { $0.folders.append(path) } } catch { Toast.show(error.localizedDescription, isError: true) }
    }

    func settingsView() -> AnyView? { AnyView(SkillManagerSettingsSections(plugin: self, state: state)) }
}

private struct SkillManagerSettingsSections: View {
    @ObservedObject var plugin: SkillManagerPlugin
    @ObservedObject var state: AppState

    var body: some View {
        Section("Skill folders") {
            ForEach(plugin.settings.folders, id: \.self) { folder in
                HStack {
                    Text(folder).font(.system(.body, design: .monospaced))
                    Spacer()
                    Button(role: .destructive) {
                        try? plugin.update { $0.folders.removeAll { $0 == folder } }
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Stop scanning this folder (nothing is deleted)")
                }
            }
            Button("Add Folder…") { plugin.addFolder() }
            Toggle("Show built-in skills", isOn: Binding(get: { plugin.settings.showBuiltin },
                                                        set: { v in try? plugin.update { $0.showBuiltin = v } }))
        }
    }
}

// MARK: - Window

/// The dashboard window: a web page (Resources/skill_manager/) for the UI; this class scans folders and
/// reads and writes files on its behalf, only inside skill folders it found.
@MainActor
final class SkillDashboardController: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    private unowned let plugin: SkillManagerPlugin
    private let window: NSWindow
    private let webView: WKWebView
    private var pageReady = false
    private var pending: [[String: Any]] = []
    private var skills: [Skill] = []
    private var scanID = 0

    init(plugin: SkillManagerPlugin) {
        self.plugin = plugin
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 13.3, *) { webView.isInspectable = true }

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Skills"
        window.minSize = NSSize(width: 820, height: 520)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.contentView = webView
        window.center()
        window.setFrameAutosaveName("SkillManagerWindow")
        super.init()

        window.delegate = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        config.userContentController.add(SkillMessageHandler(self), name: "sm")
        if let index = Paths.resource("index.html", plugin: SkillManagerPlugin.pluginID) {
            // The page loads the Markdown renderer from ../ai_chat, so allow reading all of Resources/.
            let resources = index.deletingLastPathComponent().deletingLastPathComponent()
            webView.loadFileURL(index, allowingReadAccessTo: resources)
        } else {
            Toast.show("Skill Manager files are missing from the app bundle.", isError: true)
        }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        rescan()
    }

    func close() {
        window.orderOut(nil)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "sm")
    }

    // MARK: Scanning

    func rescan() {
        let folders = plugin.settings.folders
        scanID += 1
        let id = scanID
        Task.detached(priority: .userInitiated) {
            let found = SkillStore.scan(folders)
            await MainActor.run { [weak self] in
                guard let self, id == self.scanID else { return }
                self.skills = found
                self.sendSkills()
            }
        }
    }

    private func sendSkills() {
        let fm = FileManager.default
        let roots = plugin.settings.folders.compactMap { folder -> [String: Any]? in
            let url = SkillStore.expand(folder)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return nil }
            return ["path": url.path, "label": SkillStore.tilde(url.path)]
        }
        send(["type": "skills", "skills": skills.map(\.json), "roots": roots, "showBuiltin": plugin.settings.showBuiltin])
    }

    private func send(_ event: [String: Any]) {
        guard pageReady else { pending.append(event); return }
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.SM && SM.receive(\(json))")
    }

    private func fail(_ message: String) { send(["type": "error", "message": message]) }

    /// The file, if it lies inside one of the scanned skills (so the page can't read or write anything else).
    private func skillFile(_ path: String) -> URL? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let real = url.resolvingSymlinksInPath().path
        for skill in skills {
            for base in [skill.dir.standardizedFileURL.path, skill.dir.resolvingSymlinksInPath().path]
            where url.path.hasPrefix(base + "/") || real.hasPrefix(base + "/") {
                return url
            }
        }
        return nil
    }

    // MARK: Messages from the page

    fileprivate func handle(_ body: Any) {
        guard let msg = body as? [String: Any], let type = msg["type"] as? String else { return }
        let path = msg["path"] as? String ?? ""
        switch type {
        case "ready":
            pageReady = true
            let queued = pending
            pending = []
            queued.forEach(send)
            rescan()
        case "refresh":
            rescan()
        case "read":
            guard let url = skillFile(path) else { return fail("That file is not inside a skill folder.") }
            do {
                let data = try Data(contentsOf: url)
                let text = String(data: data, encoding: .utf8) ?? "(binary file, \(data.count) bytes — open it in Finder)"
                send(["type": "file", "path": path, "content": text])
            } catch { fail("Couldn't read \(url.lastPathComponent): \(error.localizedDescription)") }
        case "save":
            guard let url = skillFile(path), let content = msg["content"] as? String else {
                return fail("That file is not inside a skill folder.")
            }
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                send(["type": "saved", "path": path])
                rescan()
            } catch { fail("Couldn't save \(url.lastPathComponent): \(error.localizedDescription)") }
        case "create":
            create(root: msg["root"] as? String ?? "", name: msg["name"] as? String ?? "",
                   description: msg["description"] as? String ?? "")
        case "reveal":
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        case "openPath":
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.open(url) }
            else { fail("Not found: \(SkillStore.tilde(url.path))") }
        case "openURL":
            if let s = msg["url"] as? String, let url = URL(string: s), ["http", "https", "mailto"].contains(url.scheme ?? "") {
                NSWorkspace.shared.open(url)
            }
        case "addFolder":
            plugin.addFolder()
        case "setShowBuiltin":
            try? plugin.update { $0.showBuiltin = msg["value"] as? Bool ?? false }
        default:
            break
        }
    }

    private func create(root: String, name: String, description: String) {
        guard name.range(of: #"^[a-z0-9]+(-[a-z0-9]+)*$"#, options: .regularExpression) != nil else {
            return fail("Use lowercase letters, digits and single dashes for the name.")
        }
        let rootURL = URL(fileURLWithPath: root).standardizedFileURL
        guard plugin.settings.folders.map({ SkillStore.expand($0).path }).contains(rootURL.path) else {
            return fail("Choose one of the skill folders as the location.")
        }
        let dir = rootURL.appendingPathComponent(name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: dir.path) else { return fail("\(SkillStore.tilde(dir.path)) already exists.") }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try SkillStore.template(name: name, description: description)
                .write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
            send(["type": "created", "dir": dir.path, "name": name])
            rescan()
        } catch { fail("Couldn't create the skill: \(error.localizedDescription)") }
    }

    // MARK: Web view

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // The page handles its own links; never navigate away from it.
        if action.navigationType == .linkActivated {
            decisionHandler(.cancel)
            if let url = action.request.url, ["http", "https"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Keep Editing")
        alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        pageReady = false
        webView.reload()
    }
}

private final class SkillMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: SkillDashboardController?
    init(_ target: SkillDashboardController) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        MainActor.assumeIsolated { target?.handle(body) }
    }
}
