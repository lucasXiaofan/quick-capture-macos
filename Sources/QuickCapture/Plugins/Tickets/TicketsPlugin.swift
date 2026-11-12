import AppKit
import SwiftUI

struct TicketsSettings: PluginSettings {
    /// Where tickets are kept (Markdown files). Empty means the app's own data folder.
    var folder = ""
    /// "claude", "codex" or "pi".
    var agent = "claude"
    /// Empty means the CLI's own default model. `model` is the older single setting: it applies to any agent
    /// that has no model of its own below.
    var model = ""
    var claudeModel = ""
    var codexModel = ""
    var piModel = ""
    /// Reasoning effort per agent; empty means the CLI's own default. Claude Code: low … max; Codex: minimal … xhigh;
    /// Pi (its "thinking" level): off … max.
    var claudeEffort = ""
    var codexEffort = ""
    var piEffort = ""
    /// Run the agent as soon as a ticket is sent or replied to.
    var autoProcess = true
    /// "read_only", "workspace" (edit files and run sandboxed commands in the working and extra folders)
    /// or "full" (no sandbox: any command, installs, any file).
    var access = "workspace"
    /// Let sandboxed commands reach the network (Codex; needed to install packages without Full access).
    var allowNetwork = true
    /// Where the agent works. Empty means <folder>/workspace.
    var workingDirectory = ""
    /// More folders the agent may read and change in "workspace" access (project checkouts, a notes vault).
    var extraFolders: [String] = []
    var timeoutMinutes = 20
    /// Let the agent change Quick Capture's own source and order a rebuild + restart (with git snapshots and an
    /// automatic way back).
    var selfUpdate = false
    /// The Quick Capture source folder; empty uses the one this app was built from.
    var selfUpdateFolder = ""
    /// Ask before each rebuild + restart the agent orders.
    var selfUpdateConfirm = true
    /// A banner when the agent has answered and a ticket waits for you.
    var notifyYourTurn = true
    /// A banner on the day a ticket is due: at `dueNotifyHour` o'clock, or `dueLeadHours` before its due time.
    var notifyDue = true
    var dueNotifyHour = 7
    var dueLeadHours = 5
    /// Empty means find it automatically.
    var claudePath = ""
    var codexPath = ""
    var piPath = ""

    enum CodingKeys: String, CodingKey {
        case folder, agent, model, claudeModel = "claude_model", codexModel = "codex_model", piModel = "pi_model"
        case claudeEffort = "claude_effort", codexEffort = "codex_effort", piEffort = "pi_effort", autoProcess = "auto_process", access, allowNetwork = "allow_network"
        case workingDirectory = "working_directory", extraFolders = "extra_folders", timeoutMinutes = "timeout_minutes"
        case selfUpdate = "self_update", selfUpdateFolder = "self_update_folder", selfUpdateConfirm = "self_update_confirm"
        case claudePath = "claude_path", codexPath = "codex_path", piPath = "pi_path"
        case notifyYourTurn = "notify_your_turn", notifyDue = "notify_due", dueNotifyHour = "due_notify_hour", dueLeadHours = "due_lead_hours"
    }

    func model(for kind: TicketAgentKind) -> String {
        let own: String
        switch kind {
        case .claude: own = claudeModel
        case .codex: own = codexModel
        case .pi: own = piModel
        }
        let trimmed = own.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty && kind.rawValue == agent ? model.trimmingCharacters(in: .whitespaces) : trimmed
    }

    func effort(for kind: TicketAgentKind) -> String {
        switch kind {
        case .claude: return claudeEffort
        case .codex: return codexEffort
        case .pi: return piEffort
        }
    }

    func path(for kind: TicketAgentKind) -> String {
        switch kind {
        case .claude: return claudePath
        case .codex: return codexPath
        case .pi: return piPath
        }
    }
}

/// Capture anything as a ticket with one shortcut; an agent classifies it, takes the first turn and keeps
/// the conversation going. Views (inbox, projects, habits, plan) are built from the tickets, never the reverse.
@MainActor
final class TicketsPlugin: ObservableObject, Plugin {
    nonisolated static let pluginID = "tickets"

    let id = TicketsPlugin.pluginID
    let name = "Tickets"
    let summary = "Capture a thought, todo, question or bug as a ticket with one shortcut. Claude Code, Codex or Pi classifies it, takes the first turn, and you reply like email."
    let symbol = "tray.full"
    var enabledByDefault: Bool { false }
    let actions = [
        PluginAction(id: "new", title: "New Ticket", symbol: "square.and.pencil", defaultShortcut: "<ctrl>+<alt>+e"),
        PluginAction(id: "inbox", title: "Open Tickets", symbol: "tray.full", defaultShortcut: "<ctrl>+<alt>+<shift>+e"),
    ]

