import Foundation

/// Tickets on disk, as plain files anyone (or any agent) can read:
///
///     <root>/tickets/0012.md            one Markdown file per ticket (see `TicketMarkdown`); a merge never rewrites its sources
///     <root>/attachments/12/<file>      screenshots and files sent with ticket 12
///     <root>/structure.json             kinds (with their agent rules) and projects
///     <root>/tags/                      the tag vocabulary: SKILL.md (rules) and references/*.md (see `TicketTagFiles`)
///     <root>/agent/instructions.md      the agent's standing instructions
///     <root>/agent/decisions.jsonl      what the agent changed and why
///     <root>/agent/corrections.jsonl    what the user said it got wrong (part of every prompt)
///     <root>/designs/<id>.canvas        designs (JSON Canvas, opens in Obsidian); index.json holds title and project
///     <root>/designs/assets/            images used on designs
///     <root>/workspace/                 the agent's default working folder
///     <root>/trash/                     deleted tickets
@MainActor
final class TicketStore {
    private(set) var root: URL
    private(set) var tickets: [Int: Ticket] = [:]
    private(set) var structure = TicketStructure()
    private(set) var instructions = TicketStore.defaultInstructions
    private(set) var decisions: [TicketDecision] = []
    private(set) var corrections: [TicketCorrection] = []
    private(set) var designs: [TicketDesign] = []
    /// Called when the agent draws or redraws a design, so a window showing it can reload it.
    var onDesignRedrawn: ((String) -> Void)?
    /// Called after anything changes, so open windows can redraw.
    var onChange: (() -> Void)?

    private let fm = FileManager.default
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()
    private let lineEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    static let defaultInstructions = """
        You are my ticket agent. A ticket is a quick capture: a todo, a question, an idea, a habit check-in, a bug.
        On every turn:
        1. Classify it: one kind, a project when it clearly belongs to one (reuse existing ids; create one only \
        when I name something new), a short title, tags.
        2. Follow that kind's rule. Do the useful first step yourself (search, read, run code) instead of describing it.
        3. Reply briefly, in the language I wrote in. Ask at most one question, and only when you can't go on without it.
        4. Set the status: waiting_human when you need me, closed when nothing is left to do.
        5. Keep things organized for me with your tools: split captures that hold several things into tickets, keep plans \
        and project context current, merge duplicates. I capture; you organize.
        6. Never spend money, send messages as me, or delete my files. Prepare it and ask.
        7. Principles and corrections below override everything above.
        """

    init(root: URL) {
        self.root = root
        load()
    }

    var ticketsDir: URL { root.appendingPathComponent("tickets", isDirectory: true) }
    var attachmentsDir: URL { root.appendingPathComponent("attachments", isDirectory: true) }
    var stagingDir: URL { root.appendingPathComponent("staging", isDirectory: true) }
    var agentDir: URL { root.appendingPathComponent("agent", isDirectory: true) }
    var workspaceDir: URL { root.appendingPathComponent("workspace", isDirectory: true) }
    var tagsDir: URL { root.appendingPathComponent("tags", isDirectory: true) }
    var tagFilesDir: URL { tagsDir.appendingPathComponent("references", isDirectory: true) }
    var designsDir: URL { root.appendingPathComponent("designs", isDirectory: true) }
    private var designIndexFile: URL { designsDir.appendingPathComponent("index.json") }
    private var trashDir: URL { root.appendingPathComponent("trash", isDirectory: true) }
    private var structureFile: URL { root.appendingPathComponent("structure.json") }
    private var instructionsFile: URL { agentDir.appendingPathComponent("instructions.md") }
    private var decisionsFile: URL { agentDir.appendingPathComponent("decisions.jsonl") }
    private var correctionsFile: URL { agentDir.appendingPathComponent("corrections.jsonl") }

    func attachmentDir(_ id: Int) -> URL { attachmentsDir.appendingPathComponent(String(id), isDirectory: true) }
    func ticketFile(_ id: Int) -> URL { ticketsDir.appendingPathComponent(String(format: "%04d.md", id)) }

    // MARK: Loading

    func setRoot(_ url: URL) {
        guard url.standardizedFileURL != root.standardizedFileURL else { return }
        root = url
        load()
        onChange?()
    }

