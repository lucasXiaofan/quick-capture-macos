import Foundation

/// A coding-agent CLI the chat can drive. Both do their own web search, file editing and
/// command execution; the chat just renders their event streams.
enum Provider: String, CaseIterable, Codable {
    case claude, codex

    var displayName: String { self == .claude ? "Claude Code" : "Codex" }
    var binary: String { self == .claude ? "claude" : "codex" }
    var installHint: String {
        self == .claude
            ? "Install with `curl -fsSL https://claude.ai/install.sh | bash` (or `npm i -g @anthropic-ai/claude-code`), then run `claude` once to sign in."
            : "Install with `npm i -g @openai/codex` (or `brew install codex`), then run `codex` once to sign in."
    }
    /// Places outside PATH where the CLI is sometimes bundled.
    var extraCandidates: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return self == .claude
            ? ["\(home)/.claude/local/claude"]
            : ["/Applications/Codex.app/Contents/Resources/codex", "\(home)/Applications/Codex.app/Contents/Resources/codex"]
    }
}

struct AgentInstall: Equatable {
    let path: String
    let version: String
}

struct ChatModel: Hashable {
    let provider: Provider
    let id: String
    let label: String
    var key: String { provider.rawValue + ":" + id }

    static func parse(_ key: String) -> (Provider, String)? {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let provider = Provider(rawValue: parts[0]), !parts[1].isEmpty else { return nil }
        return (provider, parts[1])
    }
}

/// Finds the installed CLIs and the models each offers.
@MainActor
final class AgentDetector: ObservableObject {
    @Published private(set) var installs: [Provider: AgentInstall] = [:]
    @Published private(set) var detecting = false
    @Published private(set) var hasRun = false
    private var detection: Task<Void, Never>?

    func detect(settings: AIChatSettings, force: Bool = false) async {
        if let detection, !force { return await detection.value }
        if force, let detection { await detection.value }
        let task = Task { @MainActor in
            detecting = true
            if force { await LoginEnvironment.shared.reset() }
            var found: [Provider: AgentInstall] = [:]
            for provider in Provider.allCases {
                let configured = (settings.path(for: provider) as NSString).expandingTildeInPath
                let path: String?
                if !configured.isEmpty {
                    path = FileManager.default.isExecutableFile(atPath: configured) ? configured : nil
                } else {
                    path = await LoginEnvironment.shared.find(provider.binary, extraCandidates: provider.extraCandidates)
                }
                guard let path else { continue }
                let env = await LoginEnvironment.shared.environment(for: path)
                let out = try? await Shell.run(path, ["--version"], environment: env, timeout: 15)
                let version = (out?.stdout ?? "").split(separator: "\n").first.map(String.init)?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                found[provider] = AgentInstall(path: path, version: version)
            }
            installs = found
            detecting = false
            hasRun = true
        }
        detection = task
        await task.value
    }

    func models(including extra: String? = nil) -> [ChatModel] {
        var models: [ChatModel] = []
        if installs[.claude] != nil {
            models += [("sonnet", "Claude Sonnet"), ("opus", "Claude Opus"), ("fable", "Claude Fable"), ("haiku", "Claude Haiku")]
                .map { ChatModel(provider: .claude, id: $0.0, label: $0.1) }
        }
        if installs[.codex] != nil {
            models.append(ChatModel(provider: .codex, id: "gpt-6-luna", label: "GPT-6 Luna"))
            models += Self.codexCachedModels().filter { $0.id != "gpt-6-luna" }
        }
        if let extra, let (provider, id) = ChatModel.parse(extra), installs[provider] != nil,
           !models.contains(where: { $0.key == extra }) {
            models.append(ChatModel(provider: provider, id: id, label: id))
        }
        return models
    }

