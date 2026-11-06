import AppKit
import SwiftUI

struct MemoryMonitorSettings: PluginSettings {
    /// Bundle ids that "Quit All" never quits. Finder and Quick Capture itself are always kept.
    var keep = ["com.apple.Terminal", "com.googlecode.iterm2", "com.apple.dt.Xcode",
                "com.microsoft.VSCode", "com.anthropic.claudefordesktop"]
    enum CodingKeys: String, CodingKey { case keep }
}

/// Live memory dashboard for local-model work: used / app / wired / compressed / cached files over time,
/// a baseline to see what loading a model cost, and one-click quitting of apps you don't need.
@MainActor
final class MemoryMonitorPlugin: ObservableObject, Plugin {
    nonisolated static let pluginID = "memory_monitor"

    let id = MemoryMonitorPlugin.pluginID
    let name = "Memory Monitor"
    let summary = "Watch RAM live (including cached files that hold mmap'd models) and quit apps you can spare."
    let symbol = "memorychip"
    var enabledByDefault: Bool { false }
    let actions = [
        PluginAction(id: "dashboard", title: "Open Memory Monitor", symbol: "memorychip", defaultShortcut: nil),
    ]

    private var window: NSWindow?
    private let sampler = MemorySampler()

    var settings: MemoryMonitorSettings { state.settings(MemoryMonitorSettings.self, for: id) }
    func update(_ change: (inout MemoryMonitorSettings) -> Void) throws {
        try state.updateSettings(MemoryMonitorSettings.self, for: id, change)
    }

    func perform(_ action: PluginAction) {
        guard action.id == "dashboard" else { return }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 820),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "Memory"
            w.minSize = NSSize(width: 620, height: 560)
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: MemoryView(plugin: self, sampler: sampler, state: state))
            w.center()
            w.setFrameAutosaveName("MemoryMonitorWindow")
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.sampler.stop() }
            }
            window = w
        }
        sampler.start()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func deactivate() {
        sampler.stop()
        window?.orderOut(nil)
        window = nil
    }

    func defaultSettings() -> [String: JSONValue] { encodeDefaults(MemoryMonitorSettings.self) }

    // MARK: Quitting

    func isKept(_ app: AppRow) -> Bool {
        app.bundleID == "com.apple.finder" || app.bundleID == Bundle.main.bundleIdentifier
            || settings.keep.contains(app.bundleID)
    }

    func setKept(_ app: AppRow, _ kept: Bool) {
        try? update { s in
            s.keep.removeAll { $0 == app.bundleID }
            if kept { s.keep.append(app.bundleID) }
        }
    }

    func quitAllUnkept() {
        let victims = sampler.apps.filter { !isKept($0) }
        guard !victims.isEmpty else { Toast.show("Nothing to quit."); return }
        let total = victims.reduce(0) { $0 + $1.footprint }
        let alert = NSAlert()
        alert.messageText = "Quit \(victims.count) apps (about \(MemoryView.gb(total)))?"
        alert.informativeText = victims.map(\.name).joined(separator: ", ")
            + "\n\nThey are asked to quit normally; unsaved work may prompt."
        alert.addButton(withTitle: "Quit Them")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        victims.forEach { $0.app.terminate() }
    }

    func terminate(_ p: ProcRow) {
        let alert = NSAlert()
        alert.messageText = "Stop \(p.name) (pid \(p.id), \(MemoryView.gb(p.footprint)))?"
        alert.informativeText = "Sends it a normal terminate signal."
        alert.addButton(withTitle: "Stop")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        kill(p.id, SIGTERM)
    }

    func settingsView() -> AnyView? { AnyView(MemoryMonitorSettingsSections(plugin: self, state: state)) }
}

private struct MemoryMonitorSettingsSections: View {
    @ObservedObject var plugin: MemoryMonitorPlugin
    @ObservedObject var state: AppState

    var body: some View {
        Section("Kept apps (Quit All skips these)") {
            Text(plugin.settings.keep.joined(separator: "\n"))
                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            Text("Tick \"Keep\" next to an app in the Memory window to change this list.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
