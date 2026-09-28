// Headless check of the AI Chat engine against a real CLI: two turns in a temporary folder
// (file edit + shell command, then a follow-up that needs the first turn's context).
// Run with: scripts/chat-smoke.sh claude sonnet   |   scripts/chat-smoke.sh codex gpt-6-luna
import Foundation

// Stand-ins for app types the engine files reference.
struct AIChatSettings { var permissions = "edit"; func path(for p: Provider) -> String { "" } }

@MainActor func run(_ provider: Provider, _ model: String, in dir: URL) async -> Bool {
    let detector = AgentDetector()
    await detector.detect(settings: AIChatSettings())
    guard let install = detector.installs[provider] else { print("✗ \(provider.displayName) not found"); return false }
    print("found \(install.path) \(install.version)")
    let session = ChatSession(detector: detector, directory: dir)
    session.setModel(ChatModel(provider: provider, id: model, label: model))
    var replies: [String] = [], errors: [String] = []
    for prompt in ["Remember the number 42. Create a file hello.txt containing `hi`, run `ls`, and reply in one short sentence.",
                   "What number did I ask you to remember? Answer with just the number."] {
        var idle = false, reply = ""
        session.onEvent = { ev in
            switch ev["type"] as? String {
            case "text_delta", "text": reply += ev["text"] as? String ?? ""
            case "tool": print("  tool: \(ev["name"] ?? "") \(ev["detail"] ?? "")")
            case "error": errors.append(ev["message"] as? String ?? "")
            case "idle": idle = true
            default: break
            }
        }
        print("> \(prompt)")
        session.send(prompt, settings: AIChatSettings())
        while !idle { try? await Task.sleep(nanoseconds: 100_000_000) }
        print("< \(reply.trimmingCharacters(in: .whitespacesAndNewlines))")
        replies.append(reply)
    }
    let wrote = (try? String(contentsOf: dir.appendingPathComponent("hello.txt"), encoding: .utf8))?.contains("hi") == true
    let remembered = replies.last?.contains("42") == true
    print(errors.isEmpty ? "" : "errors: \(errors)")
    print(wrote && remembered && errors.isEmpty ? "✓ edit, shell and resume work" : "✗ wrote=\(wrote) remembered=\(remembered)")
    return wrote && remembered && errors.isEmpty
}

let args = CommandLine.arguments
guard args.count == 4, let provider = Provider(rawValue: args[1]) else {
    print("usage: chat_smoke claude|codex <model> <empty folder>"); exit(2)
}
Task { @MainActor in exit(await run(provider, args[2], in: URL(fileURLWithPath: args[3])) ? 0 : 1) }
RunLoop.main.run()
