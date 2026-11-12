// self-update test marker
import Foundation

/// One captured thing — a todo, a question, a habit check-in, a bug… — plus its conversation with the agent.
/// A ticket never depends on how it is organized: kinds, projects and views are a layer on top (`TicketStructure`).
struct Ticket: Codable, Equatable {
    enum Status: String, Codable, CaseIterable {
        /// New; no agent has looked at it yet.
        case unprocessed
        /// In progress, the agent's turn.
        case needsAgent = "needs_agent"
        /// In progress, the human's turn.
        case waitingHuman = "waiting_human"
        case closed
    }

    var id: Int
    var title = ""
    /// One line: the answer, the principle, what the resource is.
    var summary = ""
    var status = Status.unprocessed
    /// A kind id from `TicketStructure.kinds`; "misc" is the bucket for what can't be categorized.
    var kind = "misc"
    /// A project id, or "" for none.
    var project = ""
    var relatedProjects: [String] = []
    var tags: [String] = []
    var created = ""
    var updated = ""
    /// yyyy-MM-dd. A ticket with both spans days (a plan, drawn on the Gantt chart); with only `due` it is a deadline.
    var start: String?
    var due: String?
    /// HH:mm on the due day, when the deadline has a time of day.
    var dueTime: String?
    var messages: [TicketMessage] = []
    /// Dated entries for recurring things (habits): what the heatmaps are drawn from.
    var log: [TicketLogEntry] = []
    var takeaways: [String] = []
    /// A merged ticket lists its sources; the sources stay on disk untouched and point back with `mergedInto`.
    var mergedFrom: [Int] = []
    var mergedInto: Int?
    /// What happened to the ticket, newest last: classified, merged, corrected, closed.
    var history: [TicketEvent] = []

    enum CodingKeys: String, CodingKey {
        case id, title, summary, status, kind, project, tags, created, updated, start, due, messages, log, takeaways
        case relatedProjects = "related_projects", dueTime = "due_time"
        case mergedFrom = "merged_from", mergedInto = "merged_into", history
    }

    init(id: Int) { self.id = id }

    /// Missing keys fall back to defaults, so files written by an older version keep loading.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        status = (try? c.decodeIfPresent(Status.self, forKey: .status)) ?? .unprocessed
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "misc"
        project = try c.decodeIfPresent(String.self, forKey: .project) ?? ""
        relatedProjects = try c.decodeIfPresent([String].self, forKey: .relatedProjects) ?? []
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        created = try c.decodeIfPresent(String.self, forKey: .created) ?? ""
        updated = try c.decodeIfPresent(String.self, forKey: .updated) ?? created
        start = try c.decodeIfPresent(String.self, forKey: .start)
        due = try c.decodeIfPresent(String.self, forKey: .due)
        dueTime = try c.decodeIfPresent(String.self, forKey: .dueTime)
        messages = try c.decodeIfPresent([TicketMessage].self, forKey: .messages) ?? []
        log = try c.decodeIfPresent([TicketLogEntry].self, forKey: .log) ?? []
        takeaways = try c.decodeIfPresent([String].self, forKey: .takeaways) ?? []
        mergedFrom = try c.decodeIfPresent([Int].self, forKey: .mergedFrom) ?? []
        mergedInto = try c.decodeIfPresent(Int.self, forKey: .mergedInto)
        history = try c.decodeIfPresent([TicketEvent].self, forKey: .history) ?? []
    }

    var isOpen: Bool { status != .closed }
}

struct TicketMessage: Codable, Equatable {
    /// "human", "agent" or "system" (an error or a note from the app).
    var role: String
    var text: String
    var at: String
    /// File names inside the ticket's attachment folder.
    var attachments: [String] = []
    /// "claude:sonnet" for agent messages.
    var agent: String?
    /// What the agent did during the turn ("Bash: pip install …"), for checking its work.
    var tools: [String]?
    /// The ticket this message came from, on a merged ticket.
    var from: Int?

