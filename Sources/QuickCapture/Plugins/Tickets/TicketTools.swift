import Foundation

/// The agent's action space beyond the ticket it is answering. Each tool is one object in the "actions" list
/// of its ticket block; the app carries them out and logs each one. This list is the single source for the
/// prompt, the Agent → Tools page and the system design drawing.
struct TicketTool {
    let name: String
    /// "tickets", "projects", "tags" or "designs": what the tool organizes.
    let area: String
    let arguments: String
    let what: String
}

enum TicketTools {
    static let all: [TicketTool] = [
        TicketTool(name: "create_ticket", area: "tickets",
                   arguments: #"{"text": "…", "title": "…", "kind": "todo", "project": "id", "tags": ["…"], "start": "YYYY-MM-DD", "due": "YYYY-MM-DD", "due_time": "HH:MM", "status": "waiting_human | closed"}"#,
                   what: "Add another ticket: split a capture that holds several things, turn a meeting note's action items into todos, add the steps of a plan. Only \"text\" is required."),
        TicketTool(name: "update_ticket", area: "tickets",
                   arguments: #"{"id": 12, "title": "…", "summary": "…", "kind": "…", "project": "…", "add_tags": ["…"], "remove_tags": ["…"], "start": "…", "due": "…", "due_time": "HH:MM or null", "status": "waiting_human | closed", "note": "why"}"#,
                   what: "Change another ticket: move a plan's dates, close a todo this capture finished, re-file a ticket. \"note\" is added to that ticket's conversation."),
        TicketTool(name: "merge_tickets", area: "tickets",
                   arguments: #"{"ids": [12, 15], "title": "…"}"#,
                   what: "Make one ticket out of tickets about the same thing. The originals are kept and can be unmerged."),
        TicketTool(name: "set_principle", area: "tickets",
                   arguments: #"{"text": "One imperative sentence.", "id": 7}"#,
                   what: "Record a personal rule the user stated, or reword an existing principle (give its ticket id). Principles are part of your instructions from then on."),
        TicketTool(name: "update_project", area: "projects",
                   arguments: #"{"id": "project-id", "name": "…", "category": "research | class | personal | …", "note": "…", "context": "maintained Markdown", "context_ticket_ids": [3], "important": true}"#,
                   what: "Keep a project current: its category, the one-line note, the maintained context (state, goals, decisions, what is missing)."),
        TicketTool(name: "define_tag", area: "tags",
                   arguments: #"{"id": "parent/child", "meaning": "one line: what tickets with it have in common", "action": "what is done differently because of it"}"#,
                   what: "Add a tag to the vocabulary, or sharpen one. The id is a full path under an existing parent (depth 1 a purpose or area, 2 a field, 3+ one concept). Needs a meaning and an action. Reuse before inventing; a project, course or paper name is never a tag."),
        TicketTool(name: "merge_tags", area: "tags",
                   arguments: #"{"from": ["planning", "plans"], "into": "career/build"}"#,
                   what: "Fold tags into one on every ticket (also how a loose, undefined tag is filed under the vocabulary). Sub-tags move with their parent."),
        TicketTool(name: "delete_tag", area: "tags",
                   arguments: #"{"id": "tag"}"#,
                   what: "Remove a tag that carries no meaning, and anything below it, from every ticket."),
        TicketTool(name: "add_kind", area: "tags",
                   arguments: #"{"id": "…", "label": "…", "icon": "one emoji", "view": "thread | todo | plan | habit | resource | principle", "description": "…", "rule": "…"}"#,
                   what: "Propose a new kind — the tag that decides where a ticket is shown and which rule you follow. Only when nothing fits and at least two tickets would use it."),
        TicketTool(name: "save_design", area: "designs",
                   arguments: #"{"id": "existing id to replace, or leave out", "title": "…", "project": "id", "summary": "…", "nodes": [{"id": "a", "text": "Markdown", "group": "optional box label", "color": "1-6"}], "edges": [{"from": "a", "to": "b", "label": "…"}]}"#,
                   what: "Draw or redraw a design (a flowchart the user reads and edits in Library → Designs): a system, a plan, how ideas connect. Positions are laid out for you; to place nodes yourself give every node x, y, width, height."),
    ]