    let detector = TicketAgentDetector()
    private(set) lazy var store = TicketStore(root: rootURL)
    private(set) lazy var runner = TicketAgentRunner(plugin: self)
    private(set) lazy var selfUpdate = TicketSelfUpdate(plugin: self)
    private(set) lazy var notifier = TicketNotifier(plugin: self)
    var isWindowKey: Bool { window?.isKey ?? false }
    private var window: TicketsWindowController?
    private var compose: TicketComposeController?
    private var pushScheduled = false
    private var capturing = false

    var settings: TicketsSettings { state.settings(TicketsSettings.self, for: id) }

    func update(_ change: (inout TicketsSettings) -> Void) throws {
        try state.updateSettings(TicketsSettings.self, for: id, change)
    }

    private static func expand(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
    }

    var rootURL: URL { settings.folder.isEmpty ? Paths.data(for: id) : Self.expand(settings.folder) }

    var workingDirectory: URL {
        settings.workingDirectory.isEmpty ? store.workspaceDir : Self.expand(settings.workingDirectory)
    }

    var extraFolders: [URL] {
        var folders = settings.extraFolders.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(Self.expand)
        if selfUpdate.isActive, let project = selfUpdate.projectFolder, !folders.contains(project) { folders.append(project) }
        return folders
    }

    // MARK: Plugin

    func perform(_ action: PluginAction) {
        switch action.id {
        case "new": showCompose()
        default: showWindow()
        }
    }

    func primaryActions() -> [PluginAction] { actions }

    func menuAlerts() -> [NSMenuItem] {
        let waiting = store.tickets.values.filter { $0.status == .waitingHuman && $0.mergedInto == nil }.count
        guard waiting > 0 else { return [] }
        return [ClosureMenuItem("Tickets Waiting for You (\(waiting))…", symbol: "tray.full") { [weak self] in self?.showWindow() }]
    }

    func menuItems() -> [NSMenuItem] {
        [ClosureMenuItem("Show Ticket Folder in Finder") { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.open(self.store.root)
        }]
    }

    func defaultSettings() -> [String: JSONValue] { encodeDefaults(TicketsSettings.self) }

    func validate(_ config: AppConfig) throws {
        let s = try config.settings(TicketsSettings.self, for: id)
        guard TicketAgentKind(rawValue: s.agent) != nil else {
            throw AppError("tickets.agent must be \"claude\", \"codex\" or \"pi\".")
        }
        guard ["read_only", "workspace", "full"].contains(s.access) else {
            throw AppError("tickets.access must be \"read_only\", \"workspace\" or \"full\".")
        }
        for kind in TicketAgentKind.allCases where !s.effort(for: kind).isEmpty && !kind.efforts.contains(s.effort(for: kind)) {
            throw AppError("tickets.\(kind.rawValue)_effort must be one of: " + kind.efforts.joined(separator: ", ") + " (or empty).")
        }
        if s.selfUpdate {
            let chosen = s.selfUpdateFolder.trimmingCharacters(in: .whitespaces)
            let source = chosen.isEmpty ? (Bundle.main.object(forInfoDictionaryKey: "QuickCaptureSourceRoot") as? String ?? "") : chosen
            guard !source.isEmpty, TicketSelfUpdate.looksLikeProject(URL(fileURLWithPath: (source as NSString).expandingTildeInPath)) else {
                throw AppError("tickets.self_update needs tickets.self_update_folder to be the Quick Capture source (a git checkout with Package.swift and scripts/build.sh).")
            }
        }
        guard (0...23).contains(s.dueNotifyHour), (0...48).contains(s.dueLeadHours) else {
            throw AppError("tickets.due_notify_hour must be 0–23 and tickets.due_lead_hours 0–48.")
        }
        guard s.timeoutMinutes >= 1 else { throw AppError("tickets.timeout_minutes must be at least 1.") }
    }

    func activate() {
        store.onChange = { [weak self] in self?.schedulePush(); self?.notifier.reschedule() }
        notifier.activate()
        store.onDesignRedrawn = { [weak self] id in self?.window?.host.send(["type": "designRedrawn", "id": id]) }
        selfUpdate.activate()
        runner.onProgress = { [weak self] in self?.pushBusy() }
        Task {
            await detectAgents()
            if settings.autoProcess { runner.enqueuePending() }
        }
    }

    func deactivate() {
        notifier.deactivate()
        selfUpdate.deactivate()
        runner.stopAll()
        window?.close()
        window?.host.dispose()
        window = nil
        compose?.hide()
        compose?.host.dispose()
        compose = nil
    }

    func configDidChange() {
        store.setRoot(rootURL)
        notifier.reschedule()
        schedulePush()
    }

