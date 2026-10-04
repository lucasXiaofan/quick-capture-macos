import AppKit
import SwiftUI

struct CaptureRequest {
    var image: NSImage?
    var notePath: String?      // Active Markdown note, if any
    var noteAtCursor: Bool
    var diaryPath: String
    var diaryExists: Bool
    var preferDiary: Bool
    var offline: Bool          // Obsidian closed / CLI unavailable → writes the diary file directly
}

struct CaptureResult {
    var text: String
    var toDiary: Bool
}

/// The floating "add a note" window shown after a screenshot or for a text capture.
@MainActor
final class CapturePanel: NSObject, NSWindowDelegate {
    private static var current: CapturePanel?
    private var panel: NSPanel!
    private var continuation: CheckedContinuation<CaptureResult?, Never>?

    static func present(_ request: CaptureRequest) async -> CaptureResult? {
        current?.finish(nil)
        let controller = CapturePanel()
        current = controller
        return await withCheckedContinuation { cont in
            controller.continuation = cont
            controller.show(request)
        }
    }

    /// Re-shows an open panel (e.g. the hotkey pressed again after clicking away).
    static func bringToFront() {
        guard let panel = current?.panel else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func show(_ request: CaptureRequest) {
        let view = CaptureView(request: request, onDone: { [weak self] in self?.finish($0) })
        let host = NSHostingView(rootView: view)
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
                        styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false  // NSPanel default hides it when another app is clicked
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        panel.delegate = self
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func finish(_ result: CaptureResult?) {
        guard let cont = continuation else { return }
        continuation = nil
        panel?.delegate = nil
        panel?.close()
        if CapturePanel.current === self { CapturePanel.current = nil }
        cont.resume(returning: result)
    }

    func windowWillClose(_ notification: Notification) { finish(nil) }
}

private struct CaptureView: View {
    let request: CaptureRequest
    let onDone: (CaptureResult?) -> Void
    @State private var text = ""
    @State private var toDiary: Bool
    @FocusState private var focused: Bool

    init(request: CaptureRequest, onDone: @escaping (CaptureResult?) -> Void) {
        self.request = request
        self.onDone = onDone
        _toDiary = State(initialValue: request.preferDiary || request.notePath == nil)
    }

    private var canSave: Bool { request.image != nil || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: request.image == nil ? "square.and.pencil" : "camera.viewfinder")
                    .foregroundStyle(.tint)
                Text(request.image == nil ? "Quick Note" : "Screenshot").font(.headline)
                Spacer()
            }
            .padding(.top, 6)

            if let image = request.image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 220)
                    .background(Color(nsColor: .underPageBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .padding(6)
                if text.isEmpty {
                    Text(request.image == nil ? "Write a note…" : "Add a comment (optional)…")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: request.image == nil ? 130 : 80)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))

            destination

            HStack {
                Text("⌘↩ to save · esc to cancel").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { onDone(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onDone(CaptureResult(text: text, toDiary: toDiary)) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
        }
        .padding(16)
        .frame(width: 520)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    @ViewBuilder private var destination: some View {
        let diaryName = (request.diaryPath as NSString).lastPathComponent
        let diaryLabel = "Today's diary · " + diaryName + (request.diaryExists ? "" : " (new)")
        HStack(spacing: 8) {
            Text("Save to").foregroundStyle(.secondary)
            if let note = request.notePath {
                Picker("", selection: $toDiary) {
                    Label(((note as NSString).lastPathComponent as NSString).deletingPathExtension
                          + (request.noteAtCursor ? " · at cursor" : " · at end"),
                          systemImage: "doc.text").tag(false)
                    Label(diaryLabel, systemImage: "calendar").tag(true)
                }
                .labelsHidden()
                .fixedSize()
            } else {
                Label(diaryLabel + " · at end", systemImage: "calendar")
            }
            Spacer()
        }
        .font(.callout)
        if request.offline {
            Label("Obsidian is closed, so this is written straight to the diary file.", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