    func load() {
        for dir in [ticketsDir, attachmentsDir, stagingDir, agentDir, workspaceDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        tickets = [:]
        let decoder = JSONDecoder()
        for file in (try? fm.contentsOfDirectory(at: ticketsDir, includingPropertiesForKeys: nil)) ?? []
        where file.pathExtension == "md" {
            guard let text = try? String(contentsOf: file, encoding: .utf8), let ticket = TicketMarkdown.decode(text) else { continue }
            tickets[ticket.id] = ticket
        }
        if let data = try? Data(contentsOf: structureFile), let s = try? decoder.decode(TicketStructure.self, from: data) {
            structure = s
        } else {
            structure = TicketStructure()
            saveStructure()
        }
        loadTags()
        if let text = try? String(contentsOf: instructionsFile, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            instructions = text
        } else {
            instructions = Self.defaultInstructions
            try? instructions.write(to: instructionsFile, atomically: true, encoding: .utf8)
        }
        decisions = readLines(decisionsFile, TicketDecision.self)
        corrections = readLines(correctionsFile, TicketCorrection.self)
        loadDesigns()
        importWorkspaceProjects()
        // Staged files only matter while a compose window is open.
        for file in (try? fm.contentsOfDirectory(at: stagingDir, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: file)
        }
    }

    /// Runs inside the app after restart, where the store owns writes to its live registry and tickets.
    /// The marker prevents duplicate plans and preserves later edits (including clearing context).
    private func importWorkspaceProjects() {
        var changed = false
        for index in structure.projects.indices where !structure.projects[index].workspaceImported {
            let project = structure.projects[index]
            guard project.id == TicketStructure.slug(project.id), !project.id.isEmpty else { continue }
            let folder = workspaceDir.appendingPathComponent(project.id, isDirectory: true)
            guard let context = try? String(contentsOf: folder.appendingPathComponent("CONTEXT.md"), encoding: .utf8),
                  let plan = try? String(contentsOf: folder.appendingPathComponent("PLAN.md"), encoding: .utf8) else { continue }
            let stages = TicketWorkspaceImport.stages(plan)
            guard !stages.isEmpty else { continue }
            let sources = TicketWorkspaceImport.sourceTickets(context).filter { tickets[$0] != nil }
            if project.context.isEmpty { structure.projects[index].context = context }
            structure.projects[index].contextTicketIDs = Array(Set(project.contextTicketIDs + sources)).sorted()
            for id in sources {
                guard var ticket = tickets[id] else { continue }
                if ticket.project != project.id && !ticket.relatedProjects.contains(project.id) {
                    ticket.relatedProjects.append(project.id)
                    save(ticket)
                }
            }
            for (number, stage) in stages.enumerated() {
                let tag = "workspace-plan-\(project.id)-\(number + 1)"
                guard !tickets.values.contains(where: { $0.tags.contains(tag) }) else { continue }
                var ticket = Ticket(id: (tickets.keys.max() ?? 0) + 1)
                ticket.title = stage.title
                ticket.summary = "Proposed research milestone; dates depend on inputs, doctor availability, and approved compute."
                ticket.kind = "plan"
                ticket.project = project.id
                ticket.status = .waitingHuman
                ticket.start = stage.start
                ticket.due = stage.due
                ticket.tags = ["planning", "medical-research", tag]
                ticket.created = TicketDates.now()
                ticket.updated = ticket.created
                let links = sources.map { "#\($0)" }.joined(separator: ", ")
                ticket.messages = [TicketMessage(role: "agent", text: "Imported from workspace/\(project.id)/PLAN.md. Source context: \(links). Dates are proposed targets. All checklist tasks remain pending.\n\n" + stage.text, at: ticket.created)]
                ticket.history = [TicketEvent(at: ticket.created, by: "agent", text: "Imported existing project plan into a dated plan ticket")]
                save(ticket)
            }
            structure.projects[index].workspaceImported = true
            changed = true
        }
        if changed { saveStructure() }
    }

    private func readLines<T: Decodable>(_ file: URL, _ type: T.Type) -> [T] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap { try? decoder.decode(T.self, from: Data($0.utf8)) }
    }

