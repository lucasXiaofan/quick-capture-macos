import Foundation

/// One agent skill: a folder with a SKILL.md (Claude Code, Codex and other agents use the same layout).
struct Skill: Sendable {
    let dir: URL
    let name: String
    let description: String
    /// Sidebar heading: the folder it was found in, or "Built-in (Claude)" / "Built-in (Codex)".
    let group: String
    let builtin: Bool
    /// Paths relative to `dir`, hidden files skipped.
    let files: [String]
    let modified: Date

    var json: [String: Any] {
        [
            "dir": dir.path, "displayDir": SkillStore.tilde(dir.path), "name": name, "description": description,
            "group": group, "builtin": builtin, "files": files,
            "modified": modified.timeIntervalSince1970 * 1000,
        ]
    }
}

/// Finds skills under a set of folders. Pure file-system code, safe to run off the main thread.
enum SkillStore {
    static let defaultFolders = ["~/.claude/skills", "~/.codex/skills", "~/.agents/skills"]
    private static let maxDepth = 3
    private static let maxFiles = 400

    static func expand(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
    }

    static func tilde(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// Every skill under `folders`. A folder reached twice (symlinks, overlapping roots) is listed once.
    static func scan(_ folders: [String]) -> [Skill] {
        var seen = Set<String>()
        var skills: [Skill] = []
        for folder in folders {
            let root = expand(folder)
            collect(in: root, depth: 0, rootLabel: tilde(root.path), builtinLabel: nil, seen: &seen, into: &skills)
        }
        return skills
    }

    private static func collect(in dir: URL, depth: Int, rootLabel: String, builtinLabel: String?,
                                seen: inout Set<String>, into skills: inout [Skill]) {
        let fm = FileManager.default
        let real = dir.resolvingSymlinksInPath().path
        guard !seen.contains(real) else { return }
        if fm.fileExists(atPath: dir.appendingPathComponent("SKILL.md").path) {
            seen.insert(real)
            if let skill = load(dir, group: builtinLabel ?? rootLabel, builtin: builtinLabel != nil) { skills.append(skill) }
            return
        }
        guard depth < maxDepth,
              let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        seen.insert(real)
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = child.lastPathComponent
            // Claude's synced built-ins live in skills/synced/<id>/, Codex's in skills/.system/.
            var label = builtinLabel
            if name == "synced" { label = "Built-in (Claude)" }
            else if name == ".system" { label = "Built-in (Codex)" }
            else if name.hasPrefix(".") || name == "node_modules" { continue }
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            collect(in: child, depth: depth + 1, rootLabel: rootLabel, builtinLabel: label, seen: &seen, into: &skills)
        }
    }

    private static func load(_ dir: URL, group: String, builtin: Bool) -> Skill? {
        guard let text = try? String(contentsOf: dir.appendingPathComponent("SKILL.md"), encoding: .utf8) else { return nil }
        let meta = frontMatter(text)
        var files: [String] = []
        var newest = Date.distantPast
        let base = dir.resolvingSymlinksInPath().path
        if let walker = FileManager.default.enumerator(at: dir.resolvingSymlinksInPath(),
                                                       includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                                                       options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let url as URL in walker {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
                guard values?.isRegularFile == true else { continue }
                let path = url.resolvingSymlinksInPath().path
                guard path.hasPrefix(base + "/") else { continue }
                files.append(String(path.dropFirst(base.count + 1)))
                if let date = values?.contentModificationDate, date > newest { newest = date }
                if files.count >= maxFiles { break }
            }
        }
        return Skill(dir: dir, name: meta["name"].flatMap { $0.isEmpty ? nil : $0 } ?? dir.lastPathComponent,
                     description: meta["description"] ?? "", group: group, builtin: builtin,
                     files: files, modified: newest == .distantPast ? Date() : newest)
    }

    /// `name` and `description` from "---\nkey: value\n---". Handles quotes and > / | multi-line values.
    static func frontMatter(_ text: String) -> [String: String] {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var meta: [String: String] = [:]
        var i = 1
        while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces) != "---" {
            let line = lines[i]
            if let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if ["", ">", "|", ">-", "|-"].contains(value) {
                    var parts: [String] = []
                    while i + 1 < lines.count, let first = lines[i + 1].first, first == " " || first == "\t" {
                        i += 1
                        parts.append(lines[i].trimmingCharacters(in: .whitespaces))
                    }
                    value = parts.joined(separator: " ")
                }
                if value.count >= 2, let q = value.first, q == "\"" || q == "'", value.last == q {
                    value = String(value.dropFirst().dropLast())
                }
                meta[key] = value
            }
            i += 1
        }
        return meta
    }

    /// The SKILL.md a new skill starts with: the parts an agent needs, as headings to fill in.
    static func template(name: String, description: String) -> String {
        let desc = description.isEmpty ? "What this skill does, and the requests that should trigger it." : description
        let quoted = desc.contains(":") || desc.contains("#") ? "\"\(desc.replacingOccurrences(of: "\"", with: "'"))\"" : desc
        let title = name.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        return """
        ---
        name: \(name)
        description: \(quoted)
        ---

        # \(title)

        One paragraph: what problem this solves and what "done" looks like.

        ## When to use

        -

        ## Steps

        1.

        ## Rules

        -

        ## Files

        - `references/…` — longer material the steps point to (create the folder when needed)

        """
    }
}
