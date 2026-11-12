import AppKit

/// One change the agent made to Quick Capture's own source, and what became of it.
struct SelfUpdateRecord: Codable, Equatable {
    var id: String
    var at: String
    var ticket: Int
    /// Snapshots (see `TicketGitSnapshots`) of the source before and after the agent's run.
    var before: String
    var after: String
    var files: [String]
    /// "pending" (changed, not rebuilt yet), "building", "ok", "build_failed", "rolled_back" (the new version didn't
    /// start, so the old one was restored) or "reverted" (source put back by hand).
    var result: String
    var note: String?
}

private struct PendingUpdate: Codable {
    var id: String
    /// The process that ordered the update: a different process finding this file is the new version.
    var pid: Int32
    var backup: String
}

/// Lets the ticket agent change this app's own source, then rebuild and restart it — with a way back.
///
/// The safety net, in order:
/// 1. Before each run the project folder is snapshotted into git (`TicketGitSnapshots`), so nothing the agent
///    does — and none of your uncommitted work — can be lost, and any run can be undone.
/// 2. The agent never restarts the app (that would kill it mid-run). It asks, and this class builds with
///    `scripts/build.sh --install` from a helper script that outlives the app. A failed build leaves the running app alone.
/// 3. The installed app is copied aside first. The new version must report healthy after ten seconds; if it doesn't
///    within a minute, the helper puts the old app back and the old app then restores the source.
@MainActor
final class TicketSelfUpdate {
    private unowned let plugin: TicketsPlugin
    private(set) var records: [SelfUpdateRecord] = []
    /// From the end of an agent run until its changes are recorded, so another run can't start in between.
    private(set) var holding = false
    private(set) var rebuilding = false
    private var timer: Timer?
    private var pollUntil = Date.distantPast
    private let fm = FileManager.default
    static let installedApp = "/Applications/Quick Capture.app"

    init(plugin: TicketsPlugin) { self.plugin = plugin }

    var isBusy: Bool { holding || rebuilding }
    var dir: URL { plugin.store.root.appendingPathComponent("self-update", isDirectory: true) }
    private var recordsFile: URL { dir.appendingPathComponent("updates.jsonl") }
    private var pendingFile: URL { dir.appendingPathComponent("pending.json") }
    private var resultFile: URL { dir.appendingPathComponent("result.json") }
    private var healthyFile: URL { dir.appendingPathComponent("healthy") }
    private var logFile: URL { dir.appendingPathComponent("update.log") }

    // MARK: Where and whether

    /// The Quick Capture source: chosen in Settings, else where this build was made (recorded in Info.plist).
    var projectFolder: URL? {
        let chosen = plugin.settings.selfUpdateFolder.trimmingCharacters(in: .whitespaces)
        let path = chosen.isEmpty ? (Bundle.main.object(forInfoDictionaryKey: "QuickCaptureSourceRoot") as? String ?? "") : chosen
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
    }

