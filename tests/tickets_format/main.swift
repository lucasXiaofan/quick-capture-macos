import Foundation

// Checks that a ticket survives being written to Markdown and read back (see scripts/tickets-test.sh).
func expect(_ ok: Bool, _ what: String) {
    if !ok { print("FAILED: \(what)"); exit(1) }
}

var ticket = Ticket(id: 12)
ticket.title = "Why \"K\" and V: differ? #1"
ticket.summary = "K decides where to look"
ticket.status = .waitingHuman
ticket.kind = "question"
ticket.project = "cs646"
ticket.relatedProjects = ["research"]
ticket.tags = ["ir", "2026"]
ticket.created = "2026-11-10T14:01:00-05:00"
ticket.updated = "2026-11-10T14:05:00-05:00"
ticket.start = "2026-11-12"
ticket.due = "2026-11-15"
ticket.takeaways = ["BM25 saturates: tf doesn't"]
ticket.log = [TicketLogEntry(date: "2026-11-10", name: "meditation", value: 5, unit: "min", note: nil)]
ticket.mergedFrom = [3, 4]
ticket.history = [TicketEvent(at: "2026-11-10T14:05:00-05:00", by: "agent", text: "kind: misc → question")]
ticket.messages = [
    TicketMessage(role: "human", text: "first line\n\n### a heading inside the message\n- [x] list\n\n```swift\nlet a = 1 --> 2\n```",
                  at: "2026-11-10T14:01:00-05:00", attachments: ["shot 1.png", "notes.pdf"]),
    TicketMessage(role: "agent", text: "Answer with $x^2$ and a [link](https://example.com).\n\n![not an attachment](x.png)",
                  at: "2026-11-10T14:05:00-05:00", agent: "claude:sonnet", tools: ["Bash: echo \"a --> b\" > out.txt", "WebSearch: 中文"], from: 3),
    TicketMessage(role: "system", text: "Stopped.", at: "2026-11-10T14:06:00-05:00"),
]

let text = TicketMarkdown.encode(ticket, attachmentsPath: "../attachments/12")
guard let back = TicketMarkdown.decode(text) else { print(text); expect(false, "decode returned nil"); exit(1) }
if back != ticket {
    print(text)
    for (a, b) in zip(ticket.messages, back.messages) where a != b { print("WANT", a, "\nGOT ", b) }
    expect(false, "round trip changed the ticket")
}
expect(text.hasPrefix("---\nid: 12\ntitle: \"Why \\\"K\\\" and V: differ? #1\"\n"), "front matter starts with id and a quoted title")
expect(text.contains("\nstatus: waiting_human\n") && text.contains("\ndue: 2026-11-15\n"), "plain words and dates aren't quoted")
expect(text.contains("![shot 1.png](../attachments/12/shot%201.png)"), "images are embedded for Markdown viewers")
expect(TicketMarkdown.decode(TicketMarkdown.encode(back, attachmentsPath: "../attachments/12")) == ticket, "second round trip")

// A file edited by hand: unknown keys are ignored, missing ones get defaults.
let manual = "---\nid: 7\ntitle: hand written\nkind: todo\nextra: [1, 2]\n---\n# hand written\n\n### Me · now\n<!-- msg {\"role\":\"human\",\"at\":\"2026-11-10T09:00:00-05:00\"} -->\nbuy milk\n"
let hand = TicketMarkdown.decode(manual)
expect(hand?.id == 7 && hand?.kind == "todo" && hand?.status == .unprocessed && hand?.messages.first?.text == "buy milk", "hand-written file loads")
expect(TicketMarkdown.decode("# not a ticket") == nil, "a file without front matter is skipped")
expect(TicketStructure.slug("CS 646: Info Retrieval!") == "cs-646-info-retrieval", "slug")
print("tickets_format: all passed")

let legacy = try! JSONDecoder().decode(TicketStructure.Project.self, from: Data(#"{"id":"old"}"#.utf8))
expect(legacy.context.isEmpty && legacy.contextTicketIDs.isEmpty && !legacy.workspaceImported, "legacy projects load with context defaults")
var project = legacy
project.context = "## Research questions\nA durable context"
project.contextTicketIDs = [3]
expect(try! JSONDecoder().decode(TicketStructure.Project.self, from: JSONEncoder().encode(project)) == project, "project context JSON round trip")
