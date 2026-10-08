import AppKit
import ApplicationServices
import AVFoundation
import Combine
import SwiftUI

struct NoseSettings: PluginSettings {
    /// Pointer travel per head movement, around the calibrated range (1 = your limits reach the screen edges).
    var sensitivityX = 1.0
    var sensitivityY = 1.0
    /// 0 = most responsive, 1 = calmest.
    var steadiness = 0.6
    var showPreview = true
    /// Skip calibration on start when a saved one exists.
    var reuseCalibration = true
    /// "columns" (left | middle | right) or "rows" (top / middle / bottom).
    var panelLayout = "columns"
    /// Shortcut cheat sheet on screen while tracking.
    var showLegend = true

    enum CodingKeys: String, CodingKey {
        case sensitivityX = "sensitivity_x", sensitivityY = "sensitivity_y", steadiness
        case showPreview = "show_preview", reuseCalibration = "reuse_calibration"
        case panelLayout = "panel_layout", showLegend = "show_legend"
    }
}

/// Moves the pointer with your nose (head movement, tracked by the camera) and clicks with shortcuts.
@MainActor
final class NoseControlPlugin: ObservableObject, Plugin {
    nonisolated static let pluginID = "nose_control"

    let id = NoseControlPlugin.pluginID
    let name = "Nose Control"
    let summary = "Move the pointer by turning your head, and click with keyboard shortcuts — no mouse needed."
    let symbol = "face.dashed"
    var enabledByDefault: Bool { false }
    let actions = [
        PluginAction(id: "toggle", title: "Start / Stop Nose Control", symbol: "power", defaultShortcut: "<ctrl>+<alt>+n"),
        PluginAction(id: "left_click", title: "Left Click (select, press)", symbol: "cursorarrow.click",
                     defaultShortcut: "<alt>+<enter>", allowsBareKey: true),
        PluginAction(id: "right_click", title: "Right Click (context menu)", symbol: "cursorarrow.click.2",
                     defaultShortcut: "<alt>+<shift>+<enter>", allowsBareKey: true),
        PluginAction(id: "double_click", title: "Double Click (open)", symbol: "cursorarrow.rays",
                     defaultShortcut: "<ctrl>+<alt>+<enter>", allowsBareKey: true),
        PluginAction(id: "panel_1", title: "Jump to Panel 1", symbol: "1.square", defaultShortcut: "1", allowsBareKey: true),
        PluginAction(id: "panel_2", title: "Jump to Panel 2", symbol: "2.square", defaultShortcut: "2", allowsBareKey: true),
        PluginAction(id: "panel_3", title: "Jump to Panel 3", symbol: "3.square", defaultShortcut: "3", allowsBareKey: true),
        PluginAction(id: "whole_screen", title: "Whole Screen (leave panel)", symbol: "rectangle", defaultShortcut: nil, allowsBareKey: true),
        PluginAction(id: "pause", title: "Pause / Resume Pointer", symbol: "pause.circle", defaultShortcut: "<alt>+<space>", allowsBareKey: true),
        PluginAction(id: "sens_up", title: "Sensitivity Up", symbol: "plus.circle", defaultShortcut: "<alt>+]", allowsBareKey: true),
        PluginAction(id: "sens_down", title: "Sensitivity Down", symbol: "minus.circle", defaultShortcut: "<alt>+[", allowsBareKey: true),
        PluginAction(id: "recalibrate", title: "Recalibrate", symbol: "scope", defaultShortcut: "<ctrl>+<alt>+c", allowsBareKey: true),
    ]

    @Published private(set) var running = false
    private var session: NoseControlSession?
    private var starting = false

    var settings: NoseSettings { state.settings(NoseSettings.self, for: id) }

    func update(_ change: (inout NoseSettings) -> Void) throws {
        try state.updateSettings(NoseSettings.self, for: id, change)
    }

    func defaultSettings() -> [String: JSONValue] { encodeDefaults(NoseSettings.self) }

    func validate(_ config: AppConfig) throws {
        let s = try config.settings(NoseSettings.self, for: id)
        guard (0.3...6).contains(s.sensitivityX), (0.3...6).contains(s.sensitivityY) else {
            throw AppError("nose_control sensitivity_x / sensitivity_y must be between 0.3 and 6.")
        }
        guard ["columns", "rows"].contains(s.panelLayout) else { throw AppError("nose_control panel_layout must be \"columns\" or \"rows\".") }
        guard (0...1).contains(s.steadiness) else { throw AppError("nose_control steadiness must be between 0 and 1.") }
    }

