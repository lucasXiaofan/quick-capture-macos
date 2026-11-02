import AppKit
import SwiftUI

struct TaskLogSettings: PluginSettings {
    var folder = ""

    var folderURL: URL? {
        folder.isEmpty ? nil : URL(fileURLWithPath: (folder as NSString).expandingTildeInPath).standardizedFileURL
    }
}

/// Screenshot or text capture appended to a plain daily log file: <folder>/YYYY-MM-DD.md, images in <folder>/images/.
/// No Obsidian needed; an agent (e.g. skill-flywheel's project-manager sync) reads the file later.
@MainActor
final class TaskLogPlugin: ObservableObject, Plugin {
    nonisolated static let pluginID = "task_log"

    let id = TaskLogPlugin.pluginID
    let name = "Task Log"
    let summary = "Screenshot or jot a note into today's task log, a plain Markdown file an agent turns into task updates."
    let symbol = "checklist"
    var enabledByDefault: Bool { false }
    let actions = [
        PluginAction(id: "image", title: "Screenshot → Task Log", symbol: "camera.viewfinder", defaultShortcut: nil),
        PluginAction(id: "text", title: "Note → Task Log", symbol: "square.and.pencil", defaultShortcut: nil),
    ]

    private var busy = false

    var settings: TaskLogSettings { state.settings(TaskLogSettings.self, for: id) }

    func update(_ change: (inout TaskLogSettings) -> Void) throws {
        try state.updateSettings(TaskLogSettings.self, for: id, change)
    }

    func defaultSettings() -> [String: JSONValue] { encodeDefaults(TaskLogSettings.self) }

    var isReady: Bool { settings.folderURL != nil }

    var setupIssues: [String] {
        var issues: [String] = []
        if settings.folderURL == nil { issues.append("Choose the task log folder.") }
        if !state.screenGranted { issues.append("Screen Recording permission is needed for screenshots.") }
        return issues
    }

    func perform(_ action: PluginAction) {
        guard !busy else { CapturePanel.bringToFront(); return }
        busy = true
        Task {
            defer { busy = false }
            do { try await capture(image: action.id == "image") } catch {
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Task log not saved"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    func menuItems() -> [NSMenuItem] {
        let open = ClosureMenuItem("Open Today's Task Log") { [weak self] in self?.openToday() }
        open.isEnabled = isReady
        return [open]
    }

    private func todayFile(_ now: Date) -> URL? {
        settings.folderURL?.appendingPathComponent(MomentFormat.format(now, "YYYY-MM-DD") + ".md")
    }

    private func openToday() {
        guard let file = todayFile(Date()) else { return }
        if FileManager.default.fileExists(atPath: file.path) { NSWorkspace.shared.open(file) }
        else { Toast.show("No task log yet today — it's created on your first capture.", symbol: "calendar") }
    }

    private func capture(image: Bool) async throws {
        let now = Date()
        guard let folder = settings.folderURL, let file = todayFile(now) else { state.showSettings?(id); return }
        if image && !CGPreflightScreenCaptureAccess() {
            state.refreshPermissions()
            state.showSettings?(id)
            Toast.show("Screen Recording permission is needed for screenshots.", symbol: "lock", isError: true)
            return
        }
        var shot: URL?
        if image {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("qc-tasklog-\(UUID().uuidString).png")
            _ = try await Shell.run("/usr/sbin/screencapture", ["-i", "-x", "-o", tmp.path], timeout: 600)
            guard let size = (try? tmp.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0 else {
                try? FileManager.default.removeItem(at: tmp)
                return  // Escape pressed: nothing is created.
            }
            shot = tmp
        }
        defer { if let shot { try? FileManager.default.removeItem(at: shot) } }

        let request = CaptureRequest(image: shot.flatMap { NSImage(contentsOf: $0) }, notePath: nil, noteAtCursor: false,
                                     diaryPath: file.path, diaryExists: true, preferDiary: true, offline: false,
                                     label: "Task log · " + file.lastPathComponent
                                         + (FileManager.default.fileExists(atPath: file.path) ? "" : " (new)"))
        guard let result = await CapturePanel.present(request) else { return }

        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let comment = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var block = "\n**" + MomentFormat.format(now, "HH:mm") + "**" + (comment.isEmpty ? "" : " " + comment) + "\n"
        if let shot {
            let images = folder.appendingPathComponent("images", isDirectory: true)
            try fm.createDirectory(at: images, withIntermediateDirectories: true)
            let stamp = MomentFormat.format(now, "YYYYMMDD-HHmmss")
            var name = "\(stamp).png", n = 2
            while fm.fileExists(atPath: images.appendingPathComponent(name).path) { name = "\(stamp)-\(n).png"; n += 1 }
            try fm.moveItem(at: shot, to: images.appendingPathComponent(name))
            block += "![](images/\(name))\n"
        }
        let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let head = existing.isEmpty ? "# " + MomentFormat.format(now, "YYYY-MM-DD") + " task log\n" : existing
        try (head + block).write(to: file, atomically: true, encoding: .utf8)
        Toast.show("Saved to task log " + file.deletingPathExtension().lastPathComponent)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.message = "Choose the folder for daily task logs (one YYYY-MM-DD.md per day)."
        panel.prompt = "Use This Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.folderURL ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? update { $0.folder = url.path }
    }

    func setupView() -> AnyView? { AnyView(TaskLogSetup(plugin: self, state: state)) }
    func settingsView() -> AnyView? { AnyView(Section("Task log") { TaskLogSetup(plugin: self, state: state) }) }
}

private struct TaskLogSetup: View {
    @ObservedObject var plugin: TaskLogPlugin
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 10) {
            StepRow(done: plugin.isReady, symbol: "folder", title: "Task log folder",
                    detail: plugin.settings.folderURL?.path ?? "Where YYYY-MM-DD.md logs and their images/ are written.") {
                Button(plugin.isReady ? "Change…" : "Choose Folder…") { plugin.chooseFolder() }
            }
            StepRow(done: state.screenGranted, symbol: "rectangle.dashed.badge.record", title: "Screen Recording",
                    detail: state.screenGranted ? "Granted — only the region you select is captured."
                        : "Needed for screenshots (shared with Obsidian Capture).") {
                if !state.screenGranted { Button("Grant Access…") { state.requestScreenRecording() } }
            }
        }
    }
}
