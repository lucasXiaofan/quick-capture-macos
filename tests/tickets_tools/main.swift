import Foundation

func expect(_ ok: Bool, _ what: String) {
    if !ok { print("FAILED: \(what)"); exit(1) }
}

@MainActor func run() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TicketStore(root: root)
    _ = store.project(named: "alpha", type: "Research")
    expect(store.structure.projects[0].type == "research", "a category is stored lowercase")
    let meeting = store.create(text: "Meeting: ship the demo Friday, and fix login #nlp #natural-language", staged: [])
    expect(store.tickets[meeting.id]?.tags == ["nlp", "natural-language"], "hashtags that are no kind or project become tags")

    // Tags: only defined ones may be used by the agent; what the user typed stays.
    var refused: [String] = []
    expect(store.allowed(["nlp", "brand-new", "alpha"], keeping: ["nlp"], refused: &refused) == ["nlp"], "undefined tags are refused; a project is not a tag")
    expect(refused == ["tag refused (not defined): brand-new"], "the refusal is logged")
    var log = store.apply(actions: [
        ["tool": "define_tag", "id": "Deadline", "meaning": "", "action": ""],
        ["tool": "define_tag", "id": "Deadline", "meaning": "Has a hard external date", "action": "Set due; remind two days before"],
        ["tool": "define_tag", "id": "alpha", "meaning": "x", "action": "y"],
        ["tool": "define_tag", "id": "deadline/exam/midterm", "meaning": "x", "action": "y"],
        ["tool": "define_tag", "id": "Deadline / Exam", "meaning": "A course exam", "action": "Ask for a takeaway"],
        ["tool": "merge_tags", "from": ["natural-language"], "into": "nlp"],
    ], from: meeting.id)
    expect(log[0].contains("refused"), "a tag without meaning and action is refused")
    expect(store.structure.tags.first { $0.id == "deadline" }?.action == "Set due; remind two days before", "define_tag stores meaning and action")
    expect(log[2].contains("is a kind or a project"), "a project id cannot be redefined as a tag")
    expect(log[3].contains("no parent deadline/exam"), "a tag needs its parent first")
    expect(store.isDefinedTag("deadline/exam"), "a tag is a path under its parent")
    expect(store.tickets[meeting.id]?.tags == ["nlp"], "merge_tags rewrites tickets without duplicates")

    // The vocabulary lives in tags/: one line per tag, the index for depth 1-2, deeper files below; prose is kept.
    let refs = store.tagFilesDir
    let index = try String(contentsOf: refs.appendingPathComponent("index.md"), encoding: .utf8)
    expect(index.contains("- `deadline`: Has a hard external date Action: Set due; remind two days before\n- `deadline/exam`: A course exam Action: Ask for a takeaway"), "a tag is written as one line, right after its parent")
    expect(index.hasPrefix("# Tag index") && FileManager.default.fileExists(atPath: store.tagsDir.appendingPathComponent("SKILL.md").path), "a new folder gets the rules and an index header")
    try (index + "\nNotes I keep here.\n").write(to: refs.appendingPathComponent("index.md"), atomically: true, encoding: .utf8)
    try "# How to classify\nWould I do this if nobody asked?".write(to: refs.appendingPathComponent("map.md"), atomically: true, encoding: .utf8)
    store.defineTag("deadline/exam/midterm", meaning: "The mid-term", action: "Review a week ahead")
    store.defineTag("fresh/branch/leaf", meaning: "x")
    expect(try String(contentsOf: refs.appendingPathComponent("deadline/exam.md"), encoding: .utf8).contains("- `deadline/exam/midterm`: The mid-term Action: Review a week ahead"), "depth 3 goes to <l1>/<l2>.md")
    expect(store.isDefinedTag("fresh") && store.isDefinedTag("fresh/branch"), "missing parents are added so the tree has no gap")
    expect(try String(contentsOf: refs.appendingPathComponent("index.md"), encoding: .utf8).contains("Notes I keep here."), "other lines of a tag file are kept")
    expect(try String(contentsOf: refs.appendingPathComponent("map.md"), encoding: .utf8) == "# How to classify\nWould I do this if nobody asked?", "a file without tags is not rewritten")
    expect(store.tagMap?.contains("nobody asked") == true, "the map is available for the prompt")
    expect(TicketTagFiles.problems(store.structure.tags).contains("`fresh` has no definition"), "gaps are reported")
    let reread = TicketTagFiles.read(refs)
    expect(Set(reread.map(TicketTagFiles.text)) == Set(store.structure.tags.map(TicketTagFiles.text)) && reread.count == store.structure.tags.count, "what is written reads back the same")
    let skillLine = "- `life-balance`: A · stay sane and well on my own (joy alone); company is `relationship`. Action: protect it first; a week with none is a warning."
    try (TicketTagFiles.defaultIndex + "\n" + skillLine + "\n").write(to: root.appendingPathComponent("probe.md"), atomically: true, encoding: .utf8)
    let probe = TicketTagFiles.read(root.appendingPathComponent("probe.md").deletingLastPathComponent().appendingPathComponent("nowhere"))
    expect(probe.isEmpty, "a missing folder has no tags")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("probe"), withIntermediateDirectories: true)
    try (skillLine + "\n").write(to: root.appendingPathComponent("probe/index.md"), atomically: true, encoding: .utf8)
    let parsed = TicketTagFiles.read(root.appendingPathComponent("probe"))
    expect(parsed.count == 1 && parsed[0].action == "protect it first; a week with none is a warning." && TicketTagFiles.text(parsed[0]) == skillLine, "a line of the tags skill round-trips unchanged")
    var crowd = (1...16).map { TicketStructure.Tag(id: "a/b/t\($0)", meaning: "m") }
    crowd.append(TicketStructure.Tag(id: "a/b/t1/deep", meaning: "m"))
    let place = TicketTagFiles.placement(crowd)
    expect(place["a/b/t1"] == "a/b.md" && place["a/b/t1/deep"] == "a/b/t1.md", "past 15 tags, what hangs below a topic moves to its own file")
    expect(store.mergeTags(["fresh"], into: "deadline") == 0 && store.isDefinedTag("deadline/branch/leaf") && !store.isDefinedTag("fresh/branch"), "merging a tag moves its sub-tags with it")
    expect(store.deleteTag("deadline/branch") == 0 && !store.isDefinedTag("deadline/branch/leaf"), "deleting a tag removes what hangs below it")
    expect(store.isDefinedTag("nlp") && !store.isDefinedTag("natural-language"), "the merged tag leaves the registry")

    // Tickets, projects and principles.
    log = store.apply(actions: [
        ["tool": "create_ticket", "text": "Ship the demo", "kind": "todo", "project": "alpha", "due": "2026-11-13", "tags": ["deadline", "nope"]],
        ["tool": "create_ticket", "text": ""],
        ["tool": "update_ticket", "id": meeting.id, "kind": "meeting", "add_tags": ["deadline"], "remove_tags": ["nlp"], "status": "closed", "note": "split into todos"],
        ["tool": "update_project", "id": "alpha", "category": "Class", "context": "## State\nDemo Friday.", "context_ticket_ids": [meeting.id, 999]],
        ["tool": "set_principle", "text": "Ship before you polish."],
        ["tool": "set_principle", "text": "Ship before you polish."],
        ["tool": "no_such_tool"],
    ], from: meeting.id)
    let todo = store.tickets.values.first { $0.title == "Ship the demo" }
    expect(todo?.kind == "todo" && todo?.project == "alpha" && todo?.due == "2026-11-13" && todo?.status == .waitingHuman, "create_ticket sets its fields and waits for the user")
    expect(todo?.tags == ["deadline"], "create_ticket keeps only defined tags")
    expect(log.contains { $0.contains("create_ticket refused") }, "an empty ticket is refused")
    let updated = store.tickets[meeting.id]
    expect(updated?.kind == "meeting" && updated?.tags == ["deadline"] && updated?.status == .closed, "update_ticket changes kind, tags and status")
    expect(store.structure.projects[0].type == "class" && store.structure.projects[0].contextTicketIDs == [meeting.id], "update_project keeps only existing context tickets")
    expect(store.tickets.values.filter { $0.kind == "principle" }.count == 1, "the same principle is recorded once")
    expect(log.last == "unknown tool: no_such_tool", "an unknown tool is reported, not ignored")
    expect(store.deleteTag("deadline") == 2 && store.tickets[meeting.id]?.tags == [], "delete_tag clears the tag everywhere")

    // Deadlines: a time of day is kept only with a date; reminders fire that morning, or a few hours before the time.
    _ = store.apply(actions: [["tool": "create_ticket", "text": "Dentist", "due": "2026-11-14", "due_time": "9:30"],
                              ["tool": "create_ticket", "text": "Timeless", "due_time": "10:00"],
                              ["tool": "create_ticket", "text": "Form", "due": "2026-11-13"],
                              ["tool": "create_ticket", "text": "Done already", "due": "2026-11-13", "status": "closed"]], from: meeting.id)
    let dentist = store.tickets.values.first { $0.title == "Dentist" }!, form = store.tickets.values.first { $0.title == "Form" }!
    expect(dentist.dueTime == "09:30" && store.tickets.values.first { $0.title == "Timeless" }?.dueTime == nil, "due_time is normalized and needs a due date")
    let now = TicketDates.date(day: "2026-11-12", time: "10:00")!
    let plan = TicketReminders.plan(Array(store.tickets.values), now: now, hour: 7, leadHours: 5).filter { [dentist.id, form.id].contains($0.ticket) }
    expect(plan.map(\.ticket) == [form.id, dentist.id], "only open tickets with a deadline are reminded, soonest first")
    expect(!TicketReminders.plan(Array(store.tickets.values), now: now, hour: 7, leadHours: 5).contains { store.tickets[$0.ticket]?.isOpen != true }, "closed tickets are not reminded")
    expect(plan[0].fire == TicketDates.date(day: "2026-11-13", time: "07:00") && !plan[0].timed, "no time: 7:00 on the day")
    expect(plan[1].fire == TicketDates.date(day: "2026-11-14", time: "04:30") && plan[1].timed, "with a time: five hours before")
    expect(TicketReminders.plan([form], now: TicketDates.date(day: "2026-11-13", time: "08:00")!, hour: 7, leadHours: 5).isEmpty, "a reminder already past is not sent late")
    let text = TicketMarkdown.encode(dentist, attachmentsPath: "x")
    expect(text.contains("due_time: 09:30") && TicketMarkdown.decode(text)?.dueTime == "09:30", "due_time survives the Markdown file")

    // Designs: laid out, saved as JSON Canvas, redrawn in place, imported without touching the source.
    log = store.apply(actions: [["tool": "save_design", "title": "Demo flow", "project": "alpha",
        "nodes": [["id": "a", "text": "Capture"], ["id": "b", "text": "Classify"], ["id": "c", "text": "Act", "color": "4"]],
        "edges": [["from": "a", "to": "b", "label": "send"], ["from": "b", "to": "c"], ["from": "b", "to": "missing"]]]], from: meeting.id)
    expect(log == ["design drawn: Demo-flow"], "save_design creates the design")
    let data = try Data(contentsOf: store.designFile("Demo-flow"))
    let canvas = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    let nodes = canvas["nodes"] as? [[String: Any]] ?? [], edges = canvas["edges"] as? [[String: Any]] ?? []
    func y(_ id: String) -> Double { (nodes.first { $0["id"] as? String == id }?["y"] as? NSNumber)?.doubleValue ?? -1 }
    expect(nodes.count == 3 && edges.count == 2, "edges to unknown nodes are dropped")
    expect(y("a") < y("b") && y("b") < y("c"), "a node sits below what points at it")
    expect(edges[0]["fromSide"] as? String == "bottom" && edges[0]["toSide"] as? String == "top" && edges[0]["label"] as? String == "send", "edges get sides and keep labels")
    expect(store.designs.first?.project == "alpha", "the design is filed under its project")
    log = store.apply(actions: [["tool": "save_design", "id": "Demo-flow", "title": "Demo flow v2",
        "nodes": [["id": "x", "text": "One", "group": "In"], ["id": "y", "text": "Two", "group": "Out"]], "edges": []]], from: meeting.id)
    expect(log == ["design redrawn: Demo-flow"] && store.designs.count == 1 && store.designs[0].title == "Demo flow v2", "an existing id is redrawn, not duplicated")
    let grouped = TicketCanvasLayout.canvas(nodes: [["id": "x", "text": "One", "group": "In"], ["id": "y", "text": "Two", "group": "Out"]], edges: [])
    expect((grouped["nodes"] as? [[String: Any]])?.filter { $0["type"] as? String == "group" }.count == 2, "groups become boxes")

    let vault = root.appendingPathComponent("vault"), folder = vault.appendingPathComponent("notes/design")
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("assets"), withIntermediateDirectories: true)
    try Data([1, 2, 3]).write(to: folder.appendingPathComponent("assets/pic.png"))
    let source = #"{"nodes":[{"id":"n","type":"file","file":"notes/design/assets/pic.png","x":0,"y":0,"width":10,"height":10}],"edges":[]}"#
    try source.write(to: folder.appendingPathComponent("design_alpha-plan.canvas"), atomically: true, encoding: .utf8)
    expect(store.importDesigns(from: folder) == 1 && store.importDesigns(from: folder) == 0, "import adds each canvas once")
    expect(try String(contentsOf: folder.appendingPathComponent("design_alpha-plan.canvas"), encoding: .utf8) == source, "the source canvas is not changed")
    let imported = store.designs.first { $0.id == "design_alpha-plan" }
    expect(imported?.project == "alpha" && imported?.title == "Alpha plan", "an imported design gets a title and a guessed project")
    expect(store.designCanvas("design_alpha-plan")?.contains("assets/pic.png") == true
           && FileManager.default.fileExists(atPath: store.designsDir.appendingPathComponent("assets/pic.png").path), "its image is copied next to it")
    expect(store.designAsset("assets/pic.png") != nil && store.designAsset("any/vault/path/pic.png") != nil, "an image is found as written or by name")
    expect(store.designAsset("../structure.json") == nil && store.designAsset("../../etc/passwd") == nil, "nothing outside designs/ is served")
    store.load()
    expect(store.designs.count == 2 && store.structure.tags.contains { $0.id == "nlp" }, "designs and tags survive a reload")
    let saved = try String(contentsOf: root.appendingPathComponent("structure.json"), encoding: .utf8)
    expect(!saved.contains("\"tags\""), "structure.json no longer holds tags")
    // An older version kept tags in structure.json: they move into the folder once.
    try saved.replacingOccurrences(of: "\"projects\"", with: "\"tags\":[{\"id\":\"old-tag\",\"meaning\":\"from before\",\"action\":\"keep\"}],\"projects\"").write(to: root.appendingPathComponent("structure.json"), atomically: true, encoding: .utf8)
    store.load()
    expect(try String(contentsOf: refs.appendingPathComponent("index.md"), encoding: .utf8).contains("- `old-tag`: from before Action: keep")
           && !(try String(contentsOf: root.appendingPathComponent("structure.json"), encoding: .utf8)).contains("old-tag"), "tags from structure.json migrate to the tags folder")
    print("tickets_tools: all passed")
}

try MainActor.assumeIsolated { try run() }