    private func writeLines<T: Encodable>(_ items: [T], to file: URL) {
        let text = items.compactMap { (try? lineEncoder.encode($0)).map { String(decoding: $0, as: UTF8.self) } }
            .joined(separator: "\n")
        try? (text.isEmpty ? "" : text + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    // MARK: Tickets

    /// Newest activity first.
    var sorted: [Ticket] { tickets.values.sorted { $0.updated > $1.updated } }

    private func save(_ ticket: Ticket) {
        tickets[ticket.id] = ticket
        try? TicketMarkdown.encode(ticket, attachmentsPath: "../attachments/\(ticket.id)")
            .write(to: ticketFile(ticket.id), atomically: true, encoding: .utf8)
    }

    @discardableResult
    func create(text: String, staged: [String]) -> Ticket {
        var ticket = Ticket(id: (tickets.keys.max() ?? 0) + 1)
        let now = TicketDates.now()
        ticket.created = now
        ticket.updated = now
        ticket.title = Self.provisionalTitle(text)
        let hints = Self.hashtags(in: text)
        for tag in hints {
            if tag != "misc", structure.kinds.contains(where: { $0.id == tag }) { ticket.kind = tag }
            else if structure.projects.contains(where: { $0.id == tag }) { ticket.project = tag }
            else if !TicketStructure.tagPath(tag).isEmpty, !ticket.tags.contains(TicketStructure.tagPath(tag)) { ticket.tags.append(TicketStructure.tagPath(tag)) }
        }
        ticket.messages = [TicketMessage(role: "human", text: text, at: now, attachments: adopt(staged, into: ticket.id))]
        save(ticket)
        onChange?()
        return ticket
    }

    /// A human message on an existing ticket. It becomes the agent's turn.
    func reply(_ id: Int, text: String, staged: [String]) {
        guard var ticket = tickets[id] else { return }
        let now = TicketDates.now()
        ticket.messages.append(TicketMessage(role: "human", text: text, at: now, attachments: adopt(staged, into: id)))
        ticket.status = .needsAgent
        ticket.updated = now
        save(ticket)
        onChange?()
    }

    /// Moves a fresh capture's messages and files into an existing ticket; the capture is kept, marked as merged into it.
    @discardableResult
    func append(_ source: Int, into target: Int) -> Bool {
        guard source != target, let capture = tickets[source], capture.mergedInto == nil,
              var ticket = tickets[target], ticket.mergedInto == nil else { return false }
        let now = TicketDates.now()
        copyAttachments(from: [capture], to: target)
        ticket.messages += capture.messages.filter { $0.role == "human" }
        ticket.tags += capture.tags.filter { !ticket.tags.contains($0) }
        ticket.history.append(TicketEvent(at: now, by: "agent", text: "Appended #\(source)"))
        ticket.updated = now
        save(ticket)
        var done = capture
        done.status = .closed
        markMerged(done, into: target, by: "agent", at: now)
        onChange?()
        return true
    }

    /// Changes a ticket. `touch` false keeps its place in the list (for edits that aren't activity).
    func update(_ id: Int, touch: Bool = true, _ change: (inout Ticket) -> Void) {
        guard var ticket = tickets[id] else { return }
        change(&ticket)
        if touch { ticket.updated = TicketDates.now() }
        save(ticket)
        onChange?()
    }

    func delete(_ id: Int) {
        guard let ticket = tickets[id] else { return }
        try? fm.createDirectory(at: trashDir, withIntermediateDirectories: true)
        let name = ticketFile(id).lastPathComponent
        let target = trashDir.appendingPathComponent("\(Int(Date().timeIntervalSince1970))-\(name)")
        try? fm.moveItem(at: ticketFile(id), to: target)
        tickets[id] = nil
        // Give its sources back, so deleting a merged ticket loses nothing.
        for source in ticket.mergedFrom { releaseSource(source, from: id) }
        onChange?()
    }

    /// Combines tickets into a new one for working on. The originals are kept as they are and only marked as merged.
    @discardableResult
    func merge(_ ids: [Int], by: String, title: String? = nil) -> Ticket? {
        let sources = Array(Set(ids)).compactMap { tickets[$0] }.filter { $0.mergedInto == nil }.sorted { $0.id < $1.id }
        guard sources.count >= 2 else { return nil }
        // Merging into an existing merged ticket extends it instead of nesting.
        if let target = sources.first(where: { !$0.mergedFrom.isEmpty }) {
            let additions = sources.filter { $0.id != target.id && $0.mergedFrom.isEmpty }
            guard !additions.isEmpty else { return target }
            let now = TicketDates.now()
            var merged = target
            merged.mergedFrom += additions.map(\.id)
            merged.messages = Self.interleave(merged.messages, additions)
            merged.log += additions.flatMap(\.log)
            merged.takeaways += additions.flatMap(\.takeaways).filter { !merged.takeaways.contains($0) }
            merged.tags += additions.flatMap(\.tags).filter { !merged.tags.contains($0) }
            merged.relatedProjects = Array(Set(merged.relatedProjects + additions.flatMap { [$0.project] + $0.relatedProjects })).filter { !$0.isEmpty && $0 != merged.project }.sorted()
            merged.history.append(TicketEvent(at: now, by: by, text: "Merged in " + additions.map { "#\($0.id)" }.joined(separator: ", ")))
            merged.updated = now
            copyAttachments(from: additions, to: merged.id)
            save(merged)
            for source in additions { markMerged(source, into: merged.id, by: by, at: now) }
            onChange?()
            return merged
        }
        let now = TicketDates.now()
        var merged = Ticket(id: (tickets.keys.max() ?? 0) + 1)
        let lead = sources.max { $0.messages.count < $1.messages.count } ?? sources[0]
        merged.title = title ?? lead.title
        merged.summary = lead.summary
        merged.kind = lead.kind
        merged.project = sources.first { !$0.project.isEmpty }?.project ?? ""
        merged.relatedProjects = Array(Set(sources.flatMap { [$0.project] + $0.relatedProjects })).filter { !$0.isEmpty && $0 != merged.project }.sorted()
        merged.tags = sources.flatMap(\.tags).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        merged.created = now
        merged.updated = now
        merged.start = sources.compactMap(\.start).min()
        merged.due = sources.compactMap(\.due).max()
        // The merge itself needs no new reply from the agent.
        merged.status = sources.contains(where: \.isOpen) ? .waitingHuman : .closed
        merged.messages = Self.interleave([], sources)
        merged.log = sources.flatMap(\.log)
        merged.takeaways = sources.flatMap(\.takeaways).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        merged.mergedFrom = sources.map(\.id)
        merged.history = [TicketEvent(at: now, by: by, text: "Merged from " + sources.map { "#\($0.id) “\($0.title)”" }.joined(separator: ", "))]
        copyAttachments(from: sources, to: merged.id)
        save(merged)
        for source in sources { markMerged(source, into: merged.id, by: by, at: now) }
        onChange?()
        return merged
    }

    /// Undoes a merge: the originals come back as they were and the merged ticket is deleted.
    func unmerge(_ id: Int) {
        guard let ticket = tickets[id], !ticket.mergedFrom.isEmpty else { return }
        delete(id)
    }

    private func markMerged(_ source: Ticket, into id: Int, by: String, at now: String) {
        var source = source
        source.mergedInto = id
        source.history.append(TicketEvent(at: now, by: by, text: "Merged into #\(id)"))
        save(source)
    }

    private func releaseSource(_ id: Int, from merged: Int) {
        guard var source = tickets[id], source.mergedInto == merged else { return }
        source.mergedInto = nil
        source.history.append(TicketEvent(at: TicketDates.now(), by: "human", text: "Unmerged from #\(merged)"))
        save(source)
    }

    private static func interleave(_ existing: [TicketMessage], _ sources: [Ticket]) -> [TicketMessage] {
        var all = existing
        for source in sources {
            all += source.messages.map { var m = $0; m.from = m.from ?? source.id; return m }
        }
        return all.sorted { $0.at < $1.at }
    }

    private func copyAttachments(from sources: [Ticket], to id: Int) {
        let target = attachmentDir(id)
        for source in sources {
            for file in (try? fm.contentsOfDirectory(at: attachmentDir(source.id), includingPropertiesForKeys: nil)) ?? [] {
                try? fm.createDirectory(at: target, withIntermediateDirectories: true)
                try? fm.copyItem(at: file, to: target.appendingPathComponent(file.lastPathComponent))
            }
        }
    }

    static func provisionalTitle(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let clean = line.trimmingCharacters(in: .whitespaces)
        if clean.isEmpty { return "Untitled" }
        return clean.count > 70 ? String(clean.prefix(70)) + "…" : clean
    }

    /// "#cs646 practice" → ["cs646"]. A '#' followed by a space (a Markdown heading) is not a tag.
    static func hashtags(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"(?:^|\s)#([\p{L}\p{N}][\p{L}\p{N}_/-]*)"#) else { return [] }
        let ns = text as NSString
        var found: [String] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: match.range(at: 1)).lowercased()
            if !found.contains(tag) { found.append(tag) }
        }
        return found
    }

