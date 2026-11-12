import Foundation

func expect(_ ok: Bool, _ what: String) {
    if !ok { print("FAILED: \(what)"); exit(1) }
}

@MainActor func run() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TicketStore(root: root)
    _ = store.project(named: "alpha", type: "research")
    _ = store.project(named: "beta", type: "research")
    let source = store.create(text: "Shared research notes", staged: [])
    store.update(source.id) { $0.project = "alpha" }
    let plan = """
    # Plan
    Proposed start: 2026-11-10. Dates are provisional.
    ## 1. Prepare — Nov 10–12
    - [ ] Prepare rubrics
    ## 2. Analyze — Nov 20–Dec 1
    - [ ] Analyze data
    ## 3. Revise — Dec 2–8
    - [ ] Revise draft
    ## Immediate blockers
    Missing data
    """
    let stages = TicketWorkspaceImport.stages(plan)
    expect(stages.count == 3 && stages[1].due == "2026-12-01" && stages[2].due == "2026-12-08", "stage dates include month boundaries")
    expect(!stages[2].text.contains("Missing data"), "blockers are not stage tasks")
    expect(TicketWorkspaceImport.stages("## 1. Undated").isEmpty, "undated prose does not invent a schedule")
    for name in ["alpha", "beta"] {
        let dir = store.workspaceDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "# Context\nResearch questions [source](../../tickets/0001.md)".write(to: dir.appendingPathComponent("CONTEXT.md"), atomically: true, encoding: .utf8)
        try plan.write(to: dir.appendingPathComponent("PLAN.md"), atomically: true, encoding: .utf8)
    }
    store.load()
    expect(store.tickets.count == 7, "two projects import three dated plan tickets each")
    expect(store.tickets[1]?.relatedProjects == ["beta"], "shared source appears in both projects")
    expect(store.structure.projects.allSatisfy { $0.context.contains("Research questions") && $0.contextTicketIDs == [1] }, "context and sources imported")
    expect(store.sorted.filter { $0.kind == "plan" }.allSatisfy { $0.status == .waitingHuman && $0.start != nil && $0.due != nil && $0.messages[0].text.contains("- [ ]") }, "plans keep tasks, dates, and pending status")
    var structure = store.structure
    structure.projects[0].context = "User edited context"
    store.setStructure(structure)
    store.load()
    expect(store.tickets.count == 7 && store.structure.projects[0].context == "User edited context", "reload preserves edits and does not duplicate plans")
    let merged = store.merge([1, 2], by: "agent")
    expect(merged?.relatedProjects.contains("beta") == true, "merge preserves shared project membership")
    store.load()
    expect(store.tickets[merged!.id]?.relatedProjects.contains("beta") == true, "shared membership persists on disk")
    // Exercise the actual prepared project plans if paths are supplied, without editing the live store.
    for path in CommandLine.arguments.dropFirst() {
        let actual = TicketWorkspaceImport.stages(try String(contentsOfFile: path, encoding: .utf8))
        expect(actual.count == 4 && actual.last?.due == "2026-12-08", "prepared plan imports four stages through Dec 8: \(path)")
    }
    print("tickets_workspace: all passed")
}
try MainActor.assumeIsolated { try run() }