    init(role: String, text: String, at: String, attachments: [String] = [], agent: String? = nil,
         tools: [String]? = nil, from: Int? = nil) {
        self.role = role; self.text = text; self.at = at; self.attachments = attachments
        self.agent = agent; self.tools = tools; self.from = from
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? "human"
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        at = try c.decodeIfPresent(String.self, forKey: .at) ?? ""
        attachments = try c.decodeIfPresent([String].self, forKey: .attachments) ?? []
        agent = try c.decodeIfPresent(String.self, forKey: .agent)
        tools = try c.decodeIfPresent([String].self, forKey: .tools)
        from = try c.decodeIfPresent(Int.self, forKey: .from)
    }
}

struct TicketLogEntry: Codable, Equatable {
    /// yyyy-MM-dd
    var date: String
    /// What recurs: "meditation", "exercise".
    var name: String
    var value: Double?
    var unit: String?
    var note: String?
}

struct TicketEvent: Codable, Equatable {
    var at: String
    /// "agent" or "human".
    var by: String
    var text: String
}

/// How tickets are organized and shown. Editing this never changes a ticket's content.
struct TicketStructure: Codable, Equatable {
    struct Kind: Codable, Equatable {
        var id: String
        var label: String
        var icon: String
        /// Which visualization the kind feeds: "habit" (heatmap), "plan" (Gantt), "todo", "resource",
        /// "principle" (also part of the agent prompt) or "thread" (just the inbox and its project).
        var view: String
        /// What a ticket of this kind looks like — how the agent recognizes it.
        var description: String
        /// What the agent does with it.
        var rule: String
    }

    struct Project: Codable, Equatable {
        var id: String
        var name: String
        /// The category the Projects page groups by: "research", "class", "personal", or any other word.
        var type = "personal"
        /// Marked by the user: worth making visible (paper, video, post).
        var important = false
        var note = ""
        var context = ""
        var contextTicketIDs: [Int] = []
        var workspaceImported = false

        enum CodingKeys: String, CodingKey {
            case id, name, type, important, note, context
            case contextTicketIDs = "context_ticket_ids", workspaceImported = "workspace_imported"
        }

