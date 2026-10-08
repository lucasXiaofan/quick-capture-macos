import AppKit
import SwiftUI

/// Main-thread side of a meeting recording: state for the menu, a small timer pill at the top-right of the
/// screen, and the hand-off to compression and transcription when it stops (see `AudioCapture`).
@MainActor
final class MeetingRecorder: ObservableObject {
    enum Phase { case idle, starting, recording, paused, stopping }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var hasSystemAudio = false
    /// Called once the partial file is complete (compression and transcription come next).
    var onFinish: ((AudioCapture, Error?) -> Void)?

    private var capture: AudioCapture?
    private var timer: Timer?
    private var panel: NSPanel?

    var isRecording: Bool { phase == .recording || phase == .paused }

    func start(to url: URL, microphone: Bool, systemAudio: Bool, compression: AudioCompression, indicator: Bool) async throws {
        guard phase == .idle else { return }
        phase = .starting
        do {
            let capture = try await AudioCapture.make(to: url, microphone: microphone, systemAudio: systemAudio, compression: compression)
            try await capture.start()
            self.capture = capture
            hasSystemAudio = capture.hasSystemAudio
        } catch {
            phase = .idle
            throw error
        }
        elapsed = 0
        phase = .recording
        if indicator { showPanel() }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if let self, let capture = self.capture { self.elapsed = capture.elapsed } }
        }
    }

    func togglePause() {
        switch phase {
        case .recording: capture?.pause(); phase = .paused
        case .paused: capture?.resume(); phase = .recording
        default: break
        }
    }

    func stop() {
        guard isRecording, let capture else { return }
        phase = .stopping
        Task {
            let error = await capture.stop()
            timer?.invalidate()
            timer = nil
            panel?.orderOut(nil)
            panel = nil
            self.capture = nil
            phase = .idle
            onFinish?(capture, error)
        }
    }

    private func showPanel() {
        let host = NSHostingView(rootView: MeetingIndicator(recorder: self))
        let size = host.fittingSize
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Left out of screen sharing, so it doesn't show up in the meeting you're recording.
        p.sharingType = .none
        p.contentView = host
        if let f = NSScreen.main?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: f.maxX - size.width - 12, y: f.maxY - size.height - 8))
        }
        p.orderFrontRegardless()
        panel = p
    }
}

private struct MeetingIndicator: View {
    @ObservedObject var recorder: MeetingRecorder

    var body: some View {
        let paused = recorder.phase == .paused
        HStack(spacing: 6) {
            Circle().fill(paused ? Color.orange : Color.red).frame(width: 8, height: 8)
            Image(systemName: recorder.hasSystemAudio ? "person.2.wave.2" : "mic").font(.system(size: 10, weight: .semibold))
            Text("\(paused ? "PAUSED" : "REC")  \(Transcriber.clock(recorder.elapsed))")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.black.opacity(0.6), in: Capsule())
        .fixedSize()
        .padding(2)
    }
}
