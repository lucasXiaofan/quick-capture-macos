import Foundation

/// The coding-agent CLIs that can work on tickets.
enum TicketAgentKind: String, CaseIterable, Codable {
    case claude, codex, pi

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .pi: return "Pi"
        }
    }

    var binary: String { rawValue }

    /// The effort levels the CLI accepts (Pi calls it "thinking").
    var efforts: [String] {
        switch self {
        case .claude: return ["low", "medium", "high", "xhigh", "max"]
        case .codex: return ["minimal", "low", "medium", "high", "xhigh"]
        case .pi: return ["off", "minimal", "low", "medium", "high", "xhigh"]
        }
    }

    var installHint: String {
        switch self {
        case .claude: return Provider.claude.installHint
        case .codex: return Provider.codex.installHint
        case .pi: return "Install with `npm i -g @mariozechner/pi-coding-agent`, then run `pi` once to sign in."
        }
    }

    var extraCandidates: [String] {
        switch self {
        case .claude: return Provider.claude.extraCandidates
        case .codex: return Provider.codex.extraCandidates
        case .pi: return []
        }
    }

    /// What each access level means for this CLI, shown in Settings.
    func accessNote(_ access: String) -> String {
        switch (self, access) {
        case (_, "read_only"): return self == .pi ? "Reads files only." : "Reads files and searches the web. No edits, no commands."
        case (.claude, "full"), (.codex, "full"), (.pi, "full"):
            return "No sandbox: runs any command, installs software, edits any file you can."
        case (.claude, _): return "Edits files and runs sandboxed commands in the working and extra folders; searches the web."
        case (.codex, _): return "Edits files and runs sandboxed commands in the working and extra folders; searches the web."
        case (.pi, _): return "Reads and edits files, but runs no commands: Pi has no sandbox, so commands need Full access."
        }
    }
}

struct TicketModelOption {
    let id: String
    let label: String
}

/// Finds the installed CLIs.
@MainActor
final class TicketAgentDetector: ObservableObject {
    @Published private(set) var installs: [TicketAgentKind: AgentInstall] = [:]
    @Published private(set) var detecting = false
    @Published private(set) var hasRun = false
    /// Pi's models as "provider/id", from `pi --list-models`.
    private(set) var piModels: [String] = []

    /// What can go in an agent's model field. `including` keeps a custom value (typed into config.json) selectable.
    func models(for kind: TicketAgentKind, including: String = "") -> [TicketModelOption] {
        var out: [TicketModelOption]
        switch kind {
        case .claude:
            out = [("sonnet", "Sonnet"), ("opus", "Opus"), ("fable", "Fable"), ("haiku", "Haiku")].map { TicketModelOption(id: $0.0, label: $0.1) }
        case .codex:
            out = [TicketModelOption(id: "gpt-6-luna", label: "GPT-6 Luna")]
                + AgentDetector.codexCachedModels().filter { $0.id != "gpt-6-luna" }.map { TicketModelOption(id: $0.id, label: $0.label) }
        case .pi:
            out = piModels.map { TicketModelOption(id: $0, label: $0) }
        }
        if !including.isEmpty, !out.contains(where: { $0.id == including }) { out.append(TicketModelOption(id: including, label: including)) }
        return out
    }

    func detect(settings: TicketsSettings, force: Bool = false) async {
        guard !detecting else { return }
        detecting = true
        if force { await LoginEnvironment.shared.reset() }
        var found: [TicketAgentKind: AgentInstall] = [:]
        for kind in TicketAgentKind.allCases {
            let configured = (settings.path(for: kind) as NSString).expandingTildeInPath
            let path: String?
            if !configured.isEmpty {
                path = FileManager.default.isExecutableFile(atPath: configured) ? configured : nil
            } else {
                path = await LoginEnvironment.shared.find(kind.binary, extraCandidates: kind.extraCandidates)
            }
            guard let path else { continue }
            let env = await LoginEnvironment.shared.environment(for: path)
            let out = try? await Shell.run(path, ["--version"], environment: env, timeout: 15)
            let version = (out?.stdout ?? "").split(separator: "\n").first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            found[kind] = AgentInstall(path: path, version: version)
            if kind == .pi {
                let list = try? await Shell.run(path, ["--list-models"], environment: env, timeout: 20)
                piModels = (list?.stdout ?? "").split(separator: "\n").dropFirst().compactMap { line in
                    let cols = line.split(whereSeparator: \.isWhitespace)
                    return cols.count >= 2 ? "\(cols[0])/\(cols[1])" : nil
                }
            }
        }
        installs = found
        detecting = false
        hasRun = true
    }
}

/// Builds each CLI's command line for one ticket turn. Every turn is a fresh, unsaved session: the prompt
/// carries the whole ticket, so any agent can pick up any ticket.
/// An agent and effort picked for one run, instead of the defaults in Settings.
struct TicketAgentChoice: Codable {
    var agent: TicketAgentKind?
    var model: String?
    var effort: String?
    /// The agent picks an existing ticket and appends this capture to it instead of keeping a new ticket.
    var append = false