        init(id: String, name: String, type: String = "personal") { self.id = id; self.name = name; self.type = type }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
            type = try c.decodeIfPresent(String.self, forKey: .type) ?? "personal"
            important = try c.decodeIfPresent(Bool.self, forKey: .important) ?? false
            note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
            context = try c.decodeIfPresent(String.self, forKey: .context) ?? ""
            contextTicketIDs = try c.decodeIfPresent([Int].self, forKey: .contextTicketIDs) ?? []
            workspaceImported = try c.decodeIfPresent(Bool.self, forKey: .workspaceImported) ?? false
        }
    }

    /// A tag carries a meaning and an action: what a ticket with this tag is, and what should happen to it.
    /// Its id is a path ("career/build"): depth 1 a purpose or area, depth 2 a field, deeper one concept.
    /// Kinds and projects are tags too (they have their own lists); this is the vocabulary for the rest.
    struct Tag: Codable, Equatable {
        var id: String
        /// What a ticket carrying this tag has in common.
        var meaning = ""
        /// What the agent (or the user) does differently because of it.
        var action = ""

        init(id: String, meaning: String = "", action: String = "") { self.id = id; self.meaning = meaning; self.action = action }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            meaning = try c.decodeIfPresent(String.self, forKey: .meaning) ?? ""
            action = try c.decodeIfPresent(String.self, forKey: .action) ?? ""
        }
    }

    var kinds: [Kind] = TicketStructure.defaultKinds
    var projects: [Project] = []
    var tags: [Tag] = []

    enum CodingKeys: String, CodingKey { case kinds, projects, tags }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kinds = try c.decodeIfPresent([Kind].self, forKey: .kinds) ?? TicketStructure.defaultKinds
        projects = try c.decodeIfPresent([Project].self, forKey: .projects) ?? []
        tags = try c.decodeIfPresent([Tag].self, forKey: .tags) ?? []
        if !kinds.contains(where: { $0.id == "misc" }), let misc = TicketStructure.defaultKinds.last { kinds.append(misc) }
    }

    /// Tags are written to structure.json only by older versions; they live in the tags folder now (`TicketTagFiles`).
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kinds, forKey: .kinds)
        try c.encode(projects, forKey: .projects)
        if !tags.isEmpty { try c.encode(tags, forKey: .tags) }
    }

    static func slug(_ name: String) -> String {
        let lowered = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var out = ""
        for ch in lowered {
            if ch.isLetter || ch.isNumber { out.append(ch) } else if !out.hasSuffix("-") { out.append("-") }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// The starting list of what a ticket can be. It grows: the agent proposes a new kind when nothing fits,
    /// and every kind and rule can be edited in the Tickets window (Agent → Kinds & rules).
    static let defaultKinds: [Kind] = [
        Kind(id: "habit", label: "Habit", icon: "🔁", view: "habit",
             description: "A check-in for something recurring: meditation, exercise, sleep.",
             rule: "Add a log entry (date, habit name reused exactly from earlier entries, amount and unit if given). Reply in one encouraging line with the current streak if you can tell. Close."),
        Kind(id: "todo", label: "Todo", icon: "☑️", view: "todo",
             description: "Something doable in a few hours; at most it needs a deadline.",
             rule: "Set due if a date is mentioned. Do it yourself if you can with your access (then say what you did and close); otherwise list the first concrete step and wait."),
        Kind(id: "plan", label: "Plan", icon: "🗓", view: "plan",
             description: "Bigger than a todo: spans days, e.g. “Nov 12–15 finish cs646 hw2”.",
             rule: "Set start and due. Break it into 2–5 steps in the reply. Keep it open until the user says it is done."),
        Kind(id: "question", label: "Question", icon: "❓", view: "thread",
             description: "Something the user wants to understand.",
             rule: "Answer directly and briefly first, then give 2–3 good resources (search the web). Wait for the user; close only when they say they understand. Put the one-line answer in summary."),
        Kind(id: "review", label: "Exam review", icon: "📝", view: "thread",
             description: "Practice questions and review notes for a course exam or homework.",
             rule: "Assign the course as project. Check the answer or explain the question. Before closing there must be at least one takeaway."),
        Kind(id: "idea", label: "Idea", icon: "💡", view: "thread",
             description: "A thought, something the user wants to do or make, a draft (e.g. a video script).",
             rule: "Assign a project if it clearly belongs to one. Sharpen it in two or three lines and suggest the smallest next step. Wait."),
        Kind(id: "experiment", label: "Experiment", icon: "🧪", view: "thread",
             description: "A result (often a screenshot) or a run to do for a project.",
             rule: "Assign the project. State what the experiment is meant to prove or show; ask if it is missing. Record the result as a takeaway."),
        Kind(id: "feature", label: "Feature", icon: "✨", view: "thread",
             description: "A project needs a feature or an experience improved, and why.",
             rule: "Assign the project. Restate the problem it solves. Implement it only if the project folder is inside your access; otherwise outline the change and wait."),
        Kind(id: "bug", label: "Bug", icon: "🐞", view: "thread",
             description: "Something is broken; a bug report.",
             rule: "Assign the project. Reproduce and fix if the code is inside your access, and say how you verified it; otherwise list the likely cause and what you need."),
        Kind(id: "complaint", label: "Complaint", icon: "😤", view: "thread",
             description: "Something is bad and the user could do better.",
             rule: "Name the concrete problem in one line. If it repeats an earlier complaint, say so and suggest merging. Suggest turning it into an idea or a plan. Close unless the user wants more."),
        Kind(id: "resource", label: "Resource", icon: "🔖", view: "resource",
             description: "Something to keep: a link, a video, a subscription or account note.",
             rule: "Put what it is and why it was kept in summary, add tags, and close. Never repeat passwords or secrets in your reply."),
        Kind(id: "meeting", label: "Meeting note", icon: "👥", view: "thread",
             description: "Notes right after a meeting.",
             rule: "Ask which project it belongs to if unclear. List decisions and action items; propose the plans (multi-day) and todos (hours) to create and wait for the user's OK."),
        Kind(id: "shipping", label: "Shipping", icon: "🚀", view: "thread",
             description: "Making a project visible: paper, video, post, release.",
             rule: "Assign the project. Keep one open shipping ticket per deliverable; merge new ones about the same deliverable into it. List what is left to publish."),
        Kind(id: "principle", label: "Principle", icon: "🧭", view: "principle",
             description: "A new or updated personal rule.",
             rule: "Write the principle as one imperative sentence in summary. If it updates an older principle, merge with it. Close. Principles are part of your instructions from then on."),
        Kind(id: "misc", label: "Uncategorized", icon: "📥", view: "thread",
             description: "Nothing above fits.",
             rule: "Say in one line why it doesn't fit; if two or more tickets share a shape, propose a new kind. Wait."),
    ]
}

/// A design: a canvas (JSON Canvas, the format Obsidian uses) kept in <root>/designs/<id>.canvas.
/// This is its entry in designs/index.json; the drawing itself stays in the .canvas file.
struct TicketDesign: Codable, Equatable {
    var id: String
    var title: String
    /// A project id, or "" for none.
    var project = ""
    var summary = ""
    var updated = ""

    init(id: String, title: String, project: String = "", summary: String = "", updated: String = "") {
        self.id = id; self.title = title; self.project = project; self.summary = summary; self.updated = updated
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? id
        project = try c.decodeIfPresent(String.self, forKey: .project) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        updated = try c.decodeIfPresent(String.self, forKey: .updated) ?? ""
    }
}

/// One line of the agent's decision log (decisions.jsonl): what it changed on a ticket and why.
struct TicketDecision: Codable, Equatable {
    var at: String
    var ticket: Int
    var agent: String
    var changes: [String]
    var reasons: [String]
}

/// One line of the correction log (corrections.jsonl). Corrections are part of every agent prompt.
struct TicketCorrection: Codable, Equatable {
    var at: String
    var ticket: Int?
    var text: String
}

enum TicketDates {
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXX"
        return f
    }()
    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func now() -> String { stamp.string(from: Date()) }
    static func today() -> String { dayFormat.string(from: Date()) }
    static func isDay(_ s: String) -> Bool { s.count == 10 && dayFormat.date(from: s) != nil }
    /// "09:30" or "9:30" → "09:30"; nil when it is not a time of day.
    static func time(_ s: String) -> String? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count >= 2, let h = Int(parts[0]), let m = Int(parts[1]), (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return String(format: "%02d:%02d", h, m)
    }
    /// The moment a day (and an optional time on it) means, in local time.
    static func date(day: String, time: String?) -> Date? {
        guard isDay(day), let start = dayFormat.date(from: day) else { return nil }
        guard let time, let clean = TicketDates.time(time) else { return start }
        let parts = clean.split(separator: ":").compactMap { Int($0) }
        return Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: start)
    }
}