    func detectAgents(force: Bool = false) async {
        await detector.detect(settings: settings, force: force)
        objectWillChange.send()
        schedulePush()
    }

    var setupIssues: [String] {
        guard detector.hasRun, !detector.detecting else { return [] }
        if detector.installs.isEmpty { return ["Tickets needs Claude Code, Codex or Pi installed for the agent."] }
        if let kind = TicketAgentKind(rawValue: settings.agent), detector.installs[kind] == nil {
            return ["Tickets is set to use \(kind.displayName), which isn't installed."]
        }
        return []
    }

    func setupView() -> AnyView? { AnyView(TicketsSetupSteps(plugin: self, detector: detector)) }
    func overviewView() -> AnyView? { AnyView(TicketsOverview(plugin: self)) }
    func settingsView() -> AnyView? { AnyView(TicketsSettingsSections(plugin: self, detector: detector, state: state)) }

    // MARK: Windows

    func showWindow(ticket: Int? = nil) {
        if window == nil {
            let controller = TicketsWindowController(plugin: self)
            controller.host.onMessage = { [weak self, weak controller] msg in
                guard let self, let controller else { return }
                self.handle(msg, from: controller.host, target: "window")
            }
            controller.host.webView.onDropFiles = { [weak self, weak controller] urls in
                guard let self, let controller else { return }
                self.sendStaged(urls.compactMap { self.store.stage(file: $0) }, to: controller.host, box: "")
            }
            window = controller
        }
        window?.show()
        if let ticket { window?.host.send(["type": "open", "id": ticket]) }
    }

    func showCompose() {
        if compose == nil {
            let controller = TicketComposeController(plugin: self)
            controller.host.onMessage = { [weak self, weak controller] msg in
                guard let self, let controller else { return }
                self.handle(msg, from: controller.host, target: "compose")
            }
            controller.host.webView.onDropFiles = { [weak self, weak controller] urls in
                guard let self, let controller else { return }
                self.sendStaged(urls.compactMap { self.store.stage(file: $0) }, to: controller.host, box: "compose")
            }
            compose = controller
        }
        compose?.show()
    }