    // MARK: Attachments

    /// Copies a file into the staging folder (what a compose window has attached but not sent). Returns its name.
    func stage(file: URL) -> String? {
        let name = uniqueName(file.lastPathComponent, in: stagingDir)
        do { try fm.copyItem(at: file, to: stagingDir.appendingPathComponent(name)); return name } catch { return nil }
    }

    func stage(data: Data, name: String) -> String? {
        let safe = name.replacingOccurrences(of: "/", with: "-")
        let unique = uniqueName(safe.isEmpty ? "file" : safe, in: stagingDir)
        do { try data.write(to: stagingDir.appendingPathComponent(unique)); return unique } catch { return nil }
    }

    func unstage(_ name: String) {
        try? fm.removeItem(at: stagingDir.appendingPathComponent((name as NSString).lastPathComponent))
    }

    private func adopt(_ staged: [String], into id: Int) -> [String] {
        guard !staged.isEmpty else { return [] }
        let dir = attachmentDir(id)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var names: [String] = []
        for item in staged {
            let source = stagingDir.appendingPathComponent((item as NSString).lastPathComponent)
            guard fm.fileExists(atPath: source.path) else { continue }
            let name = uniqueName(source.lastPathComponent, in: dir)
            if (try? fm.moveItem(at: source, to: dir.appendingPathComponent(name))) != nil { names.append(name) }
        }
        return names
    }

