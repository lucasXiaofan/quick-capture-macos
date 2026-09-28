import AppKit
import SwiftUI

/// Which Settings page is showing: "general" or a plugin id.
@MainActor
final class SettingsRouter: ObservableObject {
    @Published var page: String? = "general"
}

struct SettingsView: View {
    @ObservedObject var state: AppState
    @ObservedObject var router: SettingsRouter

    var body: some View {
        NavigationSplitView {
            List(selection: $router.page) {
                Label("General", systemImage: "gearshape").tag("general")
                Section("Plugins") {
                    ForEach(state.plugins, id: \.id) { plugin in
                        Label(plugin.name, systemImage: plugin.symbol)
                            .foregroundStyle(state.config.isEnabled(plugin) ? .primary : .secondary)
                            .tag(plugin.id)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 190, max: 240)
        } detail: {
            if let id = router.page, let plugin = state.plugin(id) {
                PluginPage(plugin: plugin, state: state).id(id)
            } else {
                GeneralPage(state: state, router: router)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}

private struct GeneralPage: View {
    @ObservedObject var state: AppState
    @ObservedObject var router: SettingsRouter
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: Binding(get: { state.loginEnabled }, set: { state.setLogin($0) }))
                LabeledContent("Configuration") {
                    Button("Reveal config.json") { NSWorkspace.shared.activateFileViewerSelecting([Paths.config]) }
                }
            } footer: {
                Text("Every setting lives in config.json. Edits made in a text editor apply within a second.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Plugins") {
                ForEach(state.plugins, id: \.id) { plugin in
                    HStack(spacing: 12) {
                        Image(systemName: plugin.symbol).foregroundStyle(.tint).frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Button(plugin.name) { router.page = plugin.id }.buttonStyle(.link)
                            Text(plugin.summary).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Toggle("", isOn: enabledBinding(plugin)).toggleStyle(.switch).labelsHidden()
                    }
                }
            }
            IssueList(state: state, extra: error)
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }

    private func enabledBinding(_ plugin: Plugin) -> Binding<Bool> {
        Binding(get: { state.config.isEnabled(plugin) }, set: { on in
            do { try state.setEnabled(on, plugin: plugin); error = nil } catch { self.error = error.localizedDescription }
        })
    }
}

/// The standard page for a plugin: on/off, setup, shortcuts, then the plugin's own settings.
struct PluginPage: View {
    let plugin: Plugin
    @ObservedObject var state: AppState
    @State private var error: String?

    var body: some View {
        let enabled = state.config.isEnabled(plugin)
        Form {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: plugin.symbol).font(.system(size: 24)).foregroundStyle(.tint).frame(width: 32)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(plugin.name).font(.title3.bold())
                        Text(plugin.summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("Enabled", isOn: Binding(get: { enabled }, set: { on in
                        do { try state.setEnabled(on, plugin: plugin); error = nil }
                        catch { self.error = error.localizedDescription }
                    }))
                    .toggleStyle(.switch).labelsHidden()
                }
                if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
            if enabled {
                if let setup = plugin.setupView() {
                    Section("Setup") { setup.environment(\.inForm, true) }
                }
                if !plugin.actions.isEmpty { shortcuts }
                if let settings = plugin.settingsView() { settings }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(plugin.name)
    }

    @ViewBuilder private var shortcuts: some View {
        Section {
            ForEach(plugin.actions) { action in
                LabeledContent {
                    ShortcutRecorder(state: state, shortcut: state.config.shortcut(action, of: plugin)) { new in
                        apply { $0.setShortcut(new, for: action, of: plugin) }
                    }
                } label: {
                    Label(action.title, systemImage: action.symbol)
                }
            }
            ForEach(state.hotkeyWarnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            Button("Restore Default Shortcuts") { apply { $0.resetShortcuts(of: plugin) } }
        } header: {
            Text("Shortcuts")
        } footer: {
            Text("Click a shortcut, then press the new key combination. Shortcuts work system-wide.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func apply(_ change: (inout AppConfig) -> Void) {
        do { try state.update(change); error = nil } catch { self.error = error.localizedDescription }
    }
}

struct IssueList: View {
    @ObservedObject var state: AppState
    var extra: String?

    var body: some View {
        let issues = (extra.map { [$0] } ?? []) + state.setupIssues
        if !issues.isEmpty {
            Section("Needs attention") {
                ForEach(issues, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
        }
    }
}

// MARK: - Onboarding

struct OnboardingView: View {
    @ObservedObject var state: AppState
    let onFinish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to Quick Capture").font(.title2.bold())
                    Text("Global shortcuts for capturing into Obsidian and chatting with AI. Turn on the features you want.")
                        .foregroundStyle(.secondary)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(state.plugins, id: \.id) { plugin in
                        PluginIntro(plugin: plugin, state: state)
                    }
                    StepRow(done: state.loginEnabled, symbol: "power", title: "Open at login",
                            detail: "Start Quick Capture automatically when you log in.", optional: true) {
                        Toggle("", isOn: Binding(get: { state.loginEnabled }, set: { state.setLogin($0) }))
                            .toggleStyle(.switch).labelsHidden()
                    }
                }
            }
            .frame(maxHeight: 520)
            HStack {
                Text("You can change all of this later from the menu bar icon → Settings.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Get Started") { onFinish() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!state.enabledPlugins.allSatisfy(\.isReady))
            }
        }
        .padding(24)
        .frame(width: 640)
    }
}

private struct PluginIntro: View {
    let plugin: Plugin
    @ObservedObject var state: AppState

    var body: some View {
        let enabled = state.config.isEnabled(plugin)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: plugin.symbol).font(.system(size: 18)).foregroundStyle(.tint).frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(plugin.name).font(.headline)
                    Text(plugin.summary).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if enabled {
                        Text(plugin.actions.compactMap { a in state.config.shortcut(a, of: plugin).map { "\($0.display)  \(a.title)" } }
                            .joined(separator: "\n"))
                            .font(.system(.caption, design: .rounded)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Toggle("", isOn: Binding(get: { enabled }, set: { try? state.setEnabled($0, plugin: plugin) }))
                    .toggleStyle(.switch).labelsHidden()
            }
            if enabled, let setup = plugin.setupView() { setup }
        }
    }
}

// MARK: - Window management

@MainActor
final class Windows {
    private var settings: NSWindow?
    private var onboarding: NSWindow?
    private let router = SettingsRouter()

    func showSettings(state: AppState, page: String? = nil) {
        if let page { router.page = page }
        let window = settings ?? makeWindow(title: "Quick Capture Settings", view: SettingsView(state: state, router: router),
                                            resizable: true)
        settings = window
        present(window)
    }

    func showOnboarding(state: AppState) {
        let window = onboarding ?? makeWindow(title: "Welcome", view: OnboardingView(state: state) { [weak self] in
            UserDefaults.standard.set(true, forKey: "onboarded")
            self?.onboarding?.close()
            Toast.show("Ready — use your shortcuts from any app", symbol: "checkmark.circle.fill")
        })
        onboarding = window
        present(window)
    }

    var isOnboardingVisible: Bool { onboarding?.isVisible ?? false }

    private func makeWindow<V: View>(title: String, view: V, resizable: Bool = false) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = title
        window.styleMask = resizable ? [.titled, .closable, .miniaturizable, .resizable] : [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    private func present(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
