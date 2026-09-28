import AppKit
import SwiftUI

private struct InFormKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Set inside Settings forms, where rows already have a background.
    var inForm: Bool {
        get { self[InFormKey.self] }
        set { self[InFormKey.self] = newValue }
    }
}

/// One item of a setup checklist: status icon, explanation, and an action on the right.
struct StepRow<Accessory: View>: View {
    let done: Bool
    let symbol: String
    let title: String
    let detail: String
    var optional = false
    @ViewBuilder let accessory: () -> Accessory
    @Environment(\.inForm) private var inForm

    var body: some View {
        let row = HStack(alignment: .center, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : symbol)
                .font(.system(size: 20))
                .foregroundStyle(done ? Color.green : Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.headline)
                    if optional && !done { Text("Recommended").font(.caption2).foregroundStyle(.secondary) }
                }
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            Spacer(minLength: 8)
            accessory()
        }
        if inForm {
            row.padding(.vertical, 2)
        } else {
            row.padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        }
    }
}

/// Click, then press a key combination. Esc cancels.
struct ShortcutRecorder: View {
    @ObservedObject var state: AppState
    let shortcut: Shortcut?
    let onChange: (Shortcut?) -> Void
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 4) {
            Button(action: toggle) {
                Text(recording ? "Press shortcut…" : (shortcut?.display ?? "Record shortcut"))
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .foregroundStyle(shortcut == nil && !recording ? .secondary : .primary)
                    .frame(minWidth: 130)
            }
            .buttonStyle(.bordered)
            .tint(recording ? .accentColor : nil)
            Button { onChange(nil) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .help("Remove shortcut")
                .opacity(shortcut == nil ? 0 : 1)
                .disabled(shortcut == nil)
        }
        .onDisappear(perform: stop)
    }

    private func toggle() { recording ? stop() : start() }

    private func start() {
        recording = true
        state.pauseHotkeys(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil }  // Esc
            if let s = Shortcut(event: event) { stop(); onChange(s) } else { NSSound.beep() }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { recording = false; state.pauseHotkeys(false) }
    }
}