    private func uniqueName(_ name: String, in dir: URL) -> String {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var candidate = name, n = 2
        while fm.fileExists(atPath: dir.appendingPathComponent(candidate).path) {
            candidate = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
            n += 1
        }
        return candidate
    }

    // MARK: Structure and agent files

    func setStructure(_ next: TicketStructure) {
        structure = next
        saveStructure()
        onChange?()
    }

    private func saveStructure() {
        var plain = structure
        plain.tags = []
        if let data = try? encoder.encode(plain) { try? data.write(to: structureFile, options: .atomic) }
        TicketTagFiles.write(structure.tags, to: tagFilesDir)
    }

    /// The vocabulary comes from the tags folder. Tags an older version kept in structure.json move there once.
    private func loadTags() {
        let fresh = !fm.fileExists(atPath: tagsDir.appendingPathComponent("SKILL.md").path)
        try? fm.createDirectory(at: tagFilesDir, withIntermediateDirectories: true)
        if fresh { try? TicketTagFiles.defaultSkill.write(to: tagsDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8) }
        let old = structure.tags
        var tags = TicketTagFiles.read(tagFilesDir)
        for tag in old where !tags.contains(where: { $0.id == tag.id }) { tags.append(tag) }
        structure.tags = tags
        if !old.isEmpty || !fm.fileExists(atPath: tagFilesDir.appendingPathComponent("index.md").path) { saveStructure() }
    }