    // MARK: Actions

    /// Everything except the on/off shortcut is only grabbed while the mode runs, so ⌥↩ keeps working in other apps otherwise.
    /// While paused, plain-key shortcuts are released (so you can type 1, 2, 3…) except the pause key itself.
    func isAvailable(_ action: PluginAction) -> Bool {
        if action.id == "toggle" { return true }
        guard running else { return false }
        if session?.paused == true, action.id != "pause",
           let shortcut = state.config.shortcut(action, of: self), !shortcut.hasRequiredModifier { return false }
        return true
    }

    func perform(_ action: PluginAction) {
        switch action.id {
        case "toggle": running ? stop() : start()
        case "left_click": session?.click(.left)
        case "right_click": session?.click(.right)
        case "double_click": session?.click(.left, count: 2)
        case "pause": session?.togglePause(); state.applyHotkeys()
        case "panel_1": session?.focusPanel(0)
        case "panel_2": session?.focusPanel(1)
        case "panel_3": session?.focusPanel(2)
        case "whole_screen": session?.focusPanel(nil)
        case "recalibrate": session?.recalibrate()
        case "sens_up": nudgeSensitivity(by: 1.15)
        case "sens_down": nudgeSensitivity(by: 1 / 1.15)
        default: break
        }
    }

    func shortcutText(_ actionID: String) -> String {
        action(actionID).flatMap { state.config.shortcut($0, of: self)?.display } ?? "(set a shortcut)"
    }

    /// The on-screen cheat sheet: which key does what.
    func legendLines() -> [String] {
        func key(_ id: String) -> String { shortcutText(id) }
        return [
            "\(key("left_click"))   left click",
            "\(key("right_click"))   right click",
            "\(key("double_click"))   double click",
            "\(key("panel_1")) \(key("panel_2")) \(key("panel_3"))   jump to panel",
            "\(key("pause"))   pause (frees plain keys)",
            "\(key("toggle"))   stop",
        ]
    }

    func start() {
        guard !running, !starting else { return }
        starting = true
        Task {
            defer { starting = false }
            guard await requestCamera() else {
                Toast.show("Nose Control needs camera access (System Settings → Privacy → Camera).", symbol: "camera", isError: true)
                return
            }
            let next = NoseControlSession(plugin: self, settings: settings)
            do { try next.start() } catch {
                Toast.show(error.localizedDescription, symbol: "camera", isError: true)
                return
            }
            session = next
            running = true
            state.applyHotkeys()
            if !AXIsProcessTrusted() {
                Toast.show("Allow Quick Capture under Accessibility so clicks work.", symbol: "hand.raised", isError: true)
                _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
            }
        }
    }

    func stop() {
        session?.stop()
        session = nil
        guard running else { return }
        running = false
        state.applyHotkeys()
    }

    private func nudgeSensitivity(by factor: Double) {
        try? update {
            $0.sensitivityX = min(max($0.sensitivityX * factor, 0.3), 6)
            $0.sensitivityY = min(max($0.sensitivityY * factor, 0.3), 6)
        }
    }

    /// Applies slider values to the running session immediately, before they are written to config.json.
    func previewSettings(_ change: (inout NoseSettings) -> Void) {
        guard let session else { return }
        change(&session.settings)
    }

    func activate() {}
    func deactivate() { stop() }
    func configDidChange() { session?.settings = settings }

    private func requestCamera() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    // MARK: Menu & views

    /// Start/Stop; the click and panel actions are only for while it runs, and live in the submenu.
    func primaryActions() -> [PluginAction] { action("toggle").map { [$0] } ?? [] }

    var setupIssues: [String] {
        var issues: [String] = []
        let camera = AVCaptureDevice.authorizationStatus(for: .video)
        if camera == .denied || camera == .restricted { issues.append("Nose Control needs camera access.") }
        if !AXIsProcessTrusted() { issues.append("Nose Control needs Accessibility access to move and click the pointer.") }
        return issues
    }

    func setupView() -> AnyView? { AnyView(NoseSetupSteps()) }
    func settingsView() -> AnyView? { AnyView(NoseSettingsSections(plugin: self, state: state)) }
}

// MARK: - Views

