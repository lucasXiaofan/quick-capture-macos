import AppKit
import SwiftUI

struct StorageManagerSettings: PluginSettings {
    /// Folders searched (a few levels deep) for node_modules and Python virtualenvs. Missing ones are skipped.
    var projectRoots = StorageCatalog.defaultProjectRoots.map { "~/" + $0 }
    /// Extra folders you want listed (moved to the Trash when cleaned).
    var extraPaths: [String] = []
    /// Folders that are never cleaned, anywhere in the app.
    var protectedPaths: [String] = []
    /// Discovered items (app caches, environments) smaller than this are hidden.
    var minDiscoveredMB = 100

    enum CodingKeys: String, CodingKey {
        case projectRoots = "project_roots", extraPaths = "extra_paths", protectedPaths = "protected_paths", minDiscoveredMB = "min_discovered_mb"
    }
}

/// Disk usage dashboard: what is big, what is safe to remove, and a folder explorer. Everything is
/// found at runtime; cleaning only touches your home folder and goes to the Trash unless it is a cache.
@MainActor
final class StorageManagerPlugin: ObservableObject, Plugin {
    nonisolated static let pluginID = "storage_manager"

    let id = StorageManagerPlugin.pluginID
    let name = "Storage Manager"
    let summary = "See what fills your disk and clear caches, old environments and models safely."
    let symbol = "internaldrive"
    var enabledByDefault: Bool { false }
    let actions = [
        PluginAction(id: "dashboard", title: "Open Storage Manager", symbol: "internaldrive", defaultShortcut: nil),
    ]

    private var window: NSWindow?
    private lazy var model = StorageModel(plugin: self)

    var settings: StorageManagerSettings { state.settings(StorageManagerSettings.self, for: id) }
    func update(_ change: (inout StorageManagerSettings) -> Void) throws {
        try state.updateSettings(StorageManagerSettings.self, for: id, change)
    }

    func perform(_ action: PluginAction) {
        guard action.id == "dashboard" else { return }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 760),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "Storage"
            w.minSize = NSSize(width: 700, height: 520)
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: StorageView(model: model))
            w.center()
            w.setFrameAutosaveName("StorageManagerWindow")
            window = w
        }
        model.refreshDisk()
        if model.items.isEmpty && !model.scanning { model.scan() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func deactivate() {
        window?.orderOut(nil)
        window = nil
    }

    func defaultSettings() -> [String: JSONValue] { encodeDefaults(StorageManagerSettings.self) }

    func validate(_ config: AppConfig) throws {
        let s = try config.settings(StorageManagerSettings.self, for: id)
        if s.minDiscoveredMB < 0 { throw AppError("storage_manager.min_discovered_mb can't be negative.") }
    }

    func overviewView() -> AnyView? { AnyView(StorageOverview(plugin: self)) }
    func settingsView() -> AnyView? { AnyView(StorageSettingsSections(plugin: self, state: state)) }
}

private struct StorageOverview: View {
    let plugin: StorageManagerPlugin
    var body: some View {
        Section {
            Button("Open Storage Manager") { plugin.perform(plugin.actions[0]) }
        }
    }
}

private struct StorageSettingsSections: View {
    @ObservedObject var plugin: StorageManagerPlugin
    @ObservedObject var state: AppState

    var body: some View {
        Section("Search for environments in") {
            pathList(plugin.settings.projectRoots, empty: "No folders.") { path in try? plugin.update { $0.projectRoots.removeAll { $0 == path } } }
            Button("Add Folder…") { pick { p in try? plugin.update { $0.projectRoots.append(p) } } }
            Text("node_modules and Python virtualenvs found up to 5 levels down. Folders that don't exist are skipped.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Your folders (listed for cleaning)") {
            pathList(plugin.settings.extraPaths, empty: "None.") { path in try? plugin.update { $0.extraPaths.removeAll { $0 == path } } }
            Button("Add Folder…") { pick { p in try? plugin.update { $0.extraPaths.append(p) } } }
        }
        Section("Protected folders (never cleaned)") {
            pathList(plugin.settings.protectedPaths, empty: "None besides the built-in ones (Keychains, ~/.ssh, Photos, iCloud Drive, …).") { path in
                try? plugin.update { $0.protectedPaths.removeAll { $0 == path } }
            }
            Button("Add Folder…") { pick { p in try? plugin.update { $0.protectedPaths.append(p) } } }
        }
        Section("Discovery") {
            Stepper("Hide found items under \(plugin.settings.minDiscoveredMB) MB",
                    value: Binding(get: { plugin.settings.minDiscoveredMB }, set: { v in try? plugin.update { $0.minDiscoveredMB = v } }),
                    in: 0...2000, step: 50)
        }
    }

    @ViewBuilder
    private func pathList(_ paths: [String], empty: String, remove: @escaping (String) -> Void) -> some View {
        if paths.isEmpty {
            Text(empty).font(.caption).foregroundStyle(.secondary)
        }
        ForEach(paths, id: \.self) { p in
            HStack {
                Text(p).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button { remove(p) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
            }
        }
    }

    private func pick(_ done: (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK, let url = panel.url else { return }
        done(url.path)
    }
}