    /// The classification guide, when the user keeps one (tags/references/map.md).
    var tagMap: String? {
        (try? String(contentsOf: tagFilesDir.appendingPathComponent("map.md"), encoding: .utf8)).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    /// The id of the project with this name or id, creating it when it is new.
    func project(named name: String, type: String? = nil) -> String {
        let id = TicketStructure.slug(name)
        guard !id.isEmpty else { return "" }
        if structure.projects.contains(where: { $0.id == id }) { return id }
        if let match = structure.projects.first(where: { TicketStructure.slug($0.name) == id }) { return match.id }
        structure.projects.append(TicketStructure.Project(id: id, name: name.trimmingCharacters(in: .whitespaces),
                                                          type: Self.category(type)))
        saveStructure()
        return id
    }

    /// A project's category: one lowercase word or phrase; "personal" when none is given.
    static func category(_ raw: String?) -> String {
        let clean = (raw ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty || clean.count > 30 ? "personal" : clean
    }

    // MARK: Tags

    /// Tags the app sets for its own bookkeeping; never shown in the tag manager or the prompt.
    static func isInternalTag(_ tag: String) -> Bool { tag.hasPrefix("workspace-plan-") }

    /// Every tag on a visible ticket, with how many tickets carry it.
    var tagCounts: [String: Int] {
        var out: [String: Int] = [:]
        for ticket in tickets.values where ticket.mergedInto == nil {
            for tag in ticket.tags where !Self.isInternalTag(tag) { out[tag, default: 0] += 1 }
        }
        return out
    }

    func isDefinedTag(_ id: String) -> Bool { structure.tags.contains { $0.id == id } }

    /// Adds a tag to the vocabulary or changes what it means. Nil keeps the old text. Missing parents are
    /// added with no meaning yet, so the tree never has a gap.
    @discardableResult
    func defineTag(_ raw: String, meaning: String? = nil, action: String? = nil) -> String? {
        let id = TicketStructure.tagPath(raw)
        guard !id.isEmpty, !Self.isInternalTag(id) else { return nil }
        let clean = { (s: String?) in s?.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) }
        var lineage: [String] = []
        var path = id
        while let parent = TicketTagFiles.parent(path) { lineage.insert(parent, at: 0); path = parent }
        for ancestor in lineage + [id] where !isDefinedTag(ancestor) {
            // A new tag goes right after its parent's branch, so a file reads top-down.
            let home = TicketTagFiles.parent(ancestor)
            let at = home.flatMap { h in structure.tags.lastIndex { TicketTagFiles.isUnder($0.id, h) } }.map { $0 + 1 } ?? structure.tags.count
            structure.tags.insert(TicketStructure.Tag(id: ancestor), at: at)
        }
        if let index = structure.tags.firstIndex(where: { $0.id == id }) {
            if let meaning = clean(meaning) { structure.tags[index].meaning = meaning }
            if let action = clean(action) { structure.tags[index].action = action }
        }
        saveStructure()
        onChange?()
        return id
    }

    /// Replaces the `from` tags with `into` on every ticket and drops them from the vocabulary. What hangs
    /// below a merged tag moves with it (`a/x` → `b/x`). Returns how many tickets changed; nil when there is nothing to merge.
    @discardableResult
    func mergeTags(_ from: [String], into raw: String) -> Int? {
        let target = TicketStructure.tagPath(raw)
        let sources = from.map { TicketStructure.tagPath($0) }.filter { !$0.isEmpty && $0 != target && !TicketTagFiles.isUnder(target, $0) }
        guard !target.isEmpty, !sources.isEmpty else { return nil }
        func moved(_ tag: String) -> String? {
            guard let source = sources.first(where: { TicketTagFiles.isUnder(tag, $0) }) else { return nil }
            return target + tag.dropFirst(source.count)
        }
        var changed = 0
        for var ticket in tickets.values where ticket.tags.contains(where: { moved($0) != nil }) {
            ticket.tags = ticket.tags.map { moved($0) ?? $0 }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            save(ticket)
            changed += 1
        }
        // The surviving tag keeps its own meaning, or inherits the first one a merged tag had.
        let inherited = structure.tags.first { sources.contains($0.id) && !$0.meaning.isEmpty }
        let carried = structure.tags.filter { moved($0.id) != nil && !sources.contains($0.id) }
        structure.tags.removeAll { moved($0.id) != nil }
        if !isDefinedTag(target) { structure.tags.append(TicketStructure.Tag(id: target)) }
        if let index = structure.tags.firstIndex(where: { $0.id == target }), structure.tags[index].meaning.isEmpty, let inherited {
            structure.tags[index].meaning = inherited.meaning
            if structure.tags[index].action.isEmpty { structure.tags[index].action = inherited.action }
        }
        for var tag in carried {
            tag.id = moved(tag.id) ?? tag.id
            if !isDefinedTag(tag.id) { structure.tags.append(tag) }
        }
        saveStructure()
        onChange?()
        return changed
    }

    /// Removes a tag, and what hangs below it, from the vocabulary and from every ticket. Returns how many tickets carried it.
    @discardableResult
    func deleteTag(_ raw: String) -> Int {
        let id = TicketStructure.tagPath(raw)
        guard !id.isEmpty else { return 0 }
        var changed = 0
        for var ticket in tickets.values where ticket.tags.contains(where: { TicketTagFiles.isUnder($0, id) }) {
            ticket.tags.removeAll { TicketTagFiles.isUnder($0, id) }
            save(ticket)
            changed += 1
        }
        structure.tags.removeAll { TicketTagFiles.isUnder($0.id, id) }
        saveStructure()
        onChange?()
        return changed
    }

    // MARK: Designs

    private func loadDesigns() {
        try? fm.createDirectory(at: designsDir, withIntermediateDirectories: true)
        var known = (try? Data(contentsOf: designIndexFile)).flatMap { try? JSONDecoder().decode([TicketDesign].self, from: $0) } ?? []
        let files = ((try? fm.contentsOfDirectory(at: designsDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "canvas" }.map { $0.deletingPathExtension().lastPathComponent }
        // The folder is the truth: a canvas dropped in by hand (or by Obsidian) shows up, a removed one goes away.
        known.removeAll { !files.contains($0.id) }
        for id in files.sorted() where !known.contains(where: { $0.id == id }) {
            known.append(TicketDesign(id: id, title: Self.designTitle(id), project: guessProject(id), updated: TicketDates.now()))
        }
        designs = known
    }

    private func saveDesignIndex() {
        try? fm.createDirectory(at: designsDir, withIntermediateDirectories: true)
        if let data = try? encoder.encode(designs) { try? data.write(to: designIndexFile, options: .atomic) }
    }

    func designFile(_ id: String) -> URL { designsDir.appendingPathComponent(Self.designID(id) + ".canvas") }

    /// A file-name-safe id that keeps non-Latin names readable.
    static func designID(_ raw: String) -> String {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: CharacterSet(charactersIn: "/\\:\0")).joined(separator: "-")
            .replacingOccurrences(of: " ", with: "-")
        return String(cleaned.drop { $0 == "." }.prefix(80))
    }

    static func designTitle(_ id: String) -> String {
        var name = id
        if name.lowercased().hasPrefix("design_") { name.removeFirst(7) }
        let words = name.replacingOccurrences(of: "_", with: " · ").replacingOccurrences(of: "-", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// The project whose id or name appears in a design's name; the longest match wins.
    private func guessProject(_ name: String) -> String {
        let hay = TicketStructure.slug(name)
        return structure.projects.filter { hay.contains($0.id) || hay.contains(TicketStructure.slug($0.name)) }
            .max { $0.id.count < $1.id.count }?.id ?? ""
    }

    /// The canvas as JSON text, or nil when the file is missing.
    func designCanvas(_ id: String) -> String? { try? String(contentsOf: designFile(id), encoding: .utf8) }

    /// Writes a canvas (creating the design when it is new) and returns its id.
    @discardableResult
    func saveDesign(id rawID: String?, title: String? = nil, project: String? = nil, summary: String? = nil, canvas: Any? = nil) -> String? {
        var id = Self.designID(rawID ?? "")
        if id.isEmpty { id = Self.designID(title ?? "") }
        guard !id.isEmpty else { return nil }
        try? fm.createDirectory(at: designsDir, withIntermediateDirectories: true)
        let isNew = !designs.contains { $0.id == id }
        if let canvas {
            guard JSONSerialization.isValidJSONObject(canvas),
                  let data = try? JSONSerialization.data(withJSONObject: canvas, options: [.prettyPrinted, .withoutEscapingSlashes]) else { return nil }
            do { try data.write(to: designFile(id), options: .atomic) } catch { return nil }
        } else if isNew {
            try? Data(#"{"nodes":[],"edges":[]}"#.utf8).write(to: designFile(id), options: .atomic)
        }
        let known = Set(structure.projects.map(\.id))
        if isNew { designs.append(TicketDesign(id: id, title: title ?? Self.designTitle(id))) }
        guard let index = designs.firstIndex(where: { $0.id == id }) else { return nil }
        if let title = title?.trimmingCharacters(in: .whitespaces), !title.isEmpty { designs[index].title = title }
        if let project { designs[index].project = known.contains(project) ? project : "" }
        if let summary { designs[index].summary = summary }
        designs[index].updated = TicketDates.now()
        saveDesignIndex()
        onChange?()
        return id
    }

    func deleteDesign(_ id: String) {
        guard designs.contains(where: { $0.id == id }) else { return }
        try? fm.createDirectory(at: trashDir, withIntermediateDirectories: true)
        try? fm.moveItem(at: designFile(id), to: trashDir.appendingPathComponent("\(Int(Date().timeIntervalSince1970))-\(id).canvas"))
        designs.removeAll { $0.id == id }
        saveDesignIndex()
        onChange?()
    }

    /// Copies every .canvas file in a folder (an Obsidian vault's, say) into designs/, with the images they show.
    /// The source is only read. A design that already exists here is left alone. Returns how many were added.
    @discardableResult
    func importDesigns(from folder: URL) -> Int {
        try? fm.createDirectory(at: designsDir.appendingPathComponent("assets"), withIntermediateDirectories: true)
        var added = 0
        for file in ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).sorted(by: { $0.path < $1.path })
        where file.pathExtension == "canvas" {
            let id = Self.designID(file.deletingPathExtension().lastPathComponent)
            guard !id.isEmpty, !designs.contains(where: { $0.id == id }), !fm.fileExists(atPath: designFile(id).path),
                  let data = try? Data(contentsOf: file) else { continue }
            var canvas = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? ["nodes": [Any](), "edges": [Any]()]
            if var nodes = canvas["nodes"] as? [[String: Any]] {
                for index in nodes.indices where nodes[index]["type"] as? String == "file" {
                    guard let path = nodes[index]["file"] as? String, let source = Self.locate(path, near: folder) else { continue }
                    let name = uniqueName(source.lastPathComponent, in: designsDir.appendingPathComponent("assets"))
                    if (try? fm.copyItem(at: source, to: designsDir.appendingPathComponent("assets/" + name))) != nil {
                        nodes[index]["file"] = assetPath(name)
                    }
                }
                canvas["nodes"] = nodes
            }
            guard let out = try? JSONSerialization.data(withJSONObject: canvas, options: [.prettyPrinted, .withoutEscapingSlashes]),
                  (try? out.write(to: designFile(id), options: .atomic)) != nil else { continue }
            designs.append(TicketDesign(id: id, title: Self.designTitle(id), project: guessProject(id), updated: TicketDates.now()))
            added += 1
        }
        saveDesignIndex()
        onChange?()
        return added
    }

    /// How a canvas should name an image in designs/assets. Obsidian resolves paths from the vault root, so when
    /// the ticket folder is inside a vault the path starts there and the image shows in Obsidian as well.
    private func assetPath(_ name: String) -> String {
        var base = designsDir.standardizedFileURL, parts = ["assets", name]
        for _ in 0..<12 {
            parts.insert(base.lastPathComponent, at: 0)
            let parent = base.deletingLastPathComponent()
            if parent.path == base.path { break }
            base = parent
            if fm.fileExists(atPath: base.appendingPathComponent(".obsidian").path) { return parts.joined(separator: "/") }
        }
        return "assets/" + name
    }

    /// The file an image path on a design means: inside designs/ as written, or by name in designs/assets
    /// (a path written from the vault root). Never a file outside designs/.
    func designAsset(_ path: String) -> URL? {
        let home = designsDir.standardizedFileURL.path + "/"
        let direct = designsDir.appendingPathComponent(path).standardizedFileURL
        if direct.path.hasPrefix(home), fm.fileExists(atPath: direct.path) { return direct }
        let byName = designsDir.appendingPathComponent("assets").appendingPathComponent((path as NSString).lastPathComponent).standardizedFileURL
        return byName.path.hasPrefix(home) && fm.fileExists(atPath: byName.path) ? byName : nil
    }

    /// A canvas names its files relative to the vault root, which is some folder above the canvas.
    private static func locate(_ path: String, near folder: URL) -> URL? {
        var base = folder
        for _ in 0..<12 {
            let candidate = base.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            let parent = base.deletingLastPathComponent()
            if parent.path == base.path { break }
            base = parent
        }
        return nil
    }

    func setInstructions(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        instructions = clean.isEmpty ? Self.defaultInstructions : clean
        try? instructions.write(to: instructionsFile, atomically: true, encoding: .utf8)
        onChange?()
    }

    func add(_ decision: TicketDecision) {
        decisions.append(decision)
        if decisions.count > 2000 { decisions.removeFirst(decisions.count - 2000) }
        writeLines(decisions, to: decisionsFile)
    }

    func addCorrection(_ text: String, ticket: Int?) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        corrections.append(TicketCorrection(at: TicketDates.now(), ticket: ticket, text: clean))
        writeLines(corrections, to: correctionsFile)
        onChange?()
    }

    func removeCorrection(at stamp: String, text: String) {
        corrections.removeAll { $0.at == stamp && $0.text == text }
        writeLines(corrections, to: correctionsFile)
        onChange?()
    }

    // MARK: For the windows

    func json<T: Encodable>(_ value: T) -> Any {
        guard let data = try? lineEncoder.encode(value), let object = try? JSONSerialization.jsonObject(with: data) else { return NSNull() }
        return object
    }
}
