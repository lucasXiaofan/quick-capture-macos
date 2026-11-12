import AppKit
import Combine
import SwiftUI

/// What the reading panel shows: the text (as the engine chunked it), where playback is, and what is going on.
/// The engine updates it; the buttons call back through the closures.
@MainActor
final class ReadAloudSession: ObservableObject {
    enum Status: Equatable {
        case preparing(String), reading, paused, finished, failed(String)
    }

    @Published var status: Status = .preparing("Starting…")
    @Published private(set) var chunks: [String]
    /// Chunk being spoken (-1 = none yet) and how far into it playback is (0…1).
    @Published var current = -1
    @Published var fraction = 0.0
    @Published var elapsed = 0.0
    @Published private(set) var total = 0.0
    /// Playback caught up with generation and is waiting for the next chunk.
    @Published var buffering = false

    var durations: [Int: Double] = [:]
    var onTogglePause: (() -> Void)?
    var onStop: (() -> Void)?
    var onReplay: (() -> Void)?
    var onClose: (() -> Void)?
    var onFinish: (() -> Void)?

    init(text: String = "") { chunks = text.isEmpty ? [] : [Self.tidy(text)] }

    nonisolated static func tidy(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ").split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    var isActive: Bool {
        switch status { case .finished, .failed: return false; default: return true }
    }

    func setRawText(_ text: String) { chunks = [Self.tidy(text)]; refreshTotal() }
    func setChunks(_ list: [String]) { chunks = list; refreshTotal() }
    func fail(_ message: String) { status = .failed(message); buffering = false }

    func finish() {
        guard isActive else { return }
        status = .finished
        buffering = false
        fraction = 1
        refreshTotal()
        elapsed = total
        onFinish?()
    }

    /// Known chunk lengths, plus the rest estimated from the seconds-per-character so far.
    func refreshTotal() {
        var known = 0.0, knownChars = 0, restChars = 0
        for (i, c) in chunks.enumerated() {
            if let d = durations[i] { known += d; knownChars += c.count } else { restChars += c.count }
        }
        let rate = knownChars > 0 ? known / Double(knownChars) : 0.07
        total = known + Double(restChars) * rate
    }
}

private func clock(_ s: Double) -> String {
    let n = max(0, Int(s.rounded()))
    return String(format: "%d:%02d", n / 60, n % 60)
}

struct ReadAloudPanelView: View {
    @ObservedObject var session: ReadAloudSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if case .failed(let message) = session.status {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12.5)).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                if !session.chunks.isEmpty { textArea.frame(height: 90) }
            } else {
                textArea.frame(height: 150)
                progress
                controls
            }
        }
        .padding(14)
        .frame(width: 460)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.primary.opacity(0.12)))
        )
        .padding(10)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint)
            Text("Read Aloud").font(.system(size: 13, weight: .semibold))
            Spacer()
            Text(statusText).font(.system(size: 11.5)).foregroundStyle(.secondary)
            Button { session.onClose?() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain).help("Close and stop")
        }
    }

    private var statusText: String {
        switch session.status {
        case .preparing(let s): return s
        case .reading: return session.buffering ? "Generating…" : "Reading"
        case .paused: return "Paused"
        case .finished: return "Done"
        case .failed: return "Problem"
        }
    }

    private var textArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(session.chunks.enumerated()), id: \.offset) { i, text in
                        chunkText(i, text).id(i)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(i == session.current && session.status != .finished
                                        ? Color.accentColor.opacity(0.14) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
                .font(.system(size: 13.5))
                .lineSpacing(2)
            }
            .onChange(of: session.current) { i in
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(i, anchor: .center) }
            }
        }
    }

    /// Finished chunks dimmed; the one being spoken has the words already said in the accent color.
    private func chunkText(_ i: Int, _ text: String) -> Text {
        if session.status == .finished || session.current < 0 { return Text(text) }
        if i < session.current { return Text(text).foregroundColor(.secondary) }
        if i > session.current { return Text(text) }
        var cut = Int(Double(text.count) * session.fraction)
        let chars = Array(text)
        while cut < chars.count, cut > 0, chars[cut] != " " { cut += 1 }   // finish the word
        return Text(String(chars[..<cut])).foregroundColor(.accentColor)
            + Text(String(chars[cut...]))
    }

    private var progress: some View {
        Group {
            if case .preparing = session.status {
                ProgressView().progressViewStyle(.linear)
            } else {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.primary.opacity(0.12))
                        Capsule().fill(Color.accentColor)
                            .frame(width: geo.size.width * min(1, session.elapsed / max(session.total, 0.1)))
                    }
                }
                .frame(height: 5)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Text("\(clock(session.elapsed)) / \(clock(session.total))")
                .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
            Spacer()
            if session.status == .finished {
                button("Replay", "arrow.counterclockwise") { session.onReplay?() }
            } else {
                button(session.status == .paused ? "Resume" : "Pause", session.status == .paused ? "play.fill" : "pause.fill") {
                    session.onTogglePause?()
                }
                .disabled({ if case .preparing = session.status { return true } else { return false } }())
            }
            button("Stop", "stop.fill") { session.onStop?() }
        }
    }

    private func button(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol).font(.system(size: 12)) }
            .buttonStyle(.bordered).controlSize(.small)
    }
}

/// A floating, non-activating panel (the app you are reading in keeps focus), draggable by its background.
@MainActor
final class ReadAloudPanelController {
    private var panel: NSPanel?
    private var closeTask: Task<Void, Never>?
    private var statusWatch: AnyCancellable?

    func show(_ session: ReadAloudSession) {
        close()
        let host = NSHostingView(rootView: ReadAloudPanelView(session: session))
        let size = host.fittingSize
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = host
        if let screen = OverlayPanel.screenUnderMouse {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.minY + 40))
        }
        p.orderFrontRegardless()
        panel = p
        // The failed layout is shorter: refit the panel, keeping its top edge.
        statusWatch = session.$status.dropFirst().receive(on: DispatchQueue.main).sink { [weak p, weak host] _ in
            guard let p, let host else { return }
            let fit = host.fittingSize
            var frame = p.frame
            frame.origin.y += frame.height - fit.height
            frame.size = fit
            p.setFrame(frame, display: true, animate: false)
        }
        session.onFinish = {[weak self, weak session] in self?.closeLater(session) }
    }

    func close() {
        closeTask?.cancel()
        statusWatch = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }

    /// A finished reading tidies itself away after a while.
    private func closeLater(_ session: ReadAloudSession?) {
        closeTask?.cancel()
        closeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if !Task.isCancelled, session?.status == .finished { self?.close() }
        }
    }
}
