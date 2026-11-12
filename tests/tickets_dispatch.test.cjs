// Exercise the production queue/choice code with process and app boundaries stubbed out.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const root = path.join(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'Sources/QuickCapture/Plugins/Tickets/TicketAgent.swift'), 'utf8');
const choice = source.slice(source.indexOf('struct TicketAgentChoice:'), source.indexOf('\nenum TicketAgentCommand'));
const runner = source.slice(source.indexOf('@MainActor\nfinal class TicketAgentRunner'), source.indexOf('    private func start(_ id: Int)'));
const harness = `import Foundation
import Dispatch
enum TicketAgentKind: String, Codable { case claude, codex, pi }
struct TicketsSettings {
 var agent = "codex"; var selfUpdate = false
 func model(for kind: TicketAgentKind) -> String { kind == .claude ? "opus" : "gpt" }
 func effort(for kind: TicketAgentKind) -> String { "high" }
}
${choice}
enum Toast { static func show(_ text: String, symbol: String, isError: Bool) {} }
@MainActor final class StreamingProcess { func stop() {} }
@MainActor final class TicketStore {
 var root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
 struct Message { var role = "human" }
 enum Status { case unprocessed, needsAgent }
 struct Ticket { var id: Int; var mergedInto: Int?; var status = Status.needsAgent; var messages = [Message()] }
 var tickets = Dictionary(uniqueKeysWithValues: (1...8).map { ($0, Ticket(id: $0)) })
 var sorted: [Ticket] { Array(tickets.values) }
}
@MainActor final class TicketsPlugin {
 var settings = TicketsSettings(); var store = TicketStore()
 struct Updater { var isBusy = false }; var selfUpdate = Updater()
}
${runner}
 var started: [(Int, TicketAgentChoice)] = []
 private func start(_ id: Int) {
   started.append((id, choices.removeValue(forKey: id)!)); running[id] = Run()
 }
 func complete(_ id: Int, followup: Bool = false) {
   running[id] = nil
   if followup { enqueue(id) }
   resume()
 }
}
@main struct Check {
 @MainActor static func main() {
   let plugin = TicketsPlugin(); let runner = TicketAgentRunner(plugin: plugin)
   runner.enqueue(1, choice: TicketAgentChoice(agent: .claude, model: "sonnet"))
   precondition(runner.started[0].1.agent == .claude && runner.started[0].1.model == "sonnet")
   runner.enqueue(2); runner.enqueue(3)
   precondition(runner.running.count == 2 && runner.queue == [3])
   plugin.settings.agent = "pi"
   runner.complete(1)
   precondition(runner.started.last!.1.agent == .codex, "queued default must be frozen")
   runner.enqueue(2, choice: TicketAgentChoice(agent: .claude, model: "opus"))
   runner.complete(2, followup: true)
   precondition(runner.started.last!.0 == 2 && runner.started.last!.1.agent == .claude)
   precondition(runner.started.last!.1.model == "opus", "busy reply must keep its model")
   runner.enqueue(4); runner.enqueue(4, choice: TicketAgentChoice(agent: .claude, model: "haiku"))
   precondition(runner.queue == [4], "queued ticket must not duplicate")
   runner.complete(3)
   precondition(runner.started.last!.1.model == "haiku")
   runner.enqueue(5); runner.stop(5); runner.complete(4)
   precondition(!runner.started.contains { $0.0 == 5 })
   let serial = TicketsPlugin(); serial.settings.selfUpdate = true
   let one = TicketAgentRunner(plugin: serial); one.enqueue(1); one.enqueue(2)
   precondition(one.running.count == 1 && one.queue == [2])
   serial.selfUpdate.isBusy = true; one.complete(1)
   precondition(one.running.isEmpty && one.queue == [2])
   serial.selfUpdate.isBusy = false; one.resume()
   precondition(one.started.last!.0 == 2)
   // Simulate another launch reading captures queued while an update is busy.
   serial.selfUpdate.isBusy = true
   one.enqueue(6, choice: TicketAgentChoice(agent: .claude, model: "sonnet"))
   let recovered = TicketAgentRunner(plugin: serial); recovered.enqueuePending()
   serial.selfUpdate.isBusy = false; recovered.resume()
   while !recovered.started.contains(where: { $0.0 == 6 }), let id = recovered.running.keys.first { recovered.complete(id) }
   precondition(recovered.started.first { $0.0 == 6 }?.1.model == "sonnet")
   try? FileManager.default.removeItem(at: plugin.store.root)
   try? FileManager.default.removeItem(at: serial.store.root)
   print("tickets_dispatch: all passed")
 }
}
`;
assert.ok(choice.includes('func resolved'));
assert.ok(runner.includes('private func pump'));
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'qc-dispatch-'));
try {
 fs.writeFileSync(path.join(tmp, 'check.swift'), harness);
 execFileSync('swiftc', ['-parse-as-library', '-o', path.join(tmp, 'check'), path.join(tmp, 'check.swift')], { stdio: 'inherit' });
 execFileSync(path.join(tmp, 'check'), [], { stdio: 'inherit' });
} finally { fs.rmSync(tmp, { recursive: true, force: true }); }