    static func looksLikeProject(_ url: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: url.appendingPathComponent(".git").path)
            && fm.fileExists(atPath: url.appendingPathComponent("Package.swift").path)
            && fm.fileExists(atPath: url.appendingPathComponent("scripts/build.sh").path)
    }

    /// Why self-update can't work right now; nil when it can.
    var problem: String? {
        guard let folder = projectFolder else { return "Choose the Quick Capture source folder." }
        guard Self.looksLikeProject(folder) else {
            return "\(folder.path) isn't a Quick Capture git checkout (it needs .git, Package.swift and scripts/build.sh)."
        }
        if Bundle.main.bundlePath != Self.installedApp {
            return "Updating replaces \(Self.installedApp); run the installed app (scripts/build.sh --install)."
        }
        if plugin.settings.access == "read_only" { return "The agent needs Workspace or Full access to edit files." }
        return nil
    }

    var isActive: Bool { plugin.settings.selfUpdate && problem == nil }

    private func snapshots() async -> TicketGitSnapshots? {
        guard let folder = projectFolder,
              let git = await LoginEnvironment.shared.find("git", extraCandidates: ["/usr/bin/git", "/opt/homebrew/bin/git"]) else { return nil }
        return TicketGitSnapshots(folder: folder, git: git, environment: await LoginEnvironment.shared.environment(for: git))
    }

    // MARK: Records

    func load() {
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let decoder = JSONDecoder()
        records = ((try? String(contentsOf: recordsFile, encoding: .utf8)) ?? "").split(separator: "\n")
            .compactMap { try? decoder.decode(SelfUpdateRecord.self, from: Data($0.utf8)) }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let text = records.suffix(200).compactMap { (try? encoder.encode($0)).map { String(decoding: $0, as: UTF8.self) } }.joined(separator: "\n")
        try? (text + "\n").write(to: recordsFile, atomically: true, encoding: .utf8)
        plugin.store.onChange?()
    }

    private func setResult(_ id: String, _ result: String, note: String? = nil) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        records[i].result = result
        if let note { records[i].note = note }
        save()
    }

    private func note(_ ticket: Int, _ text: String, reopen: Bool = false) {
        plugin.store.update(ticket, touch: true) {
            $0.messages.append(TicketMessage(role: "system", text: text, at: TicketDates.now()))
            if reopen, $0.status == .closed { $0.status = .waitingHuman }
        }
    }

    // MARK: Around an agent run

    /// Called as a run starts: the snapshot to roll back to. Also blocks other runs until `afterRun`.
    func beforeRun(ticket: Int) async -> String? {
        guard isActive, let snaps = await snapshots() else { return nil }
        return await snaps.snapshot("before ticket #\(ticket)")
    }

    func hold() { holding = true }

    /// Called when a run ends: records what the agent changed in the source and, if it asked, rebuilds and restarts.
    func afterRun(ticket: Int, before: String, restart: Bool) async {
        defer { holding = false; plugin.runner.resume() }
        guard let snaps = await snapshots(), let after = await snaps.snapshot("after ticket #\(ticket)"),
              let changes = await snaps.changes(from: before, to: after) else { return }
        guard !changes.isEmpty else {
            if restart { Toast.show("Ticket #\(ticket) asked for a restart but changed no files.", symbol: "arrow.clockwise", isError: true) }
            return
        }
        let files = changes.map(\.path)
        let record = SelfUpdateRecord(id: "\(Int(Date().timeIntervalSince1970))-\(ticket)", at: TicketDates.now(), ticket: ticket,
                                      before: before, after: after, files: files, result: "pending", note: nil)
        records.append(record)
        save()
        let list = files.prefix(6).joined(separator: ", ") + (files.count > 6 ? " +\(files.count - 6) more" : "")
        plugin.store.update(ticket, touch: false) {
            $0.history.append(TicketEvent(at: TicketDates.now(), by: "agent",
                                          text: "Changed the app's source (\(files.count) file\(files.count == 1 ? "" : "s")): \(list) · rollback point \(before.prefix(8))"))
        }
        guard restart else {
            Toast.show("Ticket #\(ticket) changed Quick Capture's source. Rebuild it from Tickets → Agent → App updates.", symbol: "hammer")
            return
        }
        await rebuild(record.id)
    }

    // MARK: Rebuild and restart

    func rebuild(_ recordID: String) async {
        if let reason = problem {
            Toast.show(reason, symbol: "exclamationmark.triangle", isError: true)
            return
        }
        guard !rebuilding, let folder = projectFolder, records.contains(where: { $0.id == recordID }) else { return }
        guard plugin.runner.running.isEmpty, plugin.runner.queue.isEmpty else {
            Toast.show("Tickets are running or queued. Wait for them to finish before rebuilding.", symbol: "clock", isError: true)
            return
        }
        // Block queue pumping before opening the modal (its nested event loop can receive new tickets).
        rebuilding = true
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Rebuild and restart Quick Capture?"
        let record = records.first { $0.id == recordID }!
        alert.informativeText = "Apply the current source, including ticket #\(record.ticket)'s changes (\(record.files.count) recorded files). "
            + "The ticket queue must be empty before restarting. The installed app is backed up and restored if the new version doesn't start."
        alert.addButton(withTitle: "Rebuild & Restart")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else {
            rebuilding = false
            plugin.runner.resume()
            return
        }
        // A ticket may have arrived while the confirmation dialog was open.
        guard plugin.runner.running.isEmpty, plugin.runner.queue.isEmpty else {
            rebuilding = false
            plugin.runner.resume()
            Toast.show("A ticket arrived while confirming. Finish queued work, then try the update again.", symbol: "clock", isError: true)
            return
        }
        setResult(recordID, "building")
        let backupDir = dir.appendingPathComponent("backups/\(recordID)", isDirectory: true)
        let backup = backupDir.appendingPathComponent("Quick Capture.app")
        try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        let copy = try? await Shell.run("/usr/bin/ditto", [Self.installedApp, backup.path], timeout: 180)
        guard copy?.status == 0 else {
            rebuilding = false
            plugin.runner.resume()
            setResult(recordID, "pending", note: "Couldn't back up the installed app, so nothing was changed.")
            Toast.show("Couldn't back up the installed app; not rebuilding.", symbol: "exclamationmark.triangle", isError: true)
            return
        }
        pruneBackups(keeping: recordID)
        let pending = PendingUpdate(id: recordID, pid: ProcessInfo.processInfo.processIdentifier, backup: backup.path)
        if let data = try? JSONEncoder().encode(pending) { try? data.write(to: pendingFile, options: .atomic) }
        for file in [resultFile, healthyFile] { try? fm.removeItem(at: file) }
        let script = dir.appendingPathComponent("update.sh")
        try? Self.updateScript(dir: dir, root: folder, backup: backup).write(to: script, atomically: true, encoding: .utf8)
        try? Self.rollbackScript(backup: backup).write(to: dir.appendingPathComponent("rollback.sh"), atomically: true, encoding: .utf8)
        for name in ["update.sh", "rollback.sh"] {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent(name).path)
        }
        fm.createFile(atPath: logFile.path, contents: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [script.path]
        process.environment = await LoginEnvironment.shared.environment(for: "/usr/bin/swift")
        process.standardInput = FileHandle.nullDevice
        if let log = FileHandle(forWritingAtPath: logFile.path) { process.standardOutput = log; process.standardError = log }
        do { try process.run() } catch {
            rebuilding = false
            plugin.runner.resume()
            setResult(recordID, "pending", note: "Couldn't start the build: \(error.localizedDescription)")
            Toast.show("Couldn't start the build: \(error.localizedDescription)", symbol: "exclamationmark.triangle", isError: true)
            return
        }
        Toast.show("Rebuilding Quick Capture… it restarts when the build is done.", symbol: "hammer")
        startPolling()
    }

    private func pruneBackups(keeping id: String) {
        let root = dir.appendingPathComponent("backups", isDirectory: true)
        let all = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
        for name in all.dropLast(3) where name != id { try? fm.removeItem(at: root.appendingPathComponent(name)) }
    }

    private static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func updateScript(dir: URL, root: URL, backup: URL) -> String {
        """
        #!/bin/zsh
        # Written by Quick Capture's Tickets plugin for one app update; it keeps running after the app quits.
        # 1. build and install the new version  2. wait for it to report healthy  3. otherwise put the old app back.
        DIR=\(quote(dir.path))
        APP=\(quote(installedApp))
        BACKUP=\(quote(backup.path))
        BUNDLE_ID=\(quote(Bundle.main.bundleIdentifier ?? "com.xiaofanlu.ObsidianQuickCapture"))
        rm -f "$DIR/healthy" "$DIR/result.json"
        cd \(quote(root.path)) || { echo '{"result":"build_failed"}' > "$DIR/result.json"; exit 1; }
        echo "▸ $(date) building"
        if ! scripts/build.sh --install; then
          echo "▸ build failed; the running app was not touched"
          echo '{"result":"build_failed"}' > "$DIR/result.json"
          exit 1
        fi
        echo "▸ installed; waiting for the new version to report healthy"
        for i in {1..30}; do
          sleep 2
          if [[ -f "$DIR/healthy" ]]; then
            echo '{"result":"ok"}' > "$DIR/result.json"
            exit 0
          fi
        done
        echo "▸ the new version never reported healthy; restoring the previous app"
        osascript -e "tell application id \\"$BUNDLE_ID\\" to quit" 2>/dev/null
        pkill -x QuickCapture 2>/dev/null
        sleep 1
        rm -rf "$APP"
        ditto "$BACKUP" "$APP"
        echo '{"result":"rolled_back"}' > "$DIR/result.json"
        open "$APP"
        """
    }

    /// For when the new version is so broken that its own window can't be used to roll back.
    private static func rollbackScript(backup: URL) -> String {
        """
        #!/bin/zsh
        # Puts back the Quick Capture app that was installed before the last agent update.
        # The source is kept in git: `git -C <project> for-each-ref refs/quick-capture/snapshots/` lists the
        # snapshots, and `git -C <project> restore --source=<snapshot> --worktree -- .` restores one.
        osascript -e 'tell application id "\(Bundle.main.bundleIdentifier ?? "com.xiaofanlu.ObsidianQuickCapture")" to quit' 2>/dev/null
        pkill -x QuickCapture 2>/dev/null
        sleep 1
        rm -rf \(quote(installedApp))
        ditto \(quote(backup.path)) \(quote(installedApp)) && open \(quote(installedApp))
        """
    }

    // MARK: Results

    private func startPolling() {
        timer?.invalidate()
        pollUntil = Date().addingTimeInterval(600)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.checkResult()
                if Date() > self.pollUntil { self.timer?.invalidate(); self.timer = nil }
            }
        }
    }

    private func readPending() -> PendingUpdate? {
        (try? Data(contentsOf: pendingFile)).flatMap { try? JSONDecoder().decode(PendingUpdate.self, from: $0) }
    }

    /// Reads the helper's verdict, in the old app (a failed build) or the new one (started fine, or the old one restored).
    func checkResult() {
        guard let pending = readPending(), let data = try? Data(contentsOf: resultFile),
              let result = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["result"] as? String else { return }
        timer?.invalidate()
        timer = nil
        rebuilding = false
        defer { plugin.runner.resume() }
        for file in [resultFile, pendingFile] { try? fm.removeItem(at: file) }
        guard let record = records.first(where: { $0.id == pending.id }) else { return }
        switch result {
        case "ok":
            setResult(record.id, "ok")
            note(record.ticket, "App update: Quick Capture was rebuilt and restarted with the agent's changes (\(record.files.count) file\(record.files.count == 1 ? "" : "s")) and started fine. "
                 + "You can roll back from Tickets → Agent → App updates.")
            Toast.show("Quick Capture updated for ticket #\(record.ticket)", symbol: "checkmark.circle.fill")
        case "build_failed":
            let tail = ((try? String(contentsOf: logFile, encoding: .utf8)) ?? "").split(separator: "\n")
                .filter { $0.contains("error:") || $0.contains("Error") }.suffix(12).joined(separator: "\n")
            setResult(record.id, "build_failed", note: tail)
            note(record.ticket, "App update: the build failed, so the running app was not changed.\n\n```\n\(tail.isEmpty ? "see self-update/update.log in the ticket folder" : tail)\n```\n"
                 + "Ask the agent to fix it, or discard the changes from Tickets → Agent → App updates.", reopen: true)
            Toast.show("The app update for ticket #\(record.ticket) didn't build; the app is unchanged.", symbol: "exclamationmark.triangle", isError: true)
        case "rolled_back":
            Task {
                let kept = await snapshots()?.restore(to: record.before)
                setResult(record.id, "rolled_back", note: kept.map { "Source restored; the attempted version is snapshot \($0.prefix(8)) / \(record.after.prefix(8))." })
                note(record.ticket, "App update: the new version didn't start properly, so the previous app and its source were restored. "
                     + "The attempt is kept in git (snapshot \(record.after.prefix(8))). Nothing was lost.", reopen: true)
                Toast.show("The updated app didn't start. Restored the previous version.", symbol: "arrow.uturn.backward", isError: true)
            }
        default:
            break
        }
    }

    /// At launch. The new version proves it works by staying up; the helper script is waiting for that.
    func activate() {
        load()
        guard let pending = readPending() else { return }
        if fm.fileExists(atPath: resultFile.path) { checkResult(); return }
        if pending.pid != ProcessInfo.processInfo.processIdentifier {
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [healthyFile] in try? Data().write(to: healthyFile) }
        }
        startPolling()
    }

    func deactivate() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: From the window

    /// Puts the source back to before this update. For an update that was already built, rebuilds so the app matches.
    func rollback(_ recordID: String) async {
        guard !isBusy, plugin.runner.running.isEmpty, plugin.runner.queue.isEmpty,
              let record = records.first(where: { $0.id == recordID }) else {
            Toast.show("Wait for ticket agents and app updates to finish before rolling back.", symbol: "clock", isError: true)
            return
        }
        holding = true
        defer { holding = false; plugin.runner.resume() }
        guard let snaps = await snapshots() else { return }
        let built = record.result == "ok"
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Roll back ticket #\(record.ticket)'s app changes?"
        alert.informativeText = "\(record.files.count) file\(record.files.count == 1 ? "" : "s") go back to how they were before the agent's run. "
            + "Anything you changed since is saved in git first, so this can be undone."
            + (built ? "\n\nThen Quick Capture is rebuilt and restarted (with the same safety net)." : "")
        alert.addButton(withTitle: built ? "Roll Back & Rebuild" : "Roll Back")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let replaced = await snaps.restore(to: record.before) else {
            Toast.show("Couldn't roll back: git snapshot failed.", symbol: "exclamationmark.triangle", isError: true)
            return
        }
        setResult(recordID, "reverted", note: "Source restored; what it replaced is snapshot \(replaced.prefix(8)).")
        note(record.ticket, "App update: the agent's source changes were rolled back (snapshot \(replaced.prefix(8)) keeps what was there).")
        if built {
            let redo = SelfUpdateRecord(id: "\(Int(Date().timeIntervalSince1970))-rollback", at: TicketDates.now(), ticket: record.ticket,
                                        before: replaced, after: record.before, files: record.files, result: "pending", note: "Rollback of \(record.id)")
            records.append(redo)
            save()
            await rebuild(redo.id)
        } else {
            Toast.show("Source restored.", symbol: "arrow.uturn.backward")
        }
    }

    func rebuildFromWindow(_ recordID: String) async { await rebuild(recordID) }
}
