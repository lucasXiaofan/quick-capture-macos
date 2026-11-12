import Foundation

/// Non-destructive snapshots of a project folder, kept as git commits under `refs/quick-capture/snapshots/`.
///
/// A snapshot records the whole working tree (tracked, modified and new files; whatever .gitignore skips stays out)
/// without touching the index, the current branch, HEAD or the working tree, so it is safe next to uncommitted work.
/// Restoring brings the working tree back to a snapshot — after taking another snapshot of what it replaces, so a
/// rollback can itself be undone. Works when the folder is a sub-folder of a larger repository (paths are relative to it).
struct TicketGitSnapshots {
    let folder: URL
    let git: String
    var environment: [String: String] = ProcessInfo.processInfo.environment

    struct Change: Equatable {
        /// "A" added, "M" modified, "D" deleted — going from the first snapshot to the second.
        let status: String
        let path: String
    }

    func run(_ args: [String], index: URL? = nil) async -> Shell.Output? {
        var env = environment
        for key in ["GIT_AUTHOR_NAME", "GIT_COMMITTER_NAME"] { env[key] = "Quick Capture" }
        for key in ["GIT_AUTHOR_EMAIL", "GIT_COMMITTER_EMAIL"] { env[key] = "quick-capture@localhost" }
        env["GIT_OPTIONAL_LOCKS"] = "0"
        if let index { env["GIT_INDEX_FILE"] = index.path }
        return try? await Shell.run(git, ["-C", folder.path] + args, environment: env, timeout: 120)
    }

    /// The commit id of a new snapshot, or nil when the folder isn't a git work tree.
    func snapshot(_ label: String) async -> String? {
        let index = FileManager.default.temporaryDirectory.appendingPathComponent("qc-snapshot-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: index) }
        guard let add = await run(["add", "-A", "--", "."], index: index), add.status == 0,
              let written = await run(["write-tree"], index: index), written.status == 0 else { return nil }
        let tree = written.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        var args = ["commit-tree", tree, "-m", label]
        if let head = await run(["rev-parse", "-q", "--verify", "HEAD"]), head.status == 0 {
            args += ["-p", head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)]
        }
        guard let commit = await run(args), commit.status == 0 else { return nil }
        let id = commit.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        let stamp = Int(Date().timeIntervalSince1970)
        _ = await run(["update-ref", "refs/quick-capture/snapshots/\(stamp)-\(id.prefix(8))", id])
        return id
    }

    /// What changed between two snapshots, paths relative to the folder.
    func changes(from a: String, to b: String) async -> [Change]? {
        guard let out = await run(["diff", "--name-status", "-z", "--no-renames", "--relative", a, b]), out.status == 0 else { return nil }
        let parts = out.stdout.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var result: [Change] = []
        var i = 0
        while i + 1 < parts.count {
            result.append(Change(status: String(parts[i].prefix(1)), path: parts[i + 1]))
            i += 2
        }
        return result
    }

    /// Puts the working tree back to `target`. Returns the snapshot of what it replaced, or nil if nothing was changed.
    func restore(to target: String) async -> String? {
        guard let current = await snapshot("before restoring \(target.prefix(8))"),
              let changes = await changes(from: target, to: current) else { return nil }
        var restore: [String] = []
        for change in changes {
            if change.status == "A" {
                // Exists now, didn't in the target.
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(change.path))
            } else {
                restore.append(change.path)
            }
        }
        var start = 0
        while start < restore.count {
            let chunk = Array(restore[start..<min(start + 40, restore.count)])
            _ = await run(["restore", "--source=\(target)", "--worktree", "--"] + chunk)
            start += 40
        }
        return current
    }
}
