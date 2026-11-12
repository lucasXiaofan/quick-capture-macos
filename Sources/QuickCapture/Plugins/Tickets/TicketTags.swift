import Foundation

/// The tag vocabulary on disk, in the layout of the `tags` skill it is built on:
///
///     <root>/tags/SKILL.md                         the rules (read by people and agents; edit freely)
///     <root>/tags/references/index.md              depth 1-2 tags only (purpose, field), at most 30
///     <root>/tags/references/<l1>/<l2>.md          depth 3+ tags; past 15, depth 4+ moves to <l1>/<l2>/<l3>.md
///     <root>/tags/references/map.md                how to classify (optional; sent to the agent when present)
///
/// One flat line per tag, full path: ``- `career/build`: what it means. Action: what is done because of it.``
/// Everything else in a file (headings, prose) is kept as it is.
enum TicketTagFiles {
    static let indexMax = 30
    static let fileMax = 15

    /// "Career / Build " → "career/build". Each level is a slug; empty levels are dropped.
    static func path(_ raw: String) -> String {
        raw.split(separator: "/").map { TicketStructure.slug(String($0)) }.filter { !$0.isEmpty }.joined(separator: "/")
    }

    static func depth(_ id: String) -> Int { id.split(separator: "/").count }
    static func parent(_ id: String) -> String? { id.contains("/") ? String(id[..<id.lastIndex(of: "/")!]) : nil }
    static func isUnder(_ id: String, _ ancestor: String) -> Bool { id == ancestor || id.hasPrefix(ancestor + "/") }

    private static let line = try! NSRegularExpression(pattern: "^- `([^`]+)`\\s*:\\s*(.*)$")

    private static func parse(_ text: Substring) -> TicketStructure.Tag? {
        let s = String(text), range = NSRange(location: 0, length: (s as NSString).length)
        guard let match = line.firstMatch(in: s, range: range) else { return nil }
        let id = path((s as NSString).substring(with: match.range(at: 1)))
        guard !id.isEmpty else { return nil }
        let definition = (s as NSString).substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
        // "… meaning. Action: what to do." — the action is whatever follows the last "Action:".
        if let cut = definition.range(of: "Action:", options: .backwards) {
            return TicketStructure.Tag(id: id, meaning: definition[..<cut.lowerBound].trimmingCharacters(in: .whitespaces),
                                       action: definition[cut.upperBound...].trimmingCharacters(in: .whitespaces))
        }
        return TicketStructure.Tag(id: id, meaning: definition)
    }

    static func text(_ tag: TicketStructure.Tag) -> String {
        let flat = { (s: String) in s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) }
        let meaning = flat(tag.meaning), action = flat(tag.action)
        return "- `\(tag.id)`: " + [meaning, action.isEmpty ? "" : "Action: " + action].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func markdownFiles(_ dir: URL) -> [URL] {
        let all = (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "md" }.sorted { $0.path < $1.path }
        // The index first: its order is the order of purposes.
        return all.filter { $0.lastPathComponent == "index.md" && $0.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL }
            + all.filter { !($0.lastPathComponent == "index.md" && $0.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL) }
    }