    /// The "# Tools" section of the prompt.
    static func prompt() -> String {
        var out = "# Tools\nBesides answering this ticket you organize the whole system. Put any of these in \"actions\" in your ticket block; "
        out += "each is {\"tool\": name, …arguments}. Use them without asking when the capture clearly calls for it, and say what you did in the reply.\n"
        for tool in all { out += "- \(tool.name) \(tool.arguments) — \(tool.what)\n" }
        return out
    }

    static func json() -> [[String: String]] {
        all.map { ["name": $0.name, "area": $0.area, "arguments": $0.arguments, "what": $0.what] }
    }

    static func number(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        guard let text = value as? String else { return nil }
        return Int(text.trimmingCharacters(in: CharacterSet(charactersIn: "# ")))
    }

    static func strings(_ value: Any?) -> [String] { (value as? [Any] ?? []).compactMap { $0 as? String } }
}

extension TicketStore {
    /// Carries out the agent's actions. Returns one line per thing that changed (or was refused), for the decision log.
    func apply(actions: [[String: Any]], from source: Int) -> [String] {
        var changes: [String] = []
        var created = 0
        for action in actions.prefix(40) {
            guard let tool = action["tool"] as? String else { continue }
            switch tool {
            case "create_ticket":
                guard let text = (action["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                    changes.append("create_ticket refused: no text"); continue
                }
                guard created < 10 else { changes.append("create_ticket refused: more than 10 in one turn"); continue }
                created += 1
                let ticket = create(text: text, staged: [])
                update(ticket.id) { t in
                    if let title = (action["title"] as? String)?.trimmingCharacters(in: .whitespaces), !title.isEmpty { t.title = title }
                    self.applyFields(action, to: &t)
                    t.tags = self.allowed(TicketTools.strings(action["tags"]), keeping: t.tags, refused: &changes)
                    t.status = (action["status"] as? String) == "closed" ? .closed : .waitingHuman
                    t.history.append(TicketEvent(at: TicketDates.now(), by: "agent", text: "Created by the agent while answering #\(source)"))
                }
                changes.append("created #\(ticket.id) “\(tickets[ticket.id]?.title ?? "")”")
            case "update_ticket":
                guard let id = TicketTools.number(action["id"]), let before = tickets[id], before.mergedInto == nil else {
                    changes.append("update_ticket refused: no such ticket"); continue
                }
                update(id, touch: false) { t in
                    if let title = (action["title"] as? String)?.trimmingCharacters(in: .whitespaces), !title.isEmpty { t.title = title }
                    self.applyFields(action, to: &t)
                    var tags = t.tags + self.allowed(TicketTools.strings(action["add_tags"]), keeping: [], refused: &changes)
                    let remove = Set(TicketTools.strings(action["remove_tags"]).map { TicketStructure.tagPath($0) })
                    tags.removeAll { remove.contains($0) }
                    t.tags = tags.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                    if let status = action["status"] as? String, let value = Ticket.Status(rawValue: status), value == .closed || value == .waitingHuman {
                        t.status = value
                    }
                    let note = (action["note"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !note.isEmpty, id != source {
                        t.messages.append(TicketMessage(role: "system", text: "Updated by the agent while answering #\(source): \(note)", at: TicketDates.now()))
                    }
                    t.history.append(TicketEvent(at: TicketDates.now(), by: "agent", text: "Updated from #\(source)" + (note.isEmpty ? "" : ": \(note)")))
                }
                changes.append("updated #\(id)" + Self.diff(before, tickets[id]))
            case "merge_tickets":
                let ids = (action["ids"] as? [Any] ?? []).compactMap { TicketTools.number($0) }.filter { tickets[$0] != nil }
                if let merged = merge(ids, by: "agent", title: action["title"] as? String) {
                    changes.append("merged " + ids.map { "#\($0)" }.joined(separator: ", ") + " → #\(merged.id)")
                } else { changes.append("merge_tickets refused: needs two existing tickets") }
            case "set_principle":
                guard let text = (action["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
                if let id = TicketTools.number(action["id"]), tickets[id]?.kind == "principle" {
                    update(id, touch: false) {
                        $0.history.append(TicketEvent(at: TicketDates.now(), by: "agent", text: "Principle reworded from #\(source); was: \($0.summary)"))
                        $0.summary = text
                    }
                    changes.append("principle #\(id) reworded")
                } else if let same = tickets.values.first(where: { $0.kind == "principle" && $0.mergedInto == nil && $0.summary == text }) {
                    changes.append("principle already recorded as #\(same.id)")
                } else {
                    let ticket = create(text: text, staged: [])
                    update(ticket.id) {
                        $0.kind = "principle"
                        $0.summary = text
                        $0.status = .closed
                        $0.history.append(TicketEvent(at: TicketDates.now(), by: "agent", text: "Principle recorded while answering #\(source)"))
                    }
                    changes.append("principle recorded as #\(ticket.id)")
                }
            case "update_project":
                var next = structure
                guard let id = action["id"] as? String, let index = next.projects.firstIndex(where: { $0.id == id }) else {
                    changes.append("update_project refused: no such project"); continue
                }
                var what: [String] = []
                if let name = (action["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty { next.projects[index].name = name; what.append("name") }
                if let category = (action["category"] ?? action["type"]) as? String { next.projects[index].type = Self.category(category); what.append("category") }
                if let note = action["note"] as? String { next.projects[index].note = note; what.append("note") }
                if let context = action["context"] as? String { next.projects[index].context = context; what.append("context") }
                if let important = action["important"] as? Bool { next.projects[index].important = important; what.append("important") }
                if let ids = action["context_ticket_ids"] as? [Any] {
                    next.projects[index].contextTicketIDs = Array(Set(ids.compactMap { TicketTools.number($0) }.filter { tickets[$0] != nil })).sorted()
                    what.append("context tickets")
                }
                setStructure(next)
                changes.append("project \(id): " + (what.isEmpty ? "nothing to change" : what.joined(separator: ", ") + " updated"))
            case "define_tag":
                let meaning = (action["meaning"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let does = (action["action"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let id = TicketStructure.tagPath(action["id"] as? String ?? "")
                guard !id.isEmpty, !meaning.isEmpty, !does.isEmpty else {
                    changes.append("define_tag refused: a tag needs an id, a meaning and an action"); continue
                }
                let leaf = id.split(separator: "/").last.map(String.init) ?? id
                guard !structure.kinds.contains(where: { $0.id == leaf }), !structure.projects.contains(where: { $0.id == leaf }) else {
                    changes.append("define_tag refused: \(leaf) is a kind or a project, not a tag"); continue
                }
                let existed = isDefinedTag(id)
                if let parent = TicketTagFiles.parent(id), !isDefinedTag(parent) {
                    changes.append("define_tag refused: \(id) has no parent \(parent) (define the parent first)"); continue
                }
                if !existed, TicketTagFiles.depth(id) <= 2, structure.tags.filter({ TicketTagFiles.depth($0.id) <= 2 }).count >= TicketTagFiles.indexMax {
                    changes.append("define_tag refused: the index is full (\(TicketTagFiles.indexMax) depth 1-2 tags); put \(id) deeper, under an existing field"); continue
                }
                defineTag(id, meaning: meaning, action: does)
                changes.append(existed ? "tag redefined: \(id)" : "tag defined: \(id)")
            case "merge_tags":
                let from = TicketTools.strings(action["from"])
                guard let into = action["into"] as? String, let count = mergeTags(from, into: into) else {
                    changes.append("merge_tags refused: needs \"from\" and \"into\""); continue
                }
                changes.append("tags merged: \(from.joined(separator: ", ")) → \(TicketStructure.tagPath(into)) (\(count) ticket\(count == 1 ? "" : "s"))")
            case "delete_tag":
                guard let id = action["id"] as? String, !TicketStructure.tagPath(id).isEmpty else { continue }
                let count = deleteTag(id)
                changes.append("tag deleted: \(TicketStructure.tagPath(id)) (\(count) ticket\(count == 1 ? "" : "s"))")
            case "add_kind":
                if let line = addKind(action) { changes.append(line) }
            case "save_design":
                let title = (action["title"] as? String)?.trimmingCharacters(in: .whitespaces)
                let nodes = action["nodes"] as? [[String: Any]] ?? []
                guard !nodes.isEmpty else { changes.append("save_design refused: no nodes"); continue }
                let canvas = TicketCanvasLayout.canvas(nodes: nodes, edges: action["edges"] as? [[String: Any]] ?? [])
                let existing = (action["id"] as? String).flatMap { id in designs.first { $0.id == Self.designID(id) }?.id }
                if let id = saveDesign(id: existing ?? action["id"] as? String, title: title, project: action["project"] as? String,
                                       summary: action["summary"] as? String, canvas: canvas) {
                    changes.append((existing == nil ? "design drawn: " : "design redrawn: ") + id)
                    onDesignRedrawn?(id)
                } else { changes.append("save_design refused: needs a title") }
            default:
                changes.append("unknown tool: \(tool)")
            }
        }
        return changes
    }

    /// Adds a kind from the agent's description. Returns the log line, or nil when it already exists.
    func addKind(_ new: [String: Any]) -> String? {
        guard let rawID = new["id"] as? String else { return nil }
        let id = TicketStructure.slug(rawID)
        var next = structure
        guard !id.isEmpty, !next.kinds.contains(where: { $0.id == id }) else { return nil }
        let view = new["view"] as? String ?? "thread"
        let kind = TicketStructure.Kind(
            id: id, label: new["label"] as? String ?? rawID, icon: new["icon"] as? String ?? "🏷",
            view: ["habit", "plan", "todo", "resource", "principle", "thread"].contains(view) ? view : "thread",
            description: new["description"] as? String ?? "", rule: new["rule"] as? String ?? "")
        next.kinds.insert(kind, at: max(0, next.kinds.count - 1))
        setStructure(next)
        return "new kind: \(id)"
    }

    /// The tags the agent may put on a ticket: ones in the registry, plus what the ticket already carries
    /// (the user typed those). Anything else is refused — a tag needs a meaning first (define_tag).
    func allowed(_ tags: [String], keeping current: [String], refused: inout [String]) -> [String] {
        var out: [String] = []
        for tag in tags.map({ TicketStructure.tagPath($0) }) where !tag.isEmpty && !out.contains(tag) {
            if isDefinedTag(tag) || current.contains(tag) { out.append(tag) }
            else if structure.kinds.contains(where: { $0.id == tag }) || structure.projects.contains(where: { $0.id == tag }) { continue }
            else { refused.append("tag refused (not defined): \(tag)") }
        }
        return out
    }

    private func applyFields(_ fields: [String: Any], to ticket: inout Ticket) {
        if let summary = fields["summary"] as? String { ticket.summary = summary }
        if let kind = fields["kind"] as? String, structure.kinds.contains(where: { $0.id == TicketStructure.slug(kind) }) {
            ticket.kind = TicketStructure.slug(kind)
        }
        if let name = fields["project"] as? String { ticket.project = name.isEmpty ? "" : project(named: name) }
        for (key, path) in [("start", \Ticket.start), ("due", \Ticket.due)] where fields[key] != nil {
            ticket[keyPath: path] = (fields[key] as? String).flatMap { TicketDates.isDay($0) ? $0 : nil }
        }
        if fields["due_time"] != nil { ticket.dueTime = (fields["due_time"] as? String).flatMap(TicketDates.time) }
        if ticket.due == nil { ticket.dueTime = nil }
    }

    private static func diff(_ before: Ticket, _ after: Ticket?) -> String {
        guard let after else { return "" }
        var parts: [String] = []
        if before.title != after.title { parts.append("title") }
        if before.kind != after.kind { parts.append("kind → \(after.kind)") }
        if before.project != after.project { parts.append("project → \(after.project.isEmpty ? "—" : after.project)") }
        if before.start != after.start || before.due != after.due { parts.append("dates → \(after.start ?? "—") … \(after.due ?? "—")") }
        if before.status != after.status { parts.append("status → \(after.status.rawValue)") }
        if before.tags != after.tags { parts.append("tags") }
        return parts.isEmpty ? "" : " (" + parts.joined(separator: ", ") + ")"
    }
}

/// Turns the agent's plain list of boxes and arrows into a JSON Canvas with positions.
enum TicketCanvasLayout {
    static func canvas(nodes raw: [[String: Any]], edges rawEdges: [[String: Any]]) -> [String: Any] {
        func id(_ value: Any?) -> String? { (value as? String) ?? (value as? NSNumber)?.stringValue }
        let placed = raw.allSatisfy { $0["x"] is NSNumber && $0["y"] is NSNumber && $0["width"] is NSNumber && $0["height"] is NSNumber }
        var nodes: [[String: Any]] = []
        var frames: [String: (x: Double, y: Double, w: Double, h: Double)] = [:]
        var order: [String] = []

        func size(_ text: String) -> (Double, Double) {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let rows = lines.reduce(0) { $0 + max(1, Int((Double($1.count) / 30).rounded(.up))) }
            return (260, Double(max(60, 34 + rows * 22)))
        }

        if placed {
            for node in raw {
                guard let key = id(node["id"]) else { continue }
                var out = node
                out["id"] = key
                out["type"] = node["type"] as? String ?? "text"
                if out["type"] as? String == "text" { out["text"] = node["text"] as? String ?? "" }
                out["group"] = nil
                nodes.append(out)
                func n(_ k: String) -> Double { (node[k] as? NSNumber)?.doubleValue ?? 0 }
                frames[key] = (n("x"), n("y"), n("width"), n("height"))
            }
        } else {
            var texts: [String: String] = [:], groups: [String: String] = [:], colors: [String: String] = [:]
            for node in raw {
                guard let key = id(node["id"]), texts[key] == nil else { continue }
                order.append(key)
                texts[key] = node["text"] as? String ?? node["label"] as? String ?? key
                if let group = node["group"] as? String, !group.isEmpty { groups[key] = group }
                if let color = id(node["color"]) { colors[key] = color }
            }
            let links = rawEdges.compactMap { edge -> (String, String)? in
                guard let from = id(edge["from"] ?? edge["fromNode"]), let to = id(edge["to"] ?? edge["toNode"]),
                      texts[from] != nil, texts[to] != nil, from != to else { return nil }
                return (from, to)
            }
            if groups.isEmpty {
                // Layers top to bottom: a node sits below everything that points at it.
                var layer = Dictionary(uniqueKeysWithValues: order.map { ($0, 0) })
                for _ in 0..<order.count {
                    var moved = false
                    for (from, to) in links where (layer[to] ?? 0) <= (layer[from] ?? 0) && (layer[from] ?? 0) < order.count {
                        layer[to] = (layer[from] ?? 0) + 1
                        moved = true
                    }
                    if !moved { break }
                }
                var y = 0.0
                for level in 0...(layer.values.max() ?? 0) {
                    let row = order.filter { layer[$0] == level }
                    let width = Double(row.count) * 320 - 60
                    var x = -width / 2, tallest = 0.0
                    for key in row {
                        let (w, h) = size(texts[key] ?? "")
                        frames[key] = (x, y, w, h)
                        x += 320
                        tallest = max(tallest, h)
                    }
                    y += tallest + 90
                }
            } else {
                // One column per group, in the order the groups first appear.
                var columns: [String] = []
                for key in order { let g = groups[key] ?? ""; if !columns.contains(g) { columns.append(g) } }
                for (index, group) in columns.enumerated() {
                    let x = Double(index) * 380
                    var y = 0.0
                    let members = order.filter { (groups[$0] ?? "") == group }
                    for key in members {
                        let (w, h) = size(texts[key] ?? "")
                        frames[key] = (x, y, w, h)
                        y += h + 40
                    }
                    if !group.isEmpty {
                        nodes.append(["id": "group-\(index)", "type": "group", "label": group,
                                      "x": x - 30, "y": -60, "width": 320, "height": y + 50])
                    }
                }
            }
            for key in order {
                guard let f = frames[key] else { continue }
                var node: [String: Any] = ["id": key, "type": "text", "text": texts[key] ?? "", "x": f.x, "y": f.y, "width": f.w, "height": f.h]
                if let color = colors[key] { node["color"] = color }
                nodes.append(node)
            }
        }

        var edges: [[String: Any]] = []
        for (index, edge) in rawEdges.enumerated() {
            guard let from = id(edge["from"] ?? edge["fromNode"]), let to = id(edge["to"] ?? edge["toNode"]),
                  let a = frames[from], let b = frames[to] else { continue }
            let dx = (b.x + b.w / 2) - (a.x + a.w / 2), dy = (b.y + b.h / 2) - (a.y + a.h / 2)
            let horizontal = abs(dx) > abs(dy)
            var out: [String: Any] = [
                "id": id(edge["id"]) ?? "edge-\(index)", "fromNode": from, "toNode": to,
                "fromSide": edge["fromSide"] as? String ?? (horizontal ? (dx > 0 ? "right" : "left") : (dy > 0 ? "bottom" : "top")),
                "toSide": edge["toSide"] as? String ?? (horizontal ? (dx > 0 ? "left" : "right") : (dy > 0 ? "top" : "bottom")),
            ]
            if let label = edge["label"] as? String, !label.isEmpty { out["label"] = label }
            if let color = id(edge["color"]) { out["color"] = color }
            edges.append(out)
        }
        return ["nodes": nodes, "edges": edges]
    }
}