private struct NoseSetupSteps: View {
    @State private var camera = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var accessibility = AXIsProcessTrusted()
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 10) {
            StepRow(done: camera == .authorized, symbol: "camera", title: "Camera",
                    detail: camera == .authorized ? "Granted — video is processed on this Mac and never saved or sent."
                        : "Needed to see where your nose points.") {
                if camera != .authorized {
                    Button(camera == .notDetermined ? "Grant Access…" : "Open Settings") {
                        if camera == .notDetermined { AVCaptureDevice.requestAccess(for: .video) { _ in } }
                        else { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!) }
                    }
                }
            }
            StepRow(done: accessibility, symbol: "hand.raised", title: "Accessibility",
                    detail: accessibility ? "Granted." : "Needed to move the pointer smoothly and to click. Turn on Quick Capture in the list.") {
                if !accessibility {
                    Button("Grant Access…") {
                        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
                    }
                }
            }
        }
        .onReceive(timer) { _ in
            camera = AVCaptureDevice.authorizationStatus(for: .video)
            accessibility = AXIsProcessTrusted()
        }
    }
}

/// A slider that updates the running session while dragging and writes config.json only on release.
struct SettingSlider: View {
    let title: String
    let range: ClosedRange<Double>
    let value: Double
    let format: (Double) -> String
    let live: (Double) -> Void
    let commit: (Double) -> Void
    @State private var draft: Double?

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: Binding(get: { draft ?? value }, set: { draft = $0; live($0) }), in: range) { editing in
                    if !editing, let d = draft { commit(d); draft = nil }
                }
                Text(format(draft ?? value)).monospacedDigit().frame(width: 46, alignment: .trailing)
            }
            .frame(width: 280)
        }
    }
}

private struct NoseSettingsSections: View {
    @ObservedObject var plugin: NoseControlPlugin
    @ObservedObject var state: AppState

    var body: some View {
        let s = plugin.settings
        Section {
            HStack {
                Label(plugin.running ? "Nose control is on" : "Nose control is off",
                      systemImage: plugin.running ? "dot.radiowaves.left.and.right" : "power")
                    .foregroundStyle(plugin.running ? .green : .secondary)
                Spacer()
                Button(plugin.running ? "Stop" : "Start") { plugin.running ? plugin.stop() : plugin.start() }
            }
        } footer: {
            Text("Start with \(plugin.shortcutText("toggle")). Calibrate once: set the neutral pose, then your comfortable left, right, up and down limits — press the Left Click shortcut after each. Then press \(plugin.shortcutText("panel_1")), \(plugin.shortcutText("panel_2")) or \(plugin.shortcutText("panel_3")) to jump to a panel; your nose then moves the pointer inside it.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            SettingSlider(title: "Horizontal sensitivity", range: 0.3...6, value: s.sensitivityX,
                          format: { String(format: "×%.1f", $0) },
                          live: { v in plugin.previewSettings { $0.sensitivityX = v } },
                          commit: { v in try? plugin.update { $0.sensitivityX = v } })
            SettingSlider(title: "Vertical sensitivity", range: 0.3...6, value: s.sensitivityY,
                          format: { String(format: "×%.1f", $0) },
                          live: { v in plugin.previewSettings { $0.sensitivityY = v } },
                          commit: { v in try? plugin.update { $0.sensitivityY = v } })
            SettingSlider(title: "Steadiness", range: 0...1, value: s.steadiness,
                          format: { "\(Int($0 * 100))%" },
                          live: { v in plugin.previewSettings { $0.steadiness = v } },
                          commit: { v in try? plugin.update { $0.steadiness = v } })
        } header: {
            Text("Pointer")
        } footer: {
            Text("Higher sensitivity needs less head movement to cross the screen (×2 = half the turn). Higher steadiness removes shake when you hold still, but the pointer reacts a little slower.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Options") {
            Picker("Three panels are", selection: Binding(get: { s.panelLayout },
                set: { v in try? plugin.update { $0.panelLayout = v } })) {
                Text("Columns (left | middle | right)").tag("columns")
                Text("Rows (top / middle / bottom)").tag("rows")
            }
            Toggle("Show shortcut cheat sheet while tracking", isOn: Binding(get: { s.showLegend },
                set: { v in try? plugin.update { $0.showLegend = v } }))
            Toggle("Show camera preview while tracking", isOn: Binding(get: { s.showPreview },
                set: { v in try? plugin.update { $0.showPreview = v } }))
            Toggle("Reuse the saved calibration on start", isOn: Binding(get: { s.reuseCalibration },
                set: { v in try? plugin.update { $0.reuseCalibration = v } }))
            Button("Forget saved calibration") { NoseControlSession.forgetCalibration() }
        }
    }
}