    /// Every tag defined under `dir`, the index first; a tag defined twice counts once.
    static func read(_ dir: URL) -> [TicketStructure.Tag] {
        var out: [TicketStructure.Tag] = []
        for file in markdownFiles(dir) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for row in text.split(separator: "\n", omittingEmptySubsequences: false) {
                guard let tag = parse(row), !out.contains(where: { $0.id == tag.id }) else { continue }
                out.append(tag)
            }
        }
        return out
    }

    /// The file (relative to references/) each tag belongs in.
    static func placement(_ tags: [TicketStructure.Tag]) -> [String: String] {
        var crowded: [String: Int] = [:]
        for tag in tags where depth(tag.id) >= 3 {
            crowded[tag.id.split(separator: "/").prefix(2).joined(separator: "/"), default: 0] += 1
        }
        var out: [String: String] = [:]
        for tag in tags {
            let parts = tag.id.split(separator: "/").map(String.init)
            if parts.count <= 2 { out[tag.id] = "index.md"; continue }
            let field = parts.prefix(2).joined(separator: "/")
            // A full field file keeps its topics; what hangs below a topic moves into the topic's own file.
            out[tag.id] = (crowded[field] ?? 0) > fileMax && parts.count >= 4 ? parts.prefix(3).joined(separator: "/") + ".md" : field + ".md"
        }
        return out
    }

    /// Writes the vocabulary back, touching only files whose tag lines changed and keeping their other lines.
    static func write(_ tags: [TicketStructure.Tag], to dir: URL) {
        let fm = FileManager.default
        let place = placement(tags)
        var wanted: [String: [TicketStructure.Tag]] = ["index.md": []]
        for tag in tags { wanted[place[tag.id] ?? "index.md", default: []].append(tag) }
        var files = Set(wanted.keys)
        for file in markdownFiles(dir) { files.insert(String(file.standardizedFileURL.path.dropFirst(dir.standardizedFileURL.path.count + 1))) }
        for name in files.sorted() {
            let file = dir.appendingPathComponent(name)
            let old = try? String(contentsOf: file, encoding: .utf8)
            let rows = (old ?? header(name)).split(separator: "\n", omittingEmptySubsequences: false)
            guard old == nil || rows.contains(where: { parse($0) != nil }) || wanted[name] != nil else { continue }
            let firstTag = rows.firstIndex { parse($0) != nil } ?? rows.count
            var before = rows[..<firstTag].map(String.init)
            var after = rows[firstTag...].filter { parse($0) == nil }.map(String.init)
            while before.last?.isEmpty == true { before.removeLast() }
            while after.first?.isEmpty == true { after.removeFirst() }
            while after.last?.isEmpty == true { after.removeLast() }
            let lines = (wanted[name] ?? []).map(text)
            let next = (before + [""] + lines + (after.isEmpty ? [] : [""] + after)).joined(separator: "\n") + "\n"
            guard next != old else { continue }
            try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? next.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    private static func header(_ name: String) -> String {
        name == "index.md" ? defaultIndex : "# \(name.dropLast(3)) topics (depth 3+)\n"
    }

    /// Structure problems, in the words of the skill's checker. Empty means the vocabulary is sound.
    static func problems(_ tags: [TicketStructure.Tag]) -> [String] {
        var out: [String] = []
        let ids = Set(tags.map(\.id))
        for tag in tags {
            if let parent = parent(tag.id), !ids.contains(parent) { out.append("`\(tag.id)` has no parent `\(parent)`") }
            if tag.meaning.isEmpty { out.append("`\(tag.id)` has no definition") }
        }
        let top = tags.filter { depth($0.id) <= 2 }.count
        if top > indexMax { out.append("index.md has \(top) tags (max \(indexMax)): move detail deeper") }
        return out
    }

    static let defaultIndex = """
        # Tag index (depth 1-2 only, max \(indexMax) tags)

        Depth 3+ tags live in `references/<l1>/<l2>.md`. Flat lines, full path: ``- `tag`: definition. Action: what is done because of it.``

        """

    /// Written to tags/SKILL.md when the folder is new. It is the user's from then on.
    static let defaultSkill = """
        ---
        name: tags
        description: The common-language tag vocabulary for tickets, projects and designs: layered index files, one-line definitions that end in an action, checked structure. Use when adding, finding, renaming, merging or splitting a tag.
        ---

        # tags

        The common language of the ticket system: every ticket is tagged from this vocabulary. It only grows, so its structure keeps the top small.

        1. **Layered files, top stays small.** `references/index.md` holds only depth 1-2 tags (purpose or domain, field), at most \(indexMax), and is the only file the agent is shown in full. Depth 3+ lives in `references/<l1>/<l2>.md`; when a file passes \(fileMax) tags, what hangs below a topic moves into `references/<l1>/<l2>/<l3>.md`. Detail goes deeper, never into the index.
        2. **One line per tag, flat.** ``- `parent/child`: one-line definition. Action: what is done because of it.`` with the full path and no indentation. Each depth has its own job: depth 1 = a purpose or area, depth 2 = a field, depth 3+ = one concept. A project, course or paper name is not a tag (it is a project). Reuse a tag before inventing one; add a new tag, with its definition, in the same step that first uses it.
        3. **Checked, not trusted.** The app refuses a tag with no parent, a duplicate, a tag with no meaning or action from the agent, and an index over its limit. The Tags page shows the tree and what still needs a meaning.
        4. **Purpose first.** Top-level tags should answer why, not what. If you keep a classification guide, save it as `references/map.md`: the agent is given it with every ticket.

        The app reads these files when it starts and rewrites the tag lines when a tag is defined, merged or deleted in the Tags page or by the agent; other lines are kept.
        """
}

extension TicketStructure {
    static func tagPath(_ raw: String) -> String { TicketTagFiles.path(raw) }
}