    private func schedulePush() {
        guard !pushScheduled else { return }
        pushScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pushScheduled = false
            let state = self.snapshot()
            self.window?.host.send(state)
            self.compose?.host.send(state)
        }
    }

    private var busy: [String: Any] {
        var out: [String: Any] = [:]
        for (id, run) in runner.running { out[String(id)] = ["activity": run.activity, "tools": run.tools] }
        for id in runner.queue { out[String(id)] = ["activity": "Queued", "tools": [String](), "queued": true] }
        return out
    }

    private func pushBusy() {
        window?.host.send(["type": "busy", "busy": busy])
    }

    private func snapshot() -> [String: Any] {
        let s = settings
        let kind = TicketAgentKind(rawValue: s.agent) ?? .claude
        return [
            "type": "state",
            "tickets": store.json(store.sorted),
            "structure": store.json(store.structure),
            "instructions": store.instructions,
            "corrections": store.json(store.corrections),
            "decisions": store.json(Array(store.decisions.suffix(300))),
            "designs": store.json(store.designs),
            "tools": TicketTools.json(),
            "tagRules": ["indexMax": TicketTagFiles.indexMax, "fileMax": TicketTagFiles.fileMax, "folder": store.tagsDir.path,
                         "problems": TicketTagFiles.problems(store.structure.tags), "map": store.tagMap != nil] as [String: Any],
            "prompt": TicketPrompt.standing(store: store) + (selfUpdate.isActive ? TicketPrompt.selfUpdateSection(selfUpdate.projectFolder) : ""),
            "contract": TicketAgentResult.contract(selfUpdate: selfUpdate.isActive),
            "selfUpdate": [
                "enabled": settings.selfUpdate, "problem": selfUpdate.problem ?? "", "folder": selfUpdate.projectFolder?.path ?? "",
                "busy": selfUpdate.isBusy, "records": store.json(Array(selfUpdate.records.reversed())),
            ] as [String: Any],
            "busy": busy,
            "today": TicketDates.today(),
            "settings": [
                "agent": kind.displayName + (s.model(for: kind).isEmpty ? "" : " · " + s.model(for: kind)),
                "agentID": kind.rawValue,
                "agents": TicketAgentKind.allCases.map { k in
                    ["id": k.rawValue, "name": k.displayName, "installed": detector.installs[k] != nil || !detector.hasRun,
                     "efforts": k.efforts, "effort": s.effort(for: k), "model": s.model(for: k),
                     "models": detector.models(for: k, including: s.model(for: k)).map { ["id": $0.id, "label": $0.label] }] as [String: Any]
                },
                "installed": detector.installs[kind] != nil || !detector.hasRun,
                "access": s.access,
                "accessNote": kind.accessNote(s.access),
                "auto": s.autoProcess,
                "folder": store.root.path,
            ],
        ]
    }

    // MARK: Messages from the pages

    private func handle(_ msg: [String: Any], from host: TicketWebHost, target: String) {
        let type = msg["type"] as? String ?? ""
        let id = (msg["id"] as? NSNumber)?.intValue
        let text = (msg["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let staged = msg["staged"] as? [String] ?? []
        let choice = TicketAgentChoice(agent: TicketAgentKind(rawValue: msg["agent"] as? String ?? ""),
                                       model: (msg["model"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                       effort: (msg["effort"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        switch type {
        case "ready":
            host.send(snapshot())
        case "create":
            guard !text.isEmpty || !staged.isEmpty else { return }
            // mode: "send" (the agent classifies), "append" (the agent files it into an existing ticket),
            // "save" (no agent: kept with the hashtags typed).
            let mode = msg["mode"] as? String ?? "send"
            let ticket = store.create(text: text.isEmpty ? "(see attachment)" : text, staged: staged)
            let run = mode == "append" || (mode != "save" && settings.autoProcess)
            if !run { store.update(ticket.id, touch: false) { $0.status = .waitingHuman } }
            if target == "compose" {
                compose?.hide()
                let agent = choice.resolved(settings: settings).agent?.displayName ?? "agent"
                Toast.show("Ticket #\(ticket.id) saved" + (!run ? "" : mode == "append" ? " · \(agent) is appending it" : " · \(agent) is on it"))
            }
            if run {
                var choice = choice
                choice.append = mode == "append"
                runner.enqueue(ticket.id, choice: choice)
            }
        case "reply":
            guard let id, !text.isEmpty || !staged.isEmpty else { return }
            store.reply(id, text: text.isEmpty ? "(see attachment)" : text, staged: staged)
            if settings.autoProcess { runner.enqueue(id, choice: choice) }
        case "note":
            // A human message that doesn't ask the agent for anything (e.g. adding a practice question for later).
            guard let id, !text.isEmpty || !staged.isEmpty else { return }
            let status = store.tickets[id]?.status
            store.reply(id, text: text.isEmpty ? "(see attachment)" : text, staged: staged)
            if let status { store.update(id, touch: false) { $0.status = status == .unprocessed ? .waitingHuman : status } }
        case "status":
            guard let id, let status = Ticket.Status(rawValue: msg["status"] as? String ?? "") else { return }
            store.update(id) {
                $0.history.append(TicketEvent(at: TicketDates.now(), by: "human", text: "status: \($0.status.rawValue) → \(status.rawValue)"))
                $0.status = status
            }
            if status == .needsAgent { runner.enqueue(id, choice: choice) } else { runner.stop(id) }
        case "edit":
            guard let id, let fields = msg["fields"] as? [String: Any] else { return }
            edit(id, fields)
        case "takeaway":
            guard let id, !text.isEmpty else { return }
            store.update(id) { if !$0.takeaways.contains(text) { $0.takeaways.append(text) } }
        case "removeTakeaway":
            guard let id else { return }
            store.update(id, touch: false) { $0.takeaways.removeAll { $0 == text } }
        case "removeLog":
            guard let id, let date = msg["date"] as? String, let name = msg["name"] as? String else { return }
            store.update(id, touch: false) { $0.log.removeAll { $0.date == date && $0.name == name } }
        case "correction":
            store.addCorrection(text, ticket: id)
            if let id {
                store.update(id, touch: false) { $0.history.append(TicketEvent(at: TicketDates.now(), by: "human", text: "Correction: \(text)")) }
            }
        case "removeCorrection":
            store.removeCorrection(at: msg["at"] as? String ?? "", text: msg["text"] as? String ?? "")
        case "run":
            guard let id else { return }
            store.update(id, touch: false) { if $0.status != .unprocessed { $0.status = .needsAgent } }
            runner.enqueue(id, choice: choice)
        case "stop":
            if let id { runner.stop(id) }
        case "selfRebuild":
            let record = msg["record"] as? String ?? ""
            Task { await selfUpdate.rebuild(record) }
        case "selfRollback":
            let record = msg["record"] as? String ?? ""
            Task { await selfUpdate.rollback(record) }
        case "selfFolder":
            chooseSelfUpdateFolder()
        case "merge":
            let ids = (msg["ids"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }
            if let merged = store.merge(ids, by: "human") { host.send(["type": "open", "id": merged.id]) }
        case "unmerge":
            if let id { runner.stop(id); store.unmerge(id) }
        case "delete":
            if let id { runner.stop(id); store.delete(id) }
        case "instructions":
            store.setInstructions(msg["text"] as? String ?? "")
        case "structure":
            guard let raw = msg["structure"], JSONSerialization.isValidJSONObject(raw),
                  let data = try? JSONSerialization.data(withJSONObject: raw),
                  let next = try? JSONDecoder().decode(TicketStructure.self, from: data) else {
                return host.send(["type": "error", "message": "That structure couldn't be saved."])
            }
            store.setStructure(next)
        case "defineTag":
            store.defineTag(msg["id"] as? String ?? "", meaning: msg["meaning"] as? String, action: msg["action"] as? String)
        case "mergeTags":
            let from = msg["from"] as? [String] ?? []
            if let count = store.mergeTags(from, into: msg["into"] as? String ?? "") {
                host.send(["type": "error", "message": "Merged into #\(TicketStructure.tagPath(msg["into"] as? String ?? "")) on \(count) ticket\(count == 1 ? "" : "s")."])
            }
        case "deleteTag":
            store.deleteTag(msg["id"] as? String ?? "")
        case "loadDesign":
            guard let design = msg["id"] as? String else { return }
            let canvas = store.designCanvas(design).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]
            host.send(["type": "design", "id": design, "canvas": canvas ?? ["nodes": [Any](), "edges": [Any]()], "missing": canvas == nil])
        case "saveDesign":
            var designID = msg["id"] as? String
            if msg["new"] as? Bool == true {
                // A new design never replaces one that has the same name.
                let base = TicketStore.designID(msg["title"] as? String ?? "design")
                var candidate = base, n = 2
                while store.designs.contains(where: { $0.id == candidate }) { candidate = "\(base)-\(n)"; n += 1 }
                designID = candidate
            }
            let saved = store.saveDesign(id: designID, title: msg["title"] as? String, project: msg["project"] as? String,
                                         summary: msg["summary"] as? String, canvas: msg["canvas"])
            if let saved { if msg["open"] as? Bool == true { host.send(["type": "openDesign", "id": saved]) } }
            else { host.send(["type": "error", "message": "That design couldn't be saved."]) }
        case "deleteDesign":
            store.deleteDesign(msg["id"] as? String ?? "")
        case "revealTags":
            NSWorkspace.shared.open(store.tagsDir)
        case "revealDesign":
            if let design = msg["id"] as? String { NSWorkspace.shared.activateFileViewerSelecting([store.designFile(design)]) }
            else { NSWorkspace.shared.open(store.designsDir) }
        case "importDesigns":
            importDesigns(for: host)
        case "stageData":
            guard let base64 = msg["data"] as? String, let data = Data(base64Encoded: base64),
                  let name = store.stage(data: data, name: msg["name"] as? String ?? "pasted.png") else { return }
            sendStaged([name], to: host, box: msg["box"] as? String ?? "")
        case "pickFiles":
            pickFiles(for: host, box: msg["box"] as? String ?? "", target: target)
        case "screenshot":
            screenshot(for: host, box: msg["box"] as? String ?? "", target: target)
        case "unstage":
            store.unstage(msg["name"] as? String ?? "")
        case "openAttachment":
            guard let id, let name = msg["name"] as? String else { return }
            let file = store.attachmentDir(id).appendingPathComponent((name as NSString).lastPathComponent)
            if FileManager.default.fileExists(atPath: file.path) { NSWorkspace.shared.open(file) }
        case "reveal":
            if let id { NSWorkspace.shared.activateFileViewerSelecting([store.ticketFile(id)]) }
            else { NSWorkspace.shared.open(store.root) }
        case "openURL":
            if let s = msg["url"] as? String, let url = URL(string: s), ["http", "https", "mailto"].contains(url.scheme ?? "") {
                NSWorkspace.shared.open(url)
            }
        case "openSettings":
            state.showSettings?(self.id)
        case "compose":
            showCompose()
        case "openWindow":
            compose?.hide(returnFocus: false)
            showWindow()
        case "hideCompose":
            compose?.hide()
        default:
            break
        }
    }

    /// A manual change. When it overrides what the agent chose, it is also logged as a correction, so the
    /// agent classifies the next similar ticket the way the user did.
    private func edit(_ id: Int, _ fields: [String: Any]) {
        guard let before = store.tickets[id] else { return }
        var projectID: String?
        if let name = fields["project"] as? String { projectID = name.isEmpty ? "" : store.project(named: name) }
        store.update(id, touch: false) { ticket in
            if let title = (fields["title"] as? String)?.trimmingCharacters(in: .whitespaces), !title.isEmpty { ticket.title = title }
            if let summary = fields["summary"] as? String { ticket.summary = summary }
            if let kind = fields["kind"] as? String, store.structure.kinds.contains(where: { $0.id == kind }) { ticket.kind = kind }
            if let projectID { ticket.project = projectID }
            if let related = fields["related_projects"] as? [String] {
                let known = Set(store.structure.projects.map(\.id))
                ticket.relatedProjects = Array(Set(related.filter { known.contains($0) && $0 != ticket.project })).sorted()
            }
            if let tags = fields["tags"] as? [String] {
                ticket.tags = tags.map { TicketStructure.tagPath($0) }.filter { !$0.isEmpty }
                    .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            }
            if fields["due_time"] != nil { ticket.dueTime = (fields["due_time"] as? String).flatMap(TicketDates.time) }
            for (key, path) in [("start", \Ticket.start), ("due", \Ticket.due)] where fields[key] != nil {
                ticket[keyPath: path] = (fields[key] as? String).flatMap { TicketDates.isDay($0) ? $0 : nil }
            }
            if ticket.due == nil { ticket.dueTime = nil }
        }
        guard let after = store.tickets[id], before.messages.contains(where: { $0.role == "agent" }) else { return }
        var fixes: [String] = []
        if before.kind != after.kind { fixes.append("kind should be \(after.kind), not \(before.kind)") }
        if before.project != after.project {
            fixes.append("project should be \(after.project.isEmpty ? "none" : after.project), not \(before.project.isEmpty ? "none" : before.project)")
        }
        guard !fixes.isEmpty else { return }
        let note = "“\(after.title)”: " + fixes.joined(separator: "; ") + "."
        store.addCorrection(note, ticket: id)
        store.update(id, touch: false) { $0.history.append(TicketEvent(at: TicketDates.now(), by: "human", text: "Correction: \(note)")) }
    }

    private func sendStaged(_ names: [String], to host: TicketWebHost, box: String) {
        guard !names.isEmpty else { return }
        host.send(["type": "staged", "box": box,
                   "items": names.map { ["name": $0, "image": TicketMarkdown.isImage($0)] }])
    }

    private func pickFiles(for host: TicketWebHost, box: String, target: String) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Attach"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else {
            if target == "compose" { compose?.show() }
            return
        }
        sendStaged(panel.urls.compactMap { store.stage(file: $0) }, to: host, box: box)
        if target == "compose" { compose?.show() }
    }

    private func screenshot(for host: TicketWebHost, box: String, target: String) {
        guard !capturing else { return }
        guard CGPreflightScreenCaptureAccess() else {
            state.refreshPermissions()
            state.requestScreenRecording()
            Toast.show("Screen Recording permission is needed for screenshots.", symbol: "lock", isError: true)
            return
        }
        capturing = true
        let fromCompose = target == "compose"
        // Get our windows out of the way of the region selection.
        if fromCompose { compose?.hide(returnFocus: false) } else { window?.close() }
        Task {
            defer { capturing = false }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("qc-ticket-\(UUID().uuidString).png")
            _ = try? await Shell.run("/usr/sbin/screencapture", ["-i", "-x", "-o", tmp.path], timeout: 600)
            defer { try? FileManager.default.removeItem(at: tmp) }
            if fromCompose { compose?.show() } else { window?.show() }
            guard let size = (try? tmp.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0,
                  let data = try? Data(contentsOf: tmp) else { return }  // Esc: nothing captured.
            let stamp = TicketDates.now().prefix(19).replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "T", with: "-")
            if let name = store.stage(data: data, name: "screenshot-\(stamp).png") { sendStaged([name], to: host, box: box) }
        }
    }

    private func importDesigns(for host: TicketWebHost) {
        let panel = NSOpenPanel()
        panel.message = "Choose a folder of .canvas files (an Obsidian vault folder, for example). They are copied into the ticket folder; the originals are not changed."
        panel.prompt = "Import Designs"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let added = store.importDesigns(from: url)
        host.send(["type": "error", "message": added == 0 ? "No new .canvas files in that folder." : "Imported \(added) design\(added == 1 ? "" : "s")."])
    }

    func chooseSelfUpdateFolder() {
        let panel = NSOpenPanel()
        panel.message = "Choose the Quick Capture source folder (the git checkout with Package.swift and scripts/build.sh)."
        panel.prompt = "Use This Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = selfUpdate.projectFolder
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard TicketSelfUpdate.looksLikeProject(url) else {
            Toast.show("That isn't a Quick Capture checkout (needs .git, Package.swift and scripts/build.sh).", symbol: "exclamationmark.triangle", isError: true)
            return
        }
        do { try update { $0.selfUpdateFolder = url.path } } catch { Toast.show(error.localizedDescription, isError: true) }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.message = "Choose where tickets are kept (Markdown files, attachments and the agent's rules)."
        panel.prompt = "Use This Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = store.root
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        runner.stopAll()
        do { try update { $0.folder = url.path } } catch { Toast.show(error.localizedDescription, isError: true) }
    }
}

// MARK: - Settings views

private struct TicketsOverview: View {
    @ObservedObject var plugin: TicketsPlugin

    var body: some View {
        Section {
            HStack {
                Button("Open Tickets") { plugin.showWindow() }
                Button("New Ticket") { plugin.showCompose() }
                Spacer()
            }
        } footer: {
            Text("Kinds, the agent's instructions, its decision log and your corrections live in the Tickets window under Agent.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct TicketsSetupSteps: View {
    @ObservedObject var plugin: TicketsPlugin
    @ObservedObject var detector: TicketAgentDetector

    var body: some View {
        VStack(spacing: 10) {
            ForEach(TicketAgentKind.allCases, id: \.self) { kind in
                let install = detector.installs[kind]
                StepRow(done: install != nil, symbol: "terminal", title: kind.displayName,
                        detail: detector.detecting && install == nil ? "Looking…"
                            : install.map { "Found \($0.version.isEmpty ? "" : $0.version + " ")at \($0.path)" }
                            ?? "Not found. \(kind.installHint)",
                        optional: true) {
                    EmptyView()
                }
            }
            HStack {
                Text("One of them is enough.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Detect Again") { Task { await plugin.detectAgents(force: true) } }.disabled(detector.detecting)
            }
        }
    }
}

private struct TicketsSettingsSections: View {
    @ObservedObject var plugin: TicketsPlugin
    @ObservedObject var detector: TicketAgentDetector
    @ObservedObject var state: AppState
    @State private var error: String?

    var body: some View {
        let settings = plugin.settings
        let kind = TicketAgentKind(rawValue: settings.agent) ?? .claude
        Section("Storage") {
            LabeledContent("Ticket folder") {
                HStack {
                    Text(plugin.rootURL.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Button("Choose…") { plugin.chooseFolder() }
                    Button("Show") { NSWorkspace.shared.open(plugin.rootURL) }
                }
            }
        }
        Section {
            Picker("Default agent", selection: binding(\.agent)) {
                ForEach(TicketAgentKind.allCases, id: \.self) { kind in
                    Text(kind.displayName + (detector.installs[kind] == nil && detector.hasRun ? " (not installed)" : "")).tag(kind.rawValue)
                }
            }
            ForEach(TicketAgentKind.allCases, id: \.self) { k in
                HStack {
                    Text(k.displayName).frame(width: 90, alignment: .leading)
                    Picker("Model", selection: modelBinding(k)) {
                        Text("Default model").tag("")
                        ForEach(detector.models(for: k, including: modelBinding(k).wrappedValue), id: \.id) { Text($0.label).tag($0.id) }
                    }.labelsHidden()
                    Picker("Effort", selection: effortBinding(k)) {
                        Text("Default effort").tag("")
                        ForEach(k.efforts, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden().frame(width: 140)
                }
            }
            Toggle("Run the agent as soon as a ticket is sent", isOn: Binding(
                get: { plugin.settings.autoProcess }, set: { v in apply { $0.autoProcess = v } }))
        } header: {
            Text("Agent")
        } footer: {
            Text("Models come from each CLI (Codex's list is the one its sign-in can use; Pi's is `pi --list-models`); \"Default model\" leaves the choice to the CLI. Another model name can be typed into config.json. Effort is Claude Code's --effort, Codex's reasoning effort and Pi's thinking level. You can also pick the agent and effort for a single reply, in the reply box.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            Picker("Access", selection: binding(\.access)) {
                Text("Read only").tag("read_only")
                Text("Workspace — edit files, run sandboxed commands").tag("workspace")
                Text("Full access — any command, installs, no sandbox").tag("full")
            }
            Label(kind.accessNote(settings.access), systemImage: settings.access == "full" ? "exclamationmark.shield" : "shield")
                .font(.callout).foregroundStyle(settings.access == "full" ? .orange : .secondary)
            if settings.access == "workspace" {
                LabeledContent("Working folder") {
                    HStack {
                        Text(plugin.workingDirectory.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Choose…") { chooseFolder { url in apply { $0.workingDirectory = url.path } } }
                        if !settings.workingDirectory.isEmpty { Button("Reset") { apply { $0.workingDirectory = "" } } }
                    }
                }
                ForEach(settings.extraFolders, id: \.self) { folder in
                    HStack {
                        Text(folder).font(.system(.body, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(role: .destructive) { apply { $0.extraFolders.removeAll { $0 == folder } } } label: {
                            Image(systemName: "minus.circle")
                        }.buttonStyle(.borderless).help("Stop giving the agent this folder")
                    }
                }
                Button("Add a Folder the Agent May Change…") {
                    chooseFolder { url in apply { if !$0.extraFolders.contains(url.path) { $0.extraFolders.append(url.path) } } }
                }
                Toggle("Let sandboxed commands use the network (Codex)", isOn: Binding(
                    get: { plugin.settings.allowNetwork }, set: { v in apply { $0.allowNetwork = v } }))
            }
            Stepper("Stop a run after \(settings.timeoutMinutes) min", value: Binding(
                get: { plugin.settings.timeoutMinutes }, set: { v in apply { $0.timeoutMinutes = v } }), in: 1...240)
        } header: {
            Text("What the agent may do")
        } footer: {
            Text("The agent runs without asking for each step, inside this scope. Workspace keeps commands in a sandbox limited to the working and extra folders; installing software system-wide needs Full access. Whatever the scope, its instructions tell it not to spend money, send messages as you, or delete your files.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            Toggle("When a ticket is waiting for you", isOn: Binding(
                get: { plugin.settings.notifyYourTurn }, set: { v in apply { $0.notifyYourTurn = v } }))
            Toggle("On the day something is due", isOn: Binding(
                get: { plugin.settings.notifyDue }, set: { v in apply { $0.notifyDue = v } }))
            if settings.notifyDue {
                Stepper("No time set: remind at \(settings.dueNotifyHour):00", value: Binding(
                    get: { plugin.settings.dueNotifyHour }, set: { v in apply { $0.dueNotifyHour = v } }), in: 0...23)
                Stepper("Time set: remind \(settings.dueLeadHours) h before", value: Binding(
                    get: { plugin.settings.dueLeadHours }, set: { v in apply { $0.dueLeadHours = v } }), in: 0...48)
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Click a notification to open its ticket. Reminders cover every open ticket with a due date. macOS asks once whether Quick Capture may send notifications.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            Toggle("Let the agent update Quick Capture itself", isOn: Binding(
                get: { plugin.settings.selfUpdate }, set: { v in apply { $0.selfUpdate = v } }))
            if settings.selfUpdate {
                LabeledContent("Source folder") {
                    HStack {
                        Text(plugin.selfUpdate.projectFolder?.path ?? "not set").lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Choose…") { plugin.chooseSelfUpdateFolder() }
                    }
                }
                Text("Every rebuild and restart requires your confirmation and requires no running or queued ticket agents.")
                    .font(.caption).foregroundStyle(.secondary)
                if let problem = plugin.selfUpdate.problem {
                    Label(problem, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Self-update")
        } footer: {
            Text("The agent may edit this app's source and order a rebuild + restart. Before every run the folder is snapshotted into git (your uncommitted work included), the installed app is backed up before a restart, and if the new version doesn't start the old app and source come back on their own. Roll back any change from Tickets → Agent → App updates. Needs Workspace or Full access.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Advanced") {
            TextField("Claude Code CLI", text: binding(\.claudePath), prompt: Text("find automatically"))
            TextField("Codex CLI", text: binding(\.codexPath), prompt: Text("find automatically"))
            TextField("Pi CLI", text: binding(\.piPath), prompt: Text("find automatically"))
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
        }
    }

    private func chooseFolder(_ done: (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        done(url)
    }

    private func apply(_ change: (inout TicketsSettings) -> Void) {
        let before = plugin.settings
        do { try plugin.update(change); error = nil } catch { self.error = error.localizedDescription }
        let after = plugin.settings
        if before.claudePath != after.claudePath || before.codexPath != after.codexPath || before.piPath != after.piPath {
            Task { await plugin.detectAgents(force: true) }
        }
    }

    private func modelBinding(_ kind: TicketAgentKind) -> Binding<String> {
        let key: WritableKeyPath<TicketsSettings, String> = kind == .claude ? \.claudeModel : kind == .codex ? \.codexModel : \.piModel
        return Binding(get: { let s = plugin.settings; return s[keyPath: key].isEmpty && kind.rawValue == s.agent ? s.model : s[keyPath: key] },
                       set: { value in apply { $0[keyPath: key] = value; if kind.rawValue == $0.agent { $0.model = "" } } })
    }

    private func effortBinding(_ kind: TicketAgentKind) -> Binding<String> {
        let key: WritableKeyPath<TicketsSettings, String> = kind == .claude ? \.claudeEffort : kind == .codex ? \.codexEffort : \.piEffort
        return Binding(get: { plugin.settings[keyPath: key] }, set: { value in apply { $0[keyPath: key] = value } })
    }

    private func binding(_ key: WritableKeyPath<TicketsSettings, String>) -> Binding<String> {
        Binding(get: { plugin.settings[keyPath: key] }, set: { value in apply { $0[keyPath: key] = value } })
    }
}
