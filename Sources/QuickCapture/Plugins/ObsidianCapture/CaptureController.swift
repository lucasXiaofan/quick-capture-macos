import AppKit

/// Runs one capture at a time:
/// 1. Snapshot the active Obsidian note + cursor (in parallel with the screenshot selection).
/// 2. Screenshot (optional) and the note panel.
/// 3. Save at the cursor → end of note → bottom of today's diary → new diary from template.
@MainActor
final class CaptureController {
    private unowned let plugin: ObsidianCapturePlugin
    private var busy = false

    init(plugin: ObsidianCapturePlugin) { self.plugin = plugin }

    func run(_ action: CaptureAction) {
        guard !busy else { CapturePanel.bringToFront(); return }
        busy = true
        Task {
            defer { busy = false }
            do { try await perform(action) } catch {
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Capture not saved"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    private func perform(_ action: CaptureAction) async throws {
        let config = plugin.settings
        guard let vault = config.vaultURL else { plugin.openSetup(); return }
        if action.isImage && !CGPreflightScreenCaptureAccess() {
            plugin.state.refreshPermissions()
            plugin.openSetup()
            Toast.show("Screen Recording permission is needed for screenshots.", symbol: "lock", isError: true)
            return
        }
        let layout = VaultLayout(config: config, vault: vault, now: Date())
        let diaryPath = layout.diaryPath
        let id = UUID().uuidString
        let preferDiary = action.forcesDiary || config.diaryOnly
        let bridge = ObsidianBridge(config: config)

        // Snapshot the editor while the screenshot crosshair is up, so neither waits on the other.
        async let snapshot: [String: Any]? = ObsidianBridge.isRunning
            ? (try? await bridge.call("snapshot", ["id": id, "diary": preferDiary, "diary_path": diaryPath])) as? [String: Any]
            : nil

        var screenshot: URL?
        if action.isImage {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("qc-\(id).png")
            _ = try await Shell.run("/usr/sbin/screencapture", ["-i", "-x", "-o", tmp.path], timeout: 600)
            guard let size = (try? tmp.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0 else {
                try? FileManager.default.removeItem(at: tmp)
                _ = await snapshot
                return  // Escape pressed: nothing is created.
            }
            screenshot = tmp
        }
        defer { if let screenshot { try? FileManager.default.removeItem(at: screenshot) } }

        let snap = await snapshot
        let live = snap != nil
        let isNote = snap?["note"] as? Bool ?? false
        let request = CaptureRequest(
            image: screenshot.flatMap { NSImage(contentsOf: $0) },
            notePath: isNote ? snap?["path"] as? String : nil,
            noteAtCursor: snap?["cursor"] as? Bool ?? false,
            diaryPath: diaryPath,
            diaryExists: FileManager.default.fileExists(atPath: vault.appendingPathComponent(diaryPath).path),
            preferDiary: preferDiary,
            offline: !live)
        guard let result = await CapturePanel.present(request) else {
            return  // The stale snapshot is pruned by the next one; no extra CLI call (each flashes a Dock icon).
        }

        let comment = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetNote = (result.toDiary ? nil : request.notePath) ?? diaryPath
        // Every capture starts with the time it was taken (when the shortcut was pressed).
        var block = "\n**" + MomentFormat.format(layout.now, "HH:mm") + "**" + (comment.isEmpty ? "" : " " + comment) + "\n"
        if let screenshot { block += try layout.storeScreenshot(screenshot, forNote: targetNote) + "\n" }

        // Keep a copy until the save is confirmed.
        try? FileManager.default.createDirectory(at: ObsidianCapturePlugin.recovery, withIntermediateDirectories: true)
        let recovery = ObsidianCapturePlugin.recovery.appendingPathComponent("\(id).md")
        try? ("<!-- Intended destination: \(targetNote) -->\n" + block).write(to: recovery, atomically: true, encoding: .utf8)

        do {
            if live {
                let savedPath = try await saveLive(bridge: bridge, id: id, diaryPath: diaryPath,
                                                   template: layout.renderedTemplate(), text: block, toDiary: result.toDiary)
                let name = ((savedPath.path as NSString).lastPathComponent as NSString).deletingPathExtension
                Toast.show("Saved to \(name)" + (savedPath.cursor ? " at cursor" : ""))
            } else {
                try layout.appendToDiaryOnDisk(block)
                Toast.show("Saved to \(layout.diaryTitle) (Obsidian closed)")
            }
            try? FileManager.default.removeItem(at: recovery)
        } catch {
            throw AppError("\(error.localizedDescription)\n\nYour capture is preserved in:\n\(recovery.path)")
        }
    }

    private func saveLive(bridge: ObsidianBridge, id: String, diaryPath: String, template: String,
                          text: String, toDiary: Bool) async throws -> (path: String, cursor: Bool) {
        // When the note is open, `save` finishes in that same call; otherwise poll `status`.
        var reply = try await bridge.call("save", ["id": id, "diary_path": diaryPath, "template": template,
                                                   "text": text, "force_diary": toDiary]) as? [String: Any]
        for attempt in 0...15 {
            if let r = reply, r["pending"] as? Bool != true {
                if let error = r["error"] as? String { throw AppError(error) }
                return (r["path"] as? String ?? diaryPath, r["cursor"] as? Bool ?? false)
            }
            if attempt == 15 { break }
            try await Task.sleep(nanoseconds: 150_000_000)
            reply = try await bridge.call("status", ["id": id]) as? [String: Any]
        }
        throw AppError("Obsidian didn't confirm the save in time. Check the note before retrying.")
    }
}
