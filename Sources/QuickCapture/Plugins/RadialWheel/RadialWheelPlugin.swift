import AppKit
import SwiftUI

struct RadialWheelSettings: PluginSettings {
    /// Slices clockwise from the top, each "<plugin id>.<action id>".
    var slots = RadialWheelSettings.defaultSlots
    /// Wheel size multiplier.
    var size = 1.0

    static let defaultSlots = [
        "video_notes.record", "video_notes.meeting", "video_notes.selfie", "video_notes.record_screen",
        "obsidian_capture.image", "obsidian_capture.text", "ai_chat.toggle", "video_notes.dashboard",
    ]
    static let slotRange = 2...12
    static let sizeRange = 0.7...1.5

    enum CodingKeys: String, CodingKey { case slots, size }
}

/// One shortcut for everything: a game-style wheel of other plugins' actions pops up at the pointer.
@MainActor
final class RadialWheelPlugin: ObservableObject, Plugin {
    nonisolated static let pluginID = "radial_wheel"

    let id = RadialWheelPlugin.pluginID
    let name = "Radial Wheel"
    let summary = "One shortcut opens a wheel of your favourite actions at the pointer: hold it, point at a slice, let go."
    let symbol = "circle.grid.cross"
    var enabledByDefault: Bool { false }
    let actions = [
        PluginAction(id: "show", title: "Show Wheel", symbol: "circle.grid.cross", defaultShortcut: "<ctrl>+<alt>+w"),
    ]

    private let wheel = RadialWheelController()

    var settings: RadialWheelSettings { state.settings(RadialWheelSettings.self, for: id) }

    func update(_ change: (inout RadialWheelSettings) -> Void) throws {
        try state.updateSettings(RadialWheelSettings.self, for: id, change)
    }

    func defaultSettings() -> [String: JSONValue] { encodeDefaults(RadialWheelSettings.self) }

    func validate(_ config: AppConfig) throws {
        let s = try config.settings(RadialWheelSettings.self, for: id)
        guard RadialWheelSettings.slotRange.contains(s.slots.count) else {
            throw AppError("radial_wheel.slots needs between \(RadialWheelSettings.slotRange.lowerBound) and \(RadialWheelSettings.slotRange.upperBound) entries.")
        }
        if let bad = s.slots.first(where: { !$0.contains(".") }) {
            throw AppError("radial_wheel.slots: “\(bad)” should look like \"<plugin id>.<action id>\", e.g. \"video_notes.record\".")
        }
        guard RadialWheelSettings.sizeRange.contains(s.size) else {
            throw AppError("radial_wheel.size must be between \(RadialWheelSettings.sizeRange.lowerBound) and \(RadialWheelSettings.sizeRange.upperBound).")
        }
    }

    func perform(_ action: PluginAction) {
        guard action.id == "show" else { return }
        if wheel.isOpen { wheel.close(); return }
        let shortcut = self.action("show").flatMap { state.config.shortcut($0, of: self) }
        wheel.open(entries: entries(), scale: settings.size, shortcut: shortcut) { [weak self] entry in self?.run(entry) }
    }

    func deactivate() { wheel.close() }

    // MARK: Slots

    func entries() -> [WheelEntry] {
        settings.slots.enumerated().map { i, ref in Self.entry(i, ref, state: state) }
    }

    static func entry(_ index: Int, _ ref: String, state: AppState) -> WheelEntry {
        let parts = ref.split(separator: ".", maxSplits: 1).map(String.init)
        let plugin = parts.first.flatMap { state.plugin($0) }
        let action = parts.count == 2 ? plugin?.action(parts[1]) : nil
        let ready = plugin.map { p in action.map { state.config.isEnabled(p) && p.isAvailable($0) } ?? false } ?? false
        let subtitle = plugin.map { p in !state.config.isEnabled(p) ? "\(p.name) is off" : ready ? p.name : "\(p.name) · not now" } ?? ref
        return WheelEntry(id: index, ref: ref, plugin: plugin, action: action, ready: ready, subtitle: subtitle)
    }

    /// Every action another plugin offers, for the slot pickers.
    var choices: [(plugin: Plugin, action: PluginAction)] {
        state.plugins.filter { $0.id != id }.flatMap { p in p.actions.map { (p, $0) } }
    }