/// When to remind about what is due: at a fixed hour on the due day, or a few hours before a due time.
enum TicketReminders {
    struct Item: Equatable {
        var ticket: Int
        /// When the banner appears.
        var fire: Date
        /// The deadline itself.
        var due: Date
        var timed: Bool
    }

    /// Open tickets with a deadline whose reminder is still ahead, soonest first.
    static func plan(_ tickets: [Ticket], now: Date, hour: Int, leadHours: Int) -> [Item] {
        var out: [Item] = []
        for ticket in tickets where ticket.isOpen && ticket.mergedInto == nil {
            guard let day = ticket.due, let start = TicketDates.date(day: day, time: nil) else { continue }
            let item: Item
            if let time = ticket.dueTime, let due = TicketDates.date(day: day, time: time) {
                item = Item(ticket: ticket.id, fire: due.addingTimeInterval(-Double(max(0, leadHours)) * 3600), due: due, timed: true)
            } else {
                guard let fire = Calendar.current.date(bySettingHour: min(23, max(0, hour)), minute: 0, second: 0, of: start) else { continue }
                item = Item(ticket: ticket.id, fire: fire, due: start, timed: false)
            }
            if item.fire > now { out.append(item) }
        }
        return out.sorted { $0.fire < $1.fire || ($0.fire == $1.fire && $0.ticket < $1.ticket) }
    }
}
