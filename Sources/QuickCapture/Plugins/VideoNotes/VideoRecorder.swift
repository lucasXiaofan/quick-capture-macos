import AVFoundation
import AppKit
import SwiftUI

/// Records the Mac's camera (and microphone) to a file, with a small live preview at the bottom of the screen.
/// With `screen` options it records the screen with the camera in a corner instead (see `ScreenCamCapture`);
/// the preview then sits exactly where the camera square will be.
@MainActor
final class VideoRecorder: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
    enum Phase { case idle, starting, recording, paused, stopping }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var elapsed: TimeInterval = 0
    /// Called once the file is complete; the error is set when recording failed.
    var onFinish: ((URL, Error?) -> Void)?

    private let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    private var panel: NSPanel?
    private var timer: Timer?
    private var screenCam: ScreenCamCapture?
    private var url: URL?
    /// The current (or last) recording is screen + camera.
    private(set) var isScreenRecording = false

    var isRecording: Bool { phase == .recording || phase == .paused }

    func start(to url: URL, microphone: Bool, screen: ScreenCamCapture.Options? = nil) async throws {
        guard phase == .idle else { return }
        phase = .starting
        isScreenRecording = screen != nil
        self.url = url
        do {
            if let screen { screenCam = try await ScreenCamCapture.make(to: url, options: screen) }
            try configure(microphone: microphone)
        } catch {
            screenCam = nil
            phase = .idle
            throw error
        }
        showPanel()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { [session] in
                session.startRunning()
                done.resume()
            }
        }
        elapsed = 0
        if let screenCam {
            do { try await screenCam.startStream() } catch {
                self.screenCam = nil
                tearDown()
                throw error
            }
        } else {
            output.startRecording(to: url, recordingDelegate: self)
        }
        phase = .recording
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func togglePause() {
        switch phase {
        case .recording:
            if let screenCam { screenCam.pause() } else { output.pauseRecording() }
            phase = .paused
        case .paused:
            if let screenCam { screenCam.resume() } else { output.resumeRecording() }
            phase = .recording
        default: break
        }
    }

    func stop() {
        guard isRecording else { return }
        phase = .stopping
        guard let screenCam, let url else { output.stopRecording(); return }
        Task {
            let error = await screenCam.stop()
            self.screenCam = nil
            finished(url, error)
        }
    }

    private func tick() {
        let seconds = screenCam?.elapsed ?? output.recordedDuration.seconds
        if seconds.isFinite { elapsed = seconds }
    }

    private func configure(microphone: Bool) throws {
        guard let camera = AVCaptureDevice.default(for: .video) else { throw AppError("No camera found on this Mac.") }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)
        // The camera is only a small square over the screen in screen mode; 720p is plenty.
        let preset: AVCaptureSession.Preset = screenCam != nil && session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high
        if session.canSetSessionPreset(preset) { session.sessionPreset = preset }
        let video = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(video), screenCam != nil || session.canAddOutput(output) else { throw AppError("Can't start the camera.") }
        session.addInput(video)
        var micAdded = false
        if microphone, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
           let mic = AVCaptureDevice.default(for: .audio),
           let input = try? AVCaptureDeviceInput(device: mic), session.canAddInput(input) {
            session.addInput(input)
            micAdded = true
        }
        if let screenCam { try screenCam.attach(to: session, microphone: micAdded) } else { session.addOutput(output) }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection], error: Error?) {
        // AVFoundation reports an error even for files that finished fine (e.g. disk nearly full).
        let finished = (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool
        let failure = (error == nil || finished == true) ? nil : error
        Task { @MainActor in self.finished(outputFileURL, failure) }
    }

    private func finished(_ url: URL, _ error: Error?) {
        tearDown()
        onFinish?(url, error)
    }

    private func tearDown() {
        timer?.invalidate()
        timer = nil
        DispatchQueue.global(qos: .userInitiated).async { [session] in session.stopRunning() }
        panel?.orderOut(nil)
        panel = nil
        phase = .idle
    }

    // MARK: Preview

    private func showPanel() {
        var size = NSSize(width: 288, height: 162)
        var frame: NSRect?
        if let screenCam, let display = screenCam.displayFrame {
            // Over the spot the camera square takes in the video (this app's windows aren't recorded).
            let side = (display.height * screenCam.options.cameraSize).rounded()
            frame = screenCam.options.corner.rect(side: side, in: display)
            size = NSSize(width: side, height: side)
        }
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let preview = PreviewView(session: session, size: size, radius: screenCam != nil ? size.width * 0.12 : 12)
        let overlay = NSHostingView(rootView: RecorderOverlay(recorder: self))
        overlay.frame = preview.bounds
        overlay.autoresizingMask = [.width, .height]
        preview.addSubview(overlay)
        p.contentView = preview
        if let frame {
            p.setFrame(frame, display: true)
        } else if let f = NSScreen.main?.visibleFrame {
            p.setFrame(NSRect(x: f.midX - size.width / 2, y: f.minY + 16, width: size.width, height: size.height), display: true)
        }
        p.orderFrontRegardless()
        panel = p
    }
}

private final class PreviewView: NSView {
    private let previewLayer: AVCaptureVideoPreviewLayer

    init(session: AVCaptureSession, size: NSSize, radius: CGFloat) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
        previewLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }
}

private struct RecorderOverlay: View {
    @ObservedObject var recorder: VideoRecorder

    var body: some View {
        let paused = recorder.phase == .paused
        VStack {
            HStack(spacing: 6) {
                Circle().fill(paused ? Color.orange : Color.red).frame(width: 9, height: 9)
                Text("\(paused ? "PAUSED" : "REC")  \(clock(recorder.elapsed))")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
        }
    }

    private func clock(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}