    private func run(_ entry: WheelEntry) {
        guard let plugin = entry.plugin, let action = entry.action else {
            Toast.show("“\(entry.ref)” isn't an action this version knows. Pick another in Radial Wheel settings.",
                       symbol: "questionmark.circle", isError: true)
            return
        }
        guard state.config.isEnabled(plugin) else {
            Toast.show("Turn on \(plugin.name) in Settings to use “\(action.shortTitle)”.", symbol: "power", isError: true)
            return
        }
        guard plugin.isAvailable(action) else {
            Toast.show("“\(action.shortTitle)” isn't available right now.", symbol: "nosign", isError: true)
            return
        }
        plugin.perform(action)
    }

    func settingsView() -> AnyView? { AnyView(RadialWheelSettingsSections(plugin: self, state: state)) }
}

private struct RadialWheelSettingsSections: View {
    @ObservedObject var plugin: RadialWheelPlugin
    @ObservedObject var state: AppState

    var body: some View {
        let s = plugin.settings
        Section {
            HStack {
                Spacer()
                WheelFace(model: WheelModel(entries: plugin.entries(), radius: 120, center: .zero), interactive: false)
                    .frame(width: 300, height: 300)
                    .background(Circle().fill(Color.black.opacity(0.85)).frame(width: 300, height: 300))
                Spacer()
            }
            .padding(.vertical, 6)
        } footer: {
            Text("Hold the shortcut, point toward a slice and let go. Or tap the shortcut, then click a slice or press its number (1–9, 0 for the 10th). Pressing the shortcut again, Esc or a click in the middle cancels. Dimmed slices belong to plugins that are switched off.")
                .font(.caption).foregroundStyle(.secondary)
        }

        Section {
            ForEach(Array(s.slots.enumerated()), id: \.offset) { index, ref in
                SlotRow(plugin: plugin, index: index, ref: ref, count: s.slots.count)
            }
            HStack {
                Button { try? plugin.update { $0.slots.append(plugin.choices.first.map { "\($0.plugin.id).\($0.action.id)" } ?? "") } } label: {
                    Label("Add Slice", systemImage: "plus")
                }
                .disabled(s.slots.count >= RadialWheelSettings.slotRange.upperBound)
                Spacer()
                Button("Reset to Defaults") { try? plugin.update { $0.slots = RadialWheelSettings.defaultSlots } }
                    .disabled(s.slots == RadialWheelSettings.defaultSlots)
            }
        } header: {
            Text("Slices (clockwise from the top)")
        }

        Section("Look") {
            SettingSlider(title: "Size", range: RadialWheelSettings.sizeRange, value: s.size,
                          format: { String(format: "×%.1f", $0) },
                          live: { _ in },
                          commit: { v in try? plugin.update { $0.size = (v * 10).rounded() / 10 } })
        }
    }
}

private struct SlotRow: View {
    @ObservedObject var plugin: RadialWheelPlugin
    let index: Int
    let ref: String
    let count: Int

    var body: some View {
        let entry = RadialWheelPlugin.entry(index, ref, state: plugin.state)
        HStack(spacing: 8) {
            Text(index < 10 ? "\(index == 9 ? 0 : index + 1)" : "·")
                .font(.system(.caption, design: .monospaced).weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Image(systemName: entry.symbol).frame(width: 18).foregroundStyle(entry.ready ? Color.accentColor : .secondary)
            Picker("", selection: Binding(get: { ref }, set: { v in try? plugin.update { $0.slots[index] = v } })) {
                if entry.action == nil { Text("Missing: \(ref)").tag(ref) }
                ForEach(plugin.state.plugins.filter { $0.id != plugin.id }, id: \.id) { p in
                    Section(p.name + (plugin.state.config.isEnabled(p) ? "" : " (off)")) {
                        ForEach(p.actions) { a in
                            Label(a.title, systemImage: a.symbol).tag("\(p.id).\(a.id)")
                        }
                    }
                }
            }
            .labelsHidden()
            Button { move(-1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless).disabled(index == 0)
            Button { move(1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless).disabled(index == count - 1)
            Button { try? plugin.update { $0.slots.remove(at: index) } } label: { Image(systemName: "minus.circle.fill") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .disabled(count <= RadialWheelSettings.slotRange.lowerBound)
                .help("Remove this slice")
        }
    }

    private func move(_ by: Int) {
        try? plugin.update { s in
            let to = index + by
            guard s.slots.indices.contains(to) else { return }
            s.slots.swapAt(index, to)
        }
    }
}
