import Foundation

// Checks TicketGitSnapshots against a throwaway repository (see scripts/tickets-test.sh).
func expect(_ ok: Bool, _ what: String) { if !ok { print("FAILED: \(what)"); exit(1) } }
func sh(_ dir: URL, _ args: [String]) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = ["git", "-C", dir.path] + args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
    try! p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}
func write(_ url: URL, _ text: String) {
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! text.write(to: url, atomically: true, encoding: .utf8)
}
func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

let repo = FileManager.default.temporaryDirectory.appendingPathComponent("qc-git-test-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: repo) }
let project = repo.appendingPathComponent("app")  // the project is a sub-folder of the repository
_ = sh(repo.deletingLastPathComponent(), ["init", "-q", repo.path])
write(project.appendingPathComponent(".gitignore"), "build/\n")
write(project.appendingPathComponent("a.txt"), "a1\n")
write(project.appendingPathComponent("c.txt"), "c1\n")
write(project.appendingPathComponent("sub/d.txt"), "d1\n")
write(repo.appendingPathComponent("outside.txt"), "outside\n")
_ = sh(repo, ["add", "-A"]); _ = sh(repo, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "init"])
// Uncommitted work that must survive everything below: a modified tracked file, a new file, an ignored file.
write(project.appendingPathComponent("a.txt"), "a2 (user edit)\n")
write(project.appendingPathComponent("user-new.txt"), "mine\n")
write(project.appendingPathComponent("build/out.bin"), "ignored\n")

let snaps = TicketGitSnapshots(folder: project, git: "/usr/bin/env")
let headBefore = sh(repo, ["rev-parse", "HEAD"])
let statusBefore = sh(repo, ["status", "--porcelain"])
let git = TicketGitSnapshots(folder: project, git: "/opt/homebrew/bin/git")
let tool = FileManager.default.isExecutableFile(atPath: "/usr/bin/git") ? "/usr/bin/git" : "/opt/homebrew/bin/git"
let s = TicketGitSnapshots(folder: project, git: tool)
_ = snaps; _ = git

let done = DispatchSemaphore(value: 0)
Task {
    guard let before = await s.snapshot("before") else { expect(false, "snapshot"); return }
    expect(sh(repo, ["rev-parse", "HEAD"]) == headBefore, "HEAD unchanged by a snapshot")
    expect(sh(repo, ["status", "--porcelain"]) == statusBefore, "index and working tree unchanged by a snapshot")
    expect(sh(repo, ["for-each-ref", "refs/quick-capture/snapshots/"]).contains(before), "snapshot is kept under a ref")
    expect(sh(repo, ["show", "\(before):app/a.txt"]) == "a2 (user edit)\n", "snapshot holds uncommitted edits")
    expect(sh(repo, ["show", "\(before):app/user-new.txt"]) == "mine\n", "snapshot holds new files")
    expect(!sh(repo, ["ls-tree", "-r", "--name-only", before]).contains("build/out.bin"), "ignored files stay out")
    expect(!sh(repo, ["ls-tree", "-r", "--name-only", before]).contains("outside.txt"), "only the project folder is recorded")

    // The agent edits, adds and deletes.
    write(project.appendingPathComponent("a.txt"), "a3 (agent)\n")
    write(project.appendingPathComponent("new/agent.swift"), "let x = 1\n")
    try? FileManager.default.removeItem(at: project.appendingPathComponent("c.txt"))
    write(project.appendingPathComponent("sub/d.txt"), "d2 (agent)\n")
    guard let after = await s.snapshot("after") else { expect(false, "second snapshot"); return }
    let changes = (await s.changes(from: before, to: after) ?? []).sorted { $0.path < $1.path }
    expect(changes == [.init(status: "M", path: "a.txt"), .init(status: "D", path: "c.txt"),
                       .init(status: "A", path: "new/agent.swift"), .init(status: "M", path: "sub/d.txt")], "changes: \(changes)")

    // Roll back.
    guard let replaced = await s.restore(to: before) else { expect(false, "restore"); return }
    expect(read(project.appendingPathComponent("a.txt")) == "a2 (user edit)\n", "user's uncommitted edit is back")
    expect(read(project.appendingPathComponent("c.txt")) == "c1\n", "deleted file is back")
    expect(read(project.appendingPathComponent("sub/d.txt")) == "d1\n", "nested edit undone")
    expect(!FileManager.default.fileExists(atPath: project.appendingPathComponent("new/agent.swift").path), "added file removed")
    expect(read(project.appendingPathComponent("user-new.txt")) == "mine\n", "user's new file untouched")
    expect(read(project.appendingPathComponent("build/out.bin")) == "ignored\n", "ignored file untouched")
    expect(read(repo.appendingPathComponent("outside.txt")) == "outside\n", "files outside the project untouched")
    expect(sh(repo, ["rev-parse", "HEAD"]) == headBefore, "HEAD unchanged by a restore")
    expect(sh(repo, ["show", "\(replaced):app/a.txt"]) == "a3 (agent)\n", "what the restore replaced is kept, so it can be undone")

    // …and the rollback can be undone.
    _ = await s.restore(to: replaced)
    expect(read(project.appendingPathComponent("a.txt")) == "a3 (agent)\n", "undo the rollback")
    expect(await TicketGitSnapshots(folder: FileManager.default.temporaryDirectory, git: tool).snapshot("x") == nil, "not a git folder → nil")
    print("tickets_git: all passed")
    done.signal()
}
done.wait()