    /// Codex keeps the list of models the account can use in ~/.codex/models_cache.json.
    private static func codexCachedModels() -> [ChatModel] {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: home).appendingPathComponent("models_cache.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["models"] as? [[String: Any]] else { return [] }
        return list
            .filter { ($0["visibility"] as? String ?? "list") == "list" }
            .sorted { ($0["priority"] as? Int ?? 99) < ($1["priority"] as? Int ?? 99) }
            .compactMap { m in
                guard let slug = m["slug"] as? String else { return nil }
                let name = (m["display_name"] as? String ?? slug).replacingOccurrences(of: "-", with: " ")
                return ChatModel(provider: .codex, id: slug, label: name.replacingOccurrences(of: "GPT ", with: "GPT-"))
            }
    }
}

/// Builds each CLI's command line for one chat turn.
enum AgentCommand {
    static let instructions = """
        You are answering in a small chat window of a macOS menu-bar app. The window renders GitHub-flavored \
        Markdown and LaTeX math ($…$ inline, $$…$$ display), and every link in it is clickable. When you mention \
        a local file, write it as a Markdown link whose target is the file path relative to the working directory, \
        e.g. [main.swift](Sources/App/main.swift). When you use information from the web, cite it with Markdown \
        links to the full https URL. Keep answers concise unless asked for detail.
        """

    static func arguments(provider: Provider, model: String, permissions: String, sessionID: String?,
                          directory: URL) -> [String] {
        switch provider {
        case .claude:
            var args = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                        "--model", model, "--append-system-prompt", instructions]
            switch permissions {
            case "read_only":
                args += ["--permission-mode", "default",
                         "--allowedTools", "Read", "Glob", "Grep", "WebSearch", "WebFetch",
                         "--disallowedTools", "Edit", "Write", "NotebookEdit", "Bash"]
            case "full":
                args += ["--dangerously-skip-permissions"]
            default:
                // Edits are accepted; shell commands run in Claude Code's sandbox (no prompts needed).
                args += ["--permission-mode", "acceptEdits", "--allowedTools", "WebSearch", "WebFetch",
                         "--settings", #"{"sandbox":{"enabled":true,"autoAllowBashIfSandboxed":true}}"#]
            }
            if let sessionID { args += ["--resume", sessionID] }
            return args
        case .codex:
            var args = ["exec"]
            if let sessionID { args += ["resume", sessionID] }
            args += ["--json", "--skip-git-repo-check", "-m", model,
                     "-c", "approval_policy=\"never\"",
                     "-c", "web_search=\"live\"",
                     "-c", "developer_instructions=" + toml(instructions)]
            if sessionID == nil { args += ["-C", directory.path] }
            switch permissions {
            case "read_only": args += ["-c", "sandbox_mode=\"read-only\""]
            case "full": args += ["--dangerously-bypass-approvals-and-sandbox"]
            default: args += ["-c", "sandbox_mode=\"workspace-write\""]
            }
            return args + ["-"]  // The prompt is written to stdin.
        }
    }

    private static func toml(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04X", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }
}

/// Turns each CLI's JSON lines into the chat UI's events:
/// text_delta, text, tool, tool_done, status, notice, error.
struct AgentEventParser {
    let provider: Provider
    let directory: URL
    private(set) var sessionID: String?
    private(set) var finished = false
    private(set) var failed = false
    private var sawDelta = false

    init(provider: Provider, directory: URL, sessionID: String?) {
        self.provider = provider
        self.directory = directory
        self.sessionID = sessionID
    }

    mutating func parse(_ line: String) -> [[String: Any]] {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return provider == .claude ? parseClaude(obj) : parseCodex(obj)
    }

    // MARK: Claude Code (stream-json)