    /// Freeze defaults when sent, so waiting in the queue cannot change the chosen backend.
    func resolved(settings: TicketsSettings) -> TicketAgentChoice {
        let kind = agent ?? TicketAgentKind(rawValue: settings.agent) ?? .claude
        return TicketAgentChoice(agent: kind, model: model ?? settings.model(for: kind),
                                 effort: effort ?? settings.effort(for: kind), append: append)
    }
}

enum TicketAgentCommand {
    static func arguments(kind: TicketAgentKind, settings: TicketsSettings, model: String, effort: String, directory: URL,
                          readable: [URL], extra: [URL], images: [URL]) -> [String] {
        switch kind {
        case .claude:
            var args = ["-p", "--output-format", "stream-json", "--verbose", "--no-session-persistence"]
            if !model.isEmpty { args += ["--model", model] }
            if !effort.isEmpty { args += ["--effort", effort] }
            switch settings.access {
            case "read_only":
                args += ["--add-dir"] + (readable + extra).map(\.path)
                args += ["--permission-mode", "default",
                         "--allowedTools", "Read", "Glob", "Grep", "WebSearch", "WebFetch",
                         "--disallowedTools", "Edit", "Write", "NotebookEdit", "Bash"]
            case "full":
                args += ["--dangerously-skip-permissions"]
            default:
                args += ["--add-dir"] + (readable + extra).map(\.path)
                args += ["--permission-mode", "acceptEdits", "--allowedTools", "WebSearch", "WebFetch",
                         "--settings", #"{"sandbox":{"enabled":true,"autoAllowBashIfSandboxed":true}}"#]
            }
            return args  // The prompt is written to stdin.
        case .codex:
            var args = ["exec", "--json", "--skip-git-repo-check"]
            for image in images { args += ["-i", image.path] }
            if !model.isEmpty { args += ["-m", model] }
            if !effort.isEmpty { args += ["-c", "model_reasoning_effort=\"\(effort)\""] }
            args += ["-c", "approval_policy=\"never\"", "-c", "web_search=\"live\"", "-C", directory.path]
            switch settings.access {
            case "read_only": args += ["-s", "read-only"]
            case "full": args += ["--dangerously-bypass-approvals-and-sandbox"]
            default:
                args += ["-s", "workspace-write"]
                if settings.allowNetwork { args += ["-c", "sandbox_workspace_write.network_access=true"] }
                for dir in extra { args += ["--add-dir", dir.path] }
            }
            return args + ["-"]
        case .pi:
            var args = ["-p", "--no-session", "--mode", "json"]
            if !model.isEmpty { args += ["--model", model] }
            if !effort.isEmpty { args += ["--thinking", effort] }
            switch settings.access {
            case "read_only": args += ["--tools", "read,grep,find,ls"]
            case "full": break
            default: args += ["--tools", "read,grep,find,ls,edit,write"]
            }
            return args  // The prompt is written to stdin.
        }
    }
}

/// Reads a CLI's JSON lines: what it is doing (for the live status and the tool log) and what it finally said.
struct TicketAgentParser {
    let kind: TicketAgentKind
    /// Text since the last tool call — the reply, without "let me look that up" narration.
    private(set) var reply: [String] = []
    private(set) var tools: [String] = []
    private(set) var finished = false
    private(set) var error: String?
    private var resultText: String?

    init(kind: TicketAgentKind) { self.kind = kind }

    var text: String {
        let joined = reply.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? (resultText ?? "").trimmingCharacters(in: .whitespacesAndNewlines) : joined
    }

    /// Returns a short description when the agent started doing something.
    mutating func parse(_ line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        switch kind {
        case .claude: return parseClaude(obj)
        case .codex: return parseCodex(obj)
        case .pi: return parsePi(obj)
        }
    }

    private mutating func tool(_ name: String, _ detail: String) -> String {
        let oneLine = detail.replacingOccurrences(of: "\n", with: " ⏎ ")
        let entry = oneLine.isEmpty ? name : "\(name): \(oneLine.count > 300 ? String(oneLine.prefix(300)) + "…" : oneLine)"
        if tools.last != entry { tools.append(entry) }
        if tools.count > 200 { tools.removeFirst() }
        reply = []
        return entry
    }

