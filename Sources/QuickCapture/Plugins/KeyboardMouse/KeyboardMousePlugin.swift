import AppKit
import ApplicationServices
import Combine
import SwiftUI

struct KeyboardMouseSettings: PluginSettings {
    /// Which key you hold to use WASD as a mouse (`ActivationKey` raw value).
    var activationKey = ActivationKey.rightOption.rawValue
    /// Multiplier for the top pointer speed.
    var speed = 1.0

    enum CodingKeys: String, CodingKey { case activationKey = "activation_key", speed }
}

/// Hold a key, then WASD moves the pointer, 1–6 jump to a screen panel, Space / E click.
@MainActor
final class KeyboardMousePlugin: ObservableObject, Plugin {
    nonisolated static let pluginID = "keyboard_mouse"

    let id = KeyboardMousePlugin.pluginID
    let name = "Keyboard Mouse"
    let summary = "Hold a key and use WASD to move the pointer, 1–6 to jump across the screen, Space and E to click."
    let symbol = "keyboard"
    var enabledByDefault: Bool { false }
    let actions = [
        PluginAction(id: "pause", title: "Pause / Resume Keyboard Mouse", symbol: "pause.circle", defaultShortcut: nil),
    ]

    @Published private(set) var running = false
    private var controller: KeyboardMouseController?
    private var retry: Timer?

    var settings: KeyboardMouseSettings { state.settings(KeyboardMouseSettings.self, for: id) }

    func update(_ change: (inout KeyboardMouseSettings) -> Void) throws {
        try state.updateSettings(KeyboardMouseSettings.self, for: id, change)
    }

    func defaultSettings() -> [String: JSONValue] { encodeDefaults(KeyboardMouseSettings.self) }

    func validate(_ config: AppConfig) throws {
        let s = try config.settings(KeyboardMouseSettings.self, for: id)
        guard ActivationKey(rawValue: s.activationKey) != nil else {
            throw AppError("keyboard_mouse.activation_key must be one of: \(ActivationKey.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        guard (0.3...3).contains(s.speed) else { throw AppError("keyboard_mouse.speed must be between 0.3 and 3.") }
    }

    func perform(_ action: PluginAction) {
        guard action.id == "pause", let controller else { return }
        controller.paused.toggle()
        Toast.show(controller.paused ? "Keyboard Mouse paused" : "Keyboard Mouse resumed", symbol: "keyboard")
    }

    // MARK: Lifecycle

    func activate() {
        tryStart()
        // Permissions are granted while the app runs; keep trying until the event tap is allowed.
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tryStart() }
        }
        RunLoop.main.add(timer, forMode: .common)
        retry = timer
    }

    func deactivate() {
        retry?.invalidate()
        retry = nil
        controller?.stop()
        controller = nil
        running = false
    }

    func configDidChange() { controller?.settings = settings }

    private func tryStart() {
        if running { return }
        let next = controller ?? KeyboardMouseController(settings: settings)
        if !CGPreflightListenEventAccess() { CGRequestListenEventAccess() }
        if next.start() { controller = next; running = true }
    }

    // MARK: Menu & views

    var setupIssues: [String] {
        var issues: [String] = []
        if !AXIsProcessTrusted() { issues.append("Keyboard Mouse needs Accessibility access.") }
        if !CGPreflightListenEventAccess() { issues.append("Keyboard Mouse needs Input Monitoring access.") }
        return issues
    }

    func setupView() -> AnyView? { AnyView(KeyboardMouseSetupSteps()) }
    func settingsView() -> AnyView? { AnyView(KeyboardMouseSettingsSections(plugin: self, state: state)) }
}

private struct KeyboardMouseSetupSteps: View {
    @State private var accessibility = AXIsProcessTrusted()
    @State private var input = CGPreflightListenEventAccess()
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 10) {
            StepRow(done: accessibility, symbol: "hand.raised", title: "Accessibility",
                    detail: accessibility ? "Granted." : "Needed to move the pointer and to swallow the keys you use as a mouse.") {
                if !accessibility {
                    Button("Grant Access…") {
                        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
                    }
                }
            }
            StepRow(done: input, symbol: "keyboard", title: "Input Monitoring",
                    detail: input ? "Granted — keystrokes are only used to detect the shortcut keys, never stored."
                        : "Needed to notice when you hold the activation key.") {
                if !input {
                    Button("Grant Access…") { CGRequestListenEventAccess() }
                }
            }
        }
        .onReceive(timer) { _ in
            accessibility = AXIsProcessTrusted()
            input = CGPreflightListenEventAccess()
        }
    }
}

private struct KeyboardMouseSettingsSections: View {
    @ObservedObject var plugin: KeyboardMousePlugin
    @ObservedObject var state: AppState

    var body: some View {
        let s = plugin.settings
        Section {
            Label(plugin.running ? "Keyboard Mouse is on" : "Waiting for permissions…",
                  systemImage: plugin.running ? "dot.radiowaves.left.and.right" : "hourglass")
                .foregroundStyle(plugin.running ? .green : .secondary)
        } footer: {
            Text("While holding the activation key: W A S D move the pointer (hold longer to go faster, add Shift for a boost), 1–6 jump to a panel of the screen (1 2 3 on top, 4 5 6 below), Space is the left button, E the right button. Tap a button twice for a double click; hold it and move to drag.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Options") {
            Picker("Activation key", selection: Binding(get: { ActivationKey(rawValue: s.activationKey) ?? .rightOption },
                                                        set: { v in try? plugin.update { $0.activationKey = v.rawValue } })) {
                ForEach(ActivationKey.allCases) { Text($0.title).tag($0) }
            }
            SettingSlider(title: "Top speed", range: 0.3...3, value: s.speed,
                          format: { String(format: "×%.1f", $0) },
                          live: { _ in },
                          commit: { v in try? plugin.update { $0.speed = v } })
        }
    }
}