    private mutating func parseClaude(_ obj: [String: Any]) -> [[String: Any]] {
        let type = obj["type"] as? String
        let isSubagent = !(obj["parent_tool_use_id"] is NSNull || obj["parent_tool_use_id"] == nil)
        switch type {
        case "system":
            if obj["subtype"] as? String == "init", let id = obj["session_id"] as? String { sessionID = id }
            return []
        case "stream_event":
            guard !isSubagent, let event = obj["event"] as? [String: Any] else { return [] }
            switch event["type"] as? String {
            case "content_block_start":
                let block = event["content_block"] as? [String: Any]
                switch block?["type"] as? String {
                case "text": return [["type": "text_break"]]
                case "thinking": return [["type": "status", "text": "Thinking…"]]
                default: return []
                }
            case "content_block_delta":
                guard let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                      let text = delta["text"] as? String else { return [] }
                sawDelta = true
                return [["type": "text_delta", "text": text]]
            default: return []
            }
        case "assistant":
            guard !isSubagent, let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return [] }
            var events: [[String: Any]] = []
            for block in content {
                switch block["type"] as? String {
                case "text" where !sawDelta:
                    if let text = block["text"] as? String { events.append(["type": "text", "text": text]) }
                case "tool_use":
                    let name = block["name"] as? String ?? "Tool"
                    let input = block["input"] as? [String: Any] ?? [:]
                    var event: [String: Any] = ["type": "tool", "id": block["id"] as? String ?? UUID().uuidString,
                                                "name": name, "detail": Self.describe(name, input)]
                    if let path = Self.filePath(name, input) { event["path"] = path }
                    events.append(event)
                default: break
                }
            }
            sawDelta = false
            return events
        case "user":
            guard let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return [] }
            return content.compactMap { block in
                guard block["type"] as? String == "tool_result", let id = block["tool_use_id"] as? String else { return nil }
                return ["type": "tool_done", "id": id, "ok": !(block["is_error"] as? Bool ?? false),
                        "output": Self.truncate(Self.text(of: block["content"]))]
            }
        case "result":
            if let id = obj["session_id"] as? String { sessionID = id }
            finished = true
            var done: [String: Any] = ["type": "done"]
            if let cost = obj["total_cost_usd"] as? Double { done["cost"] = cost }
            if let ms = obj["duration_ms"] as? Double { done["seconds"] = ms / 1000 }
            if obj["is_error"] as? Bool == true || (obj["subtype"] as? String).map({ $0 != "success" }) == true {
                failed = true
                let message = (obj["result"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (obj["errors"] as? [String])?.joined(separator: "\n")
                    ?? "Claude Code stopped: \(obj["subtype"] as? String ?? "error")"
                return [["type": "error", "message": message], done]
            }
            return [done]
        default:
            return []
        }
    }

    // MARK: Codex (exec --json)

    private mutating func parseCodex(_ obj: [String: Any]) -> [[String: Any]] {
        switch obj["type"] as? String {
        case "thread.started":
            if let id = obj["thread_id"] as? String { sessionID = id }
            return [["type": "status", "text": "Working…"]]
        case "item.started", "item.updated", "item.completed":
            guard let item = obj["item"] as? [String: Any] else { return [] }
            return codexItem(item, completed: obj["type"] as? String == "item.completed")
        case "turn.completed":
            finished = true
            return [["type": "done"]]
        case "turn.failed":
            finished = true
            failed = true
            let message = (obj["error"] as? [String: Any])?["message"] as? String ?? "Codex turn failed."
            return [["type": "error", "message": message], ["type": "done"]]
        case "error":
            return [["type": "notice", "text": obj["message"] as? String ?? "Codex error"]]
        default:
            return []
        }
    }