    private mutating func parseClaude(_ obj: [String: Any]) -> String? {
        switch obj["type"] as? String {
        case "assistant":
            guard obj["parent_tool_use_id"] == nil || obj["parent_tool_use_id"] is NSNull,
                  let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return nil }
            var activity: String?
            for block in content {
                switch block["type"] as? String {
                case "text":
                    if let text = block["text"] as? String, !text.isEmpty { reply.append(text) }
                case "tool_use":
                    let name = block["name"] as? String ?? "Tool"
                    activity = tool(name, AgentEventParser.describe(name, block["input"] as? [String: Any] ?? [:]))
                default: break
                }
            }
            return activity
        case "result":
            finished = true
            resultText = obj["result"] as? String
            if obj["is_error"] as? Bool == true || (obj["subtype"] as? String).map({ $0 != "success" }) == true {
                error = (obj["result"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? "Claude Code stopped: \(obj["subtype"] as? String ?? "error")"
            }
            return nil
        default:
            return nil
        }
    }

    private mutating func parseCodex(_ obj: [String: Any]) -> String? {
        switch obj["type"] as? String {
        case "item.started", "item.completed":
            guard let item = obj["item"] as? [String: Any] else { return nil }
            let started = obj["type"] as? String == "item.started"
            switch item["type"] as? String {
            case "agent_message":
                if !started, let text = item["text"] as? String, !text.isEmpty { reply.append(text) }
                return nil
            case "command_execution":
                guard started else { return nil }
                let command = (item["command"] as? [String])?.last ?? item["command"] as? String ?? ""
                return tool("Shell", command)
            case "web_search":
                guard !started else { return nil }
                let query = (item["query"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? ((item["action"] as? [String: Any])?["query"] as? String) ?? ""
                return tool("Web search", query)
            case "file_change":
                guard !started else { return nil }
                let paths = (item["changes"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
                return tool("Edit", paths.joined(separator: ", "))
            case "mcp_tool_call":
                guard started else { return nil }
                return tool([item["server"] as? String, item["tool"] as? String].compactMap { $0 }.joined(separator: "."), "")
            default:
                return nil
            }
        case "turn.completed":
            finished = true
            return nil
        case "turn.failed":
            finished = true
            error = (obj["error"] as? [String: Any])?["message"] as? String ?? "Codex turn failed."
            return nil
        case "error":
            error = obj["message"] as? String ?? "Codex error"
            return nil
        default:
            return nil
        }
    }

    private mutating func parsePi(_ obj: [String: Any]) -> String? {
        switch obj["type"] as? String {
        case "message_end":
            guard let message = obj["message"] as? [String: Any], message["role"] as? String == "assistant" else { return nil }
            let text = (message["content"] as? [[String: Any]] ?? [])
                .filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
            if !text.isEmpty { reply.append(text) }
            if message["stopReason"] as? String == "error" {
                error = message["errorMessage"] as? String ?? "Pi stopped with an error."
            }
            return nil
        case "tool_execution_start":
            let name = obj["toolName"] as? String ?? "tool"
            let args = obj["args"] as? [String: Any] ?? [:]
            let detail = (args["command"] ?? args["path"] ?? args["pattern"] ?? args.values.first { $0 is String }) as? String ?? ""
            return tool(name, detail)
        case "agent_end":
            finished = true
            return nil
        default:
            return nil
        }
    }
}

/// What the agent decided about a ticket: the JSON block that ends its reply.
struct TicketAgentResult {
    var reply: String
    var fields: [String: Any]?

    static func contract(selfUpdate: Bool) -> String {
        guard selfUpdate else { return baseContract }
        return baseContract.replacingOccurrences(of: "\n  \"decisions\":", with: "\n  \"restart_app\": false,\n  \"decisions\":")
            + "\n\"restart_app\": true rebuilds and restarts Quick Capture with the changes you made to its source in this run (see “Changing the app itself”)."
    }

    static var contract: String { contract(selfUpdate: false) }

    private static let baseContract = """
        End your reply with exactly one fenced block like this (it is removed before I read the reply). \
        Leave out a field to keep it unchanged.

        ```ticket
        {
          "title": "short, specific title",
          "summary": "one line: the answer, the principle, or what the resource is",
          "kind": "one kind id from the list",
          "project": "an existing project id, a new project's name, or \\"\\" for none",
          "project_category": "research | class | personal, or a new category (only for a new project)",
          "related_projects": ["existing project ids relevant to this ticket"],
          "tags": ["only tags from the Tags list"],
          "status": "waiting_human | closed",
          "start": "YYYY-MM-DD or null",
          "due": "YYYY-MM-DD or null",
          "due_time": "HH:MM (24h) when the deadline has a time of day, else null",
          "log": [{"date": "YYYY-MM-DD", "name": "meditation", "value": 5, "unit": "min", "note": ""}],
          "takeaways": ["new takeaways to add"],
          "actions": [{"tool": "create_ticket", "text": "…"}, {"tool": "define_tag", "id": "…", "meaning": "…", "action": "…"}],
          "decisions": ["one short line per decision, with the reason: why this kind, project, status, merge"]
        }
        ```

        "log" adds dated entries (habits). "tags" replaces this ticket's tags: any number, but only ones defined \
        under Tags, by full path (define a missing one with the define_tag tool in the same block; undefined tags are dropped). \
        "due" is a deadline; I am reminded at 7:00 that morning, or five hours before "due_time". \
        "actions" is the list of tools to run, in order (see Tools); leave it out when there is nothing to organize.
        """

    static func parse(_ text: String) -> TicketAgentResult {
        guard let regex = try? NSRegularExpression(pattern: "```ticket[^\\n]*\\n([\\s\\S]*?)```"),
              let match = regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).last else {
            return TicketAgentResult(reply: text.trimmingCharacters(in: .whitespacesAndNewlines), fields: nil)
        }
        let ns = text as NSString
        let body = ns.substring(with: match.range(at: 1))
        let reply = ns.replacingCharacters(in: match.range, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
        return TicketAgentResult(reply: reply, fields: fields)
    }
}

/// Runs the agent on tickets, two at a time, and applies what it decides.
@MainActor
final class TicketAgentRunner {
    struct Run {
        var activity = "Starting…"
        var tools: [String] = []
        var process: StreamingProcess?
        var stopped = false
        var token = UUID()
        var append = false
    }

    private unowned let plugin: TicketsPlugin
    private var store: TicketStore { plugin.store }
    private(set) var running: [Int: Run] = [:]
    private(set) var queue: [Int] = []
    private var choices: [Int: TicketAgentChoice] = [:]
    /// A ticket's live status changed.
    var onProgress: (() -> Void)?
    /// One at a time while the agent may edit the app: parallel runs would edit the same source.
    private var maxParallel: Int { plugin.settings.selfUpdate ? 1 : 2 }

    init(plugin: TicketsPlugin) { self.plugin = plugin }

    private var choicesFile: URL { store.root.appendingPathComponent("agent/queued-choices.json") }

    private func saveChoices() {
        do {
            try FileManager.default.createDirectory(at: choicesFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(choices).write(to: choicesFile, options: .atomic)
        } catch {
            Toast.show("Couldn't save queued model choices: \(error.localizedDescription)", symbol: "exclamationmark.triangle", isError: true)
        }
    }

    func isBusy(_ id: Int) -> Bool { running[id] != nil || queue.contains(id) }

    func enqueue(_ id: Int, choice: TicketAgentChoice? = nil) {
        guard store.tickets[id] != nil else { return }
        // A reply sent during a run belongs to the next turn; keep its picker choice.
        if let choice { choices[id] = choice.resolved(settings: plugin.settings) }
        if isBusy(id) { saveChoices(); onProgress?(); return }
        if choices[id] == nil { choices[id] = TicketAgentChoice().resolved(settings: plugin.settings) }
        saveChoices()
        queue.append(id)
        onProgress?()
        pump()
    }

    /// Queues every ticket waiting for the agent, except ones whose last run failed (those need a manual retry).
    func enqueuePending() {
        // Captures arriving while an update builds must retain their model after the restart.
        if let data = try? Data(contentsOf: choicesFile),
           let saved = try? JSONDecoder().decode([Int: TicketAgentChoice].self, from: data) {
            for (id, choice) in saved where choices[id] == nil { choices[id] = choice }
        }
        for ticket in store.sorted.reversed()
        where ticket.mergedInto == nil && (ticket.status == .unprocessed || ticket.status == .needsAgent)
            && ticket.messages.last?.role == "human" {
            enqueue(ticket.id)
        }
    }

    func stop(_ id: Int) {
        queue.removeAll { $0 == id }
        choices[id] = nil
        saveChoices()
        if var run = running[id] {
            run.stopped = true
            running[id] = run
            run.process?.stop()
        }
        onProgress?()
    }

    func stopAll() {
        queue = []
        for id in running.keys { stop(id) }
    }

    /// Starts the next waiting runs (also called when a self-update step is done).
    func resume() { pump() }

    private func pump() {
        while running.count < maxParallel, !queue.isEmpty, !plugin.selfUpdate.isBusy {
            start(queue.removeFirst())
        }
    }

    private func start(_ id: Int) {
        guard let ticket = store.tickets[id] else { return }
        let settings = plugin.settings
        let choice = choices.removeValue(forKey: id)
        saveChoices()
        guard let kind = choice?.agent ?? TicketAgentKind(rawValue: settings.agent) else { return }
        let model = choice?.model ?? settings.model(for: kind)
        // An effort picked for this run wins; otherwise the one set for this agent in Settings.
        let selectedEffort = choice?.effort ?? settings.effort(for: kind)
        let effort = kind.efforts.contains(selectedEffort) ? selectedEffort : ""
        var run = Run()
        run.append = choice?.append == true
        running[id] = run
        onProgress?()
        let token = run.token
        let humanCount = ticket.messages.filter { $0.role == "human" }.count
        let label = kind.rawValue + (model.isEmpty ? "" : ":" + model) + (effort.isEmpty ? "" : " · " + effort)

        Task { [weak self] in
            guard let self else { return }
            if !self.plugin.detector.hasRun { await self.plugin.detector.detect(settings: settings) }
            guard let install = self.plugin.detector.installs[kind] else {
                self.finish(id, token: token, humanCount: humanCount, label: label, text: "", tools: [],
                            failure: "\(kind.displayName) isn't installed. \(kind.installHint)")
                return
            }
            let directory = self.plugin.workingDirectory
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let extra = self.plugin.extraFolders
            let attachmentDir = self.store.attachmentDir(id)
            let images = ticket.messages.flatMap(\.attachments).map { attachmentDir.appendingPathComponent($0) }
                .filter { ["png", "jpg", "jpeg", "gif", "webp"].contains($0.pathExtension.lowercased()) }
            let selfBefore = await self.plugin.selfUpdate.beforeRun(ticket: id)
            let appFolder = selfBefore == nil ? nil : self.plugin.selfUpdate.projectFolder
            let prompt = TicketPrompt.build(ticket: ticket, store: self.store, settings: settings, kind: kind,
                                            directory: directory, extra: extra, appFolder: appFolder, append: run.append)
            let args = TicketAgentCommand.arguments(kind: kind, settings: settings, model: model, effort: effort,
                                                    directory: directory, readable: [self.store.root], extra: extra, images: images)
            let env = await LoginEnvironment.shared.environment(for: install.path)
            guard let current = self.running[id], current.token == token, !current.stopped else {
                self.finish(id, token: token, humanCount: humanCount, label: label, text: "", tools: [], failure: nil, selfBefore: selfBefore)
                return
            }
            let parser = Box(TicketAgentParser(kind: kind))
            let process = StreamingProcess(executable: install.path, arguments: args, directory: directory,
                                           environment: env, input: prompt)
            process.onLine = { [weak self] line in
                guard let self, let activity = parser.value.parse(line) else { return }
                guard var run = self.running[id], run.token == token else { return }
                run.activity = activity
                run.tools = parser.value.tools
                self.running[id] = run
                self.onProgress?()
            }
            process.onExit = { [weak self] status, stderr in
                guard let self else { return }
                let result = parser.value
                var failure = result.error
                if failure == nil, result.text.isEmpty {
                    let tail = stderr.split(separator: "\n").suffix(6).joined(separator: "\n")
                    failure = "\(kind.displayName) exited (\(status)) without a reply." + (tail.isEmpty ? "" : "\n\n" + tail)
                }
                self.finish(id, token: token, humanCount: humanCount, label: label, text: result.text,
                            tools: result.tools, failure: failure, selfBefore: selfBefore)
            }
            self.running[id]?.process = process
            do { try process.start() } catch {
                self.finish(id, token: token, humanCount: humanCount, label: label, text: "", tools: [],
                            failure: "Couldn't start \(install.path): \(error.localizedDescription)", selfBefore: selfBefore)
                return
            }
            let minutes = max(1, settings.timeoutMinutes)
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(minutes * 60)) { [weak self] in
                guard let self, let run = self.running[id], run.token == token, !run.stopped else { return }
                self.running[id]?.activity = "Stopped after \(minutes) min"
                self.stop(id)
            }
        }
    }

    static func ticketNumber(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        guard let text = value as? String else { return nil }
        return Int(text.trimmingCharacters(in: CharacterSet(charactersIn: "# ")))
    }

    private func finish(_ captured: Int, token: UUID, humanCount: Int, label: String, text: String, tools: [String], failure: String?,
                        selfBefore: String? = nil) {
        var id = captured
        guard let run = running[id], run.token == token else { return }
        running[id] = nil
        defer { onProgress?(); pump() }
        if selfBefore != nil { plugin.selfUpdate.hold() }
        guard store.tickets[id] != nil else {
            if let selfBefore { Task { await plugin.selfUpdate.afterRun(ticket: id, before: selfBefore, restart: false) } }
            return
        }
        let now = TicketDates.now()
        if run.stopped {
            if let selfBefore { Task { await plugin.selfUpdate.afterRun(ticket: id, before: selfBefore, restart: false) } }
            store.update(id) { $0.messages.append(TicketMessage(role: "system", text: "Stopped. \(run.activity.hasPrefix("Stopped after") ? run.activity + "." : "") Press Run agent to try again.".replacingOccurrences(of: "  ", with: " "), at: now, tools: tools.isEmpty ? nil : tools)) }
            return
        }
        if let failure {
            if let selfBefore { Task { await plugin.selfUpdate.afterRun(ticket: id, before: selfBefore, restart: false) } }
            store.update(id) { $0.messages.append(TicketMessage(role: "system", text: failure, at: now, tools: tools.isEmpty ? nil : tools)) }
            plugin.notifier.yourTurn(id, text: failure, failed: true)
            return
        }
        let result = TicketAgentResult.parse(text)
        var changes: [String] = []
        var reasons = (result.fields?["decisions"] as? [String]) ?? []
        if result.fields == nil { reasons.append("The agent returned no ticket block; only its reply was saved.") }
        let fields = result.fields ?? [:]

        // Older reply formats: "new_kind" is the add_kind tool.
        if let new = fields["new_kind"] as? [String: Any], let line = store.addKind(new) { changes.append(line) }
        var projectID: String?
        if let name = fields["project"] as? String {
            projectID = name.isEmpty ? "" : store.project(named: name, type: (fields["project_category"] ?? fields["project_type"]) as? String)
        }
        if let updates = fields["project_updates"] as? [[String: Any]] {
            var structure = store.structure
            for update in updates {
                guard let project = update["id"] as? String,
                      let index = structure.projects.firstIndex(where: { $0.id == project }) else { continue }
                if let context = update["context"] as? String { structure.projects[index].context = context }
                if let ids = update["context_ticket_ids"] as? [Int] {
                    structure.projects[index].contextTicketIDs = Array(Set(ids.filter { store.tickets[$0] != nil })).sorted()
                }
                changes.append("project context updated: \(project)")
            }
            store.setStructure(structure)
        }
        var stillWaiting = (store.tickets[id]?.messages.filter { $0.role == "human" }.count ?? 0) > humanCount
        // Append mode: the capture joins the ticket the agent picked, and the rest of the block applies to that ticket.
        if run.append, let target = Self.ticketNumber(fields["append_to"]), store.append(id, into: target) {
            changes.append("appended #\(id) to #\(target)")
            id = target
            stillWaiting = false
        }
        // Tools run before the ticket's own fields, so a tag defined in this turn can be used in it.
        if let actions = fields["actions"] as? [[String: Any]] { changes += store.apply(actions: actions, from: id) }
        guard store.tickets[id] != nil else {
            // A tool merged this ticket away; the rest of the block has nothing to apply to.
            store.add(TicketDecision(at: now, ticket: id, agent: label, changes: changes, reasons: reasons))
            store.onChange?()
            return
        }
        let projectIDs = Set(store.structure.projects.map(\.id))
        let kinds = Set(store.structure.kinds.map(\.id))
        var refused: [String] = []
        let tags = (fields["tags"] as? [String]).map { store.allowed($0, keeping: store.tickets[id]?.tags ?? [], refused: &refused) }
        changes += refused

        store.update(id) { ticket in
            ticket.messages.append(TicketMessage(role: "agent", text: result.reply.isEmpty ? "(no reply)" : result.reply,
                                                 at: now, agent: label, tools: tools.isEmpty ? nil : tools))
            func change(_ name: String, _ old: String, _ new: String) {
                if old != new { changes.append("\(name): \(old.isEmpty ? "—" : old) → \(new.isEmpty ? "—" : new)") }
            }
            if let title = (fields["title"] as? String)?.trimmingCharacters(in: .whitespaces), !title.isEmpty {
                change("title", ticket.title, title); ticket.title = title
            }
            if let summary = fields["summary"] as? String { ticket.summary = summary }
            if let kind = fields["kind"] as? String, kinds.contains(TicketStructure.slug(kind)) {
                change("kind", ticket.kind, TicketStructure.slug(kind)); ticket.kind = TicketStructure.slug(kind)
            }
            if let projectID { change("project", ticket.project, projectID); ticket.project = projectID }
            if let related = fields["related_projects"] as? [String] {
                ticket.relatedProjects = Array(Set(related.filter { projectIDs.contains($0) && $0 != ticket.project })).sorted()
            }
            if let tags {
                // Bookkeeping tags the app set stay, whatever the agent lists.
                let next = tags + ticket.tags.filter { TicketStore.isInternalTag($0) && !tags.contains($0) }
                if next != ticket.tags { changes.append("tags: " + (next.isEmpty ? "—" : next.joined(separator: " "))) }
                ticket.tags = next
            }
            for (key, path) in [("start", \Ticket.start), ("due", \Ticket.due)] where fields[key] != nil {
                let value = (fields[key] as? String).flatMap { TicketDates.isDay($0) ? $0 : nil }
                change(key, ticket[keyPath: path] ?? "", value ?? "")
                ticket[keyPath: path] = value
            }
            if fields["due_time"] != nil { ticket.dueTime = (fields["due_time"] as? String).flatMap(TicketDates.time) }
            if ticket.due == nil { ticket.dueTime = nil }
            for entry in fields["log"] as? [[String: Any]] ?? [] {
                guard let name = (entry["name"] as? String).map({ $0.lowercased().trimmingCharacters(in: .whitespaces) }), !name.isEmpty else { continue }
                let date = (entry["date"] as? String).flatMap { TicketDates.isDay($0) ? $0 : nil } ?? TicketDates.today()
                let item = TicketLogEntry(date: date, name: name, value: (entry["value"] as? NSNumber)?.doubleValue,
                                          unit: entry["unit"] as? String, note: (entry["note"] as? String).flatMap { $0.isEmpty ? nil : $0 })
                if !ticket.log.contains(item) { ticket.log.append(item); changes.append("log: \(name) \(date)") }
            }
            for takeaway in fields["takeaways"] as? [String] ?? [] where !takeaway.isEmpty && !ticket.takeaways.contains(takeaway) {
                ticket.takeaways.append(takeaway); changes.append("takeaway added")
            }
            let status: Ticket.Status = stillWaiting ? .needsAgent
                : (fields["status"] as? String) == "closed" ? .closed : .waitingHuman
            change("status", ticket.status.rawValue, status.rawValue)
            ticket.status = status
            if !changes.isEmpty || !reasons.isEmpty {
                ticket.history.append(TicketEvent(at: now, by: "agent", text: (changes + reasons).joined(separator: " · ")))
            }
        }
        if let others = fields["merge_with"] as? [Any] {
            let ids = others.compactMap { ($0 as? NSNumber)?.intValue ?? Int("\($0)") }.filter { $0 != id && store.tickets[$0] != nil }
            if !ids.isEmpty, let merged = store.merge([id] + ids, by: "agent") {
                changes.append("merged with " + ids.map { "#\($0)" }.joined(separator: ", ") + " → #\(merged.id)")
            }
        }
        store.add(TicketDecision(at: now, ticket: id, agent: label, changes: changes, reasons: reasons))
        store.onChange?()
        // A merge moved the conversation to another ticket; that is the one to open.
        let shown = store.tickets[id]?.mergedInto ?? id
        if store.tickets[shown]?.status == .waitingHuman { plugin.notifier.yourTurn(shown, text: result.reply) }
        if let selfBefore {
            let restart = (fields["restart_app"] as? Bool) == true
            Task { await plugin.selfUpdate.afterRun(ticket: id, before: selfBefore, restart: restart) }
        }
        if stillWaiting { enqueue(id) }
    }
}

private final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

/// The prompt for one turn: instructions, structure, principles, corrections, related tickets, the ticket.
@MainActor
enum TicketPrompt {
    /// Everything the agent is told that doesn't depend on the ticket — shown in the window so it is easy to check.
    static func standing(store: TicketStore) -> String {
        var out = "# Instructions\n\(store.instructions)\n\n# Kinds\nid (view) — what it looks like → what you do\n"
        for kind in store.structure.kinds {
            out += "- \(kind.id) (\(kind.view)) — \(kind.description) → \(kind.rule)\n"
        }
        out += "\n# Projects\nResearch, classes and personal projects are all projects; there are no nested projects.\n"
        if store.structure.projects.isEmpty { out += "(none yet)\n" }
        for project in store.structure.projects {
            out += "- \(project.id) — \(project.name) (\(project.type))\(project.note.isEmpty ? "" : ": " + project.note)\n"
        }
        for project in store.structure.projects where !project.context.isEmpty || !project.contextTicketIDs.isEmpty {
            out += "\n## Project context: \(project.id)\n\(project.context)\n"
            out += "Context tickets: " + project.contextTicketIDs.map { "#\($0)" }.joined(separator: ", ") + "\n"
        }
        out += "\n# Tags\nA ticket has one kind, at most one project, and any number of tags. Kinds and projects have their own lists above; "
        out += "tags are the layered vocabulary in \(store.tagsDir.path) (rules: SKILL.md there). A tag is a full path: depth 1 a purpose or area, "
        out += "depth 2 a field, depth 3+ one concept. Each carries a meaning and an action. Use only tags listed here, with the full path; reuse before "
        out += "inventing; a project, course or paper name is never a tag; tags marked LEGACY are not for new tickets.\n"
        let counts = store.tagCounts
        let top = store.structure.tags.filter { TicketTagFiles.depth($0.id) <= 2 }, deep = store.structure.tags.filter { TicketTagFiles.depth($0.id) > 2 }
        out += "Index (depth 1-2): `tag`: meaning. Action: …\n"
        if top.isEmpty { out += "(none defined yet)\n" }
        for tag in top { out += TicketTagFiles.text(tag) + "\n" }
        if !deep.isEmpty {
            out += "Deeper tags (definitions in references/<l1>/<l2>.md; read the file before using one you are unsure of): " + deep.map(\.id).joined(separator: ", ") + "\n"
        }
        let undefined = counts.keys.filter { !store.isDefinedTag($0) }.sorted()
        if !undefined.isEmpty {
            out += "Loose tags on tickets, not in the vocabulary (when you meet one: merge_tags it into a defined tag, define it under a parent, or delete it): "
                + undefined.map { "\($0) (\(counts[$0] ?? 0))" }.joined(separator: ", ") + "\n"
        }
        if let map = store.tagMap {
            out += "\n## How to classify (tags/references/map.md)\nGive every ticket exactly one top-level purpose from the index (or its depth-2 child), chosen with this guide.\n"
                + String(map.prefix(4000)) + "\n"
        }
        if !store.designs.isEmpty {
            out += "\n# Designs\nFlowcharts the user and you both read and edit (JSON Canvas files in \(store.designsDir.path)). Read one when a ticket refers to it.\n"
            for design in store.designs { out += "- \(design.id) — \(design.title)\(design.project.isEmpty ? "" : " · " + design.project)\(design.summary.isEmpty ? "" : ": " + design.summary)\n" }
        }
        let principles = store.sorted.filter { $0.kind == "principle" && $0.mergedInto == nil }
        out += "\n# Principles\n"
        if principles.isEmpty { out += "(none yet)\n" }
        for p in principles.reversed() { out += "- \(p.summary.isEmpty ? p.title : p.summary) [#\(p.id)]\n" }
        out += "\n# Corrections\nThings I told you that you got wrong. Don't repeat them.\n"
        if store.corrections.isEmpty { out += "(none yet)\n" }
        for c in store.corrections.suffix(40) { out += "- \(c.ticket.map { "[#\($0)] " } ?? "")\(c.text)\n" }
        out += "\n" + TicketTools.prompt()
        return out
    }

    /// Added to the prompt while the agent may change Quick Capture's own source.
    static func selfUpdateSection(_ folder: URL?) -> String {
        """

        # Changing the app itself
        This app, Quick Capture, is the project at \(folder?.path ?? "(unknown)"). You may change its source to carry out tickets \
        (features, fixes, changes to this ticket system). Follow the CLAUDE.md in that folder. Keep changes small and focused.
        - Never run scripts/build.sh --install, quit or relaunch the app: that would stop you mid-run.
        - Rebuilds and restarts always require the user's explicit confirmation and no running or queued ticket agents.
        - To request a rebuild and restart with your changes, set "restart_app": true in your ticket block, once your changes are \
        complete (run `swift build` first if your access allows). The app snapshots the project into git, builds, restarts, \
        and restores the previous version by itself if the new one doesn't start. If a build fails you will see the errors \
        in the conversation as an "App update" note.
        - Change nothing outside that folder for this.

        """
    }

    static func build(ticket: Ticket, store: TicketStore, settings: TicketsSettings, kind: TicketAgentKind,
                      directory: URL, extra: [URL], appFolder: URL? = nil, append: Bool = false) -> String {
        var out = standing(store: store)

        let others = store.sorted.filter { $0.id != ticket.id && $0.mergedInto == nil }
        let listed = Array(others.filter(\.isOpen).prefix(90)) + Array(others.filter { !$0.isOpen }.prefix(40))
        out += "\n# Other tickets\nUse these to reuse projects and tags, link related work, and find merge candidates.\n"
        if listed.isEmpty { out += "(none)\n" }
        for t in listed {
            let tags = t.tags.filter { !TicketStore.isInternalTag($0) }
            out += "#\(t.id) [\(t.status.rawValue)] \(t.kind)\(t.project.isEmpty ? "" : " · " + t.project)\(tags.isEmpty ? "" : " " + tags.map { "#" + $0 }.joined(separator: " "))\(t.start != nil && t.due != nil ? " \(t.start!)…\(t.due!)" : t.due.map { " due " + $0 } ?? "") — \(t.title)\n"
        }

        let weekday = DateFormatter()
        weekday.dateFormat = "EEEE HH:mm"
        out += """

            # Context
            Now: \(TicketDates.today()) \(weekday.string(from: Date())) (local time).
            Ticket files (read when you need another ticket's details; never edit them — change tickets with your tools): \(store.ticketsDir.path)/NNNN.md
            Working folder: \(directory.path)\(extra.isEmpty ? "" : "\nOther folders you may use: " + extra.map(\.path).joined(separator: ", "))
            Your access: \(kind.accessNote(settings.access))

            """

        if appFolder != nil { out += selfUpdateSection(appFolder) }

        out += "\n# Ticket #\(ticket.id)\n"
        out += "title: \(ticket.title)\nkind: \(ticket.kind)\(ticket.status == .unprocessed ? " (not classified yet)" : "")\n"
        out += "related_projects: \(ticket.relatedProjects.joined(separator: ", "))\nproject: \(ticket.project.isEmpty ? "—" : ticket.project)\nstatus: \(ticket.status.rawValue)\n"
        if !ticket.tags.isEmpty { out += "tags: \(ticket.tags.joined(separator: ", "))\n" }
        if let start = ticket.start { out += "start: \(start)\n" }
        if let due = ticket.due { out += "due: \(due)\(ticket.dueTime.map { " " + $0 } ?? "")\n" }
        if !ticket.takeaways.isEmpty { out += "takeaways:\n" + ticket.takeaways.map { "- \($0)\n" }.joined() }
        if !ticket.log.isEmpty {
            out += "log (latest): " + ticket.log.suffix(10).map { "\($0.date) \($0.name)" }.joined(separator: ", ") + "\n"
        }
        out += "\n## Conversation\n"
        let attachmentDir = store.attachmentDir(ticket.id)
        let recent = ticket.messages.suffix(30)
        if recent.count < ticket.messages.count { out += "(\(ticket.messages.count - recent.count) older messages left out)\n\n" }
        for message in recent where message.role != "system" || message.text.hasPrefix("App update") {
            let who = message.role == "human" ? "Me" : message.role == "agent" ? "You (\(message.agent ?? "agent"))" : "The app"
            var text = message.text
            if message.role == "agent", text.count > 4000 { text = String(text.prefix(4000)) + "\n… (shortened)" }
            out += "[\(message.at.prefix(16).replacingOccurrences(of: "T", with: " "))] \(who):\n\(text)\n"
            for name in message.attachments {
                out += "Attached file (open it): \(attachmentDir.appendingPathComponent(name).path)\n"
            }
            out += "\n"
        }
        if append {
            out += """
                # Append mode
                I sent this capture with "append": it belongs in an existing ticket (e.g. an exercise check-in goes to the \
                ticket that tracks exercise). Pick the single most relevant open ticket from Other tickets (read its file \
                if unsure) and add "append_to": its number to your ticket block. This capture then becomes that ticket's \
                latest message, and your reply and all other fields apply to that ticket: keep its title, kind and project \
                unless they should change, and answer as that ticket's next turn. If no ticket fits well, leave out \
                append_to and handle this as a new ticket.


                """
        }
        out += "# Your turn\nAnswer my last message following the instructions, the kind's rule, the principles and the corrections. "
        out += "Write the reply in Markdown.\n\n" + TicketAgentResult.contract(selfUpdate: appFolder != nil) + "\n"
        return out
    }
}