    private func codexItem(_ item: [String: Any], completed: Bool) -> [[String: Any]] {
        let id = item["id"] as? String ?? UUID().uuidString
        switch item["type"] as? String {
        case "agent_message":
            guard completed, let text = item["text"] as? String else { return [] }
            return [["type": "text_break"], ["type": "text", "text": text]]
        case "reasoning":
            return completed ? [] : [["type": "status", "text": "Thinking…"]]
        case "command_execution":
            var events: [[String: Any]] = [["type": "tool", "id": id, "name": "Shell",
                                            "detail": Self.shellCommand(item["command"])]]
            if completed {
                events.append(["type": "tool_done", "id": id, "ok": (item["exit_code"] as? Int ?? 0) == 0,
                               "output": Self.truncate(item["aggregated_output"] as? String ?? "")])
            }
            return events
        case "web_search":
            let query = (item["query"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? ((item["action"] as? [String: Any])?["query"] as? String) ?? "…"
            var events: [[String: Any]] = [["type": "tool", "id": id, "name": "Web search", "detail": query]]
            if completed { events.append(["type": "tool_done", "id": id, "ok": true, "output": ""]) }
            return events
        case "file_change":
            let changes = item["changes"] as? [[String: Any]] ?? []
            let paths = changes.compactMap { $0["path"] as? String }
            var event: [String: Any] = ["type": "tool", "id": id, "name": "Edit",
                                        "detail": paths.map(relative).joined(separator: ", ")]
            if let first = paths.first { event["path"] = first }
            var events = [event]
            if completed { events.append(["type": "tool_done", "id": id, "ok": (item["status"] as? String) != "failed", "output": ""]) }
            return events
        case "mcp_tool_call":
            let name = [item["server"] as? String, item["tool"] as? String].compactMap { $0 }.joined(separator: ".")
            var events: [[String: Any]] = [["type": "tool", "id": id, "name": name.isEmpty ? "Tool" : name, "detail": ""]]
            if completed { events.append(["type": "tool_done", "id": id, "ok": (item["status"] as? String) != "failed", "output": ""]) }
            return events
        case "error":
            return [["type": "notice", "text": item["message"] as? String ?? "Error"]]
        default:
            return []
        }
    }

    // MARK: Helpers

    private func relative(_ path: String) -> String {
        let base = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }

    private static func shellCommand(_ value: Any?) -> String {
        if let parts = value as? [String] {
            // Codex reports ["/bin/zsh", "-lc", "<script>"]; show just the script.
            if parts.count == 3, parts[1].hasPrefix("-") { return parts[2] }
            return parts.joined(separator: " ")
        }
        // …or as one string: /bin/zsh -lc "<script>".
        let command = value as? String ?? ""
        if let match = command.range(of: #"^\S*/(?:zsh|bash|sh) -l?c (["'])([\s\S]*)\1$"#, options: .regularExpression) {
            var script = String(command[match])
            script = script.replacingOccurrences(of: #"^\S* -l?c ["']"#, with: "", options: .regularExpression)
            return String(script.dropLast()).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\'", with: "'")
        }
        return command
    }

    static func describe(_ name: String, _ input: [String: Any]) -> String {
        func s(_ key: String) -> String? { input[key] as? String }
        switch name {
        case "Bash": return s("command") ?? ""
        case "Read", "Write", "Edit", "MultiEdit", "NotebookEdit": return s("file_path") ?? s("notebook_path") ?? ""
        case "Glob", "Grep": return [s("pattern"), s("path")].compactMap { $0 }.joined(separator: " in ")
        case "WebSearch": return s("query") ?? ""
        case "WebFetch": return s("url") ?? ""
        case "Task", "Agent": return s("description") ?? ""
        case "TodoWrite": return "Updated the plan"
        default: return input.values.compactMap { $0 as? String }.first ?? ""
        }
    }

    static func filePath(_ name: String, _ input: [String: Any]) -> String? {
        ["Read", "Write", "Edit", "MultiEdit", "NotebookEdit"].contains(name)
            ? (input["file_path"] as? String ?? input["notebook_path"] as? String) : nil
    }

    static func text(of content: Any?) -> String {
        if let s = content as? String { return s }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }

    static func truncate(_ s: String, limit: Int = 6000) -> String {
        s.count <= limit ? s : String(s.prefix(limit)) + "\n… (\(s.count - limit) more characters)"
    }
}
