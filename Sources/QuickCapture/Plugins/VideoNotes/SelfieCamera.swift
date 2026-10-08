import AVFoundation
import AppKit
import SwiftUI

/// The daily selfie: the first press opens a live, mirrored preview so you see yourself; the second press
/// (or Space / Return / a click) takes the photo, holds it on screen for a moment and saves it. Esc closes.
@MainActor
final class SelfieCamera: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    @Published private(set) var captured: NSImage?
    @Published private(set) var flash = false
    var isOpen: Bool { panel != nil }

    private let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private var panel: KeyPanel?
    private var destination: URL?
    private var mirror = true
    private var onSaved: ((URL) -> Void)?

    /// Opens the preview. `directory` is where the photo goes.
    func open(saveIn directory: URL, mirror: Bool, onSaved: @escaping (URL) -> Void) throws {
        guard panel == nil else { return }
        guard let camera = AVCaptureDevice.default(for: .video) else { throw AppError("No camera found on this Mac.") }
        let input = try AVCaptureDeviceInput(device: camera)
        session.beginConfiguration()
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)
        if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw AppError("Can't start the camera.")
        }
        session.addInput(input)
        session.addOutput(output)
        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirror
        }
        session.commitConfiguration()
        self.mirror = mirror
        self.onSaved = onSaved
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
        destination = directory.appendingPathComponent("Selfie \(stamp.string(from: Date())).jpg")
        captured = nil
        DispatchQueue.global(qos: .userInitiated).async { [session] in session.startRunning() }
        showPanel()
    }

    /// Second press: take the photo.
    func shoot() {
        guard panel != nil, captured == nil, session.isRunning else { return }
        let settings = output.availablePhotoCodecTypes.contains(.jpeg)
            ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            : AVCapturePhotoSettings()
        flash = true
        withAnimation(.easeOut(duration: 0.35)) { flash = false }
        output.capturePhoto(with: settings, delegate: self)
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
        captured = nil
        DispatchQueue.global(qos: .userInitiated).async { [session] in session.stopRunning() }
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = photo.fileDataRepresentation()
        Task { @MainActor in self.save(data, error: error) }
    }

    private func save(_ data: Data?, error: Error?) {
        guard let data, let destination, error == nil else {
            Toast.show(error?.localizedDescription ?? "The photo wasn't taken.", symbol: "camera", isError: true)
            close()
            return
        }
        do {
            try data.write(to: destination, options: .atomic)
            captured = NSImage(data: data)
            onSaved?(destination)
            // Show the photo for a moment, then get out of the way.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in self?.close() }
        } catch {
            Toast.show(error.localizedDescription, symbol: "camera", isError: true)
            close()
        }
    }

    private func showPanel() {
        let size = NSSize(width: 520, height: 390)
        let p = KeyPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let preview = SelfiePreviewView(session: session, size: size, mirror: mirror)
        let overlay = NSHostingView(rootView: SelfieOverlay(camera: self))
        overlay.frame = preview.bounds
        overlay.autoresizingMask = [.width, .height]
        preview.addSubview(overlay)
        p.contentView = preview
        p.onKey = { [weak self] event in
            switch event.keyCode {
            case 53: self?.close(); return true            // Esc
            case 49, 36, 76: self?.shoot(); return true    // Space, Return, Enter
            default: return false
            }
        }
        p.center()
        panel = p
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
    }
}

private final class SelfiePreviewView: NSView {
    private let previewLayer: AVCaptureVideoPreviewLayer

    init(session: AVCaptureSession, size: NSSize, mirror: Bool) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
        previewLayer.videoGravity = .resizeAspectFill
        if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirror
        }
        layer?.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }
}

private struct SelfieOverlay: View {
    @ObservedObject var camera: SelfieCamera

    var body: some View {
        ZStack {
            if let image = camera.captured {
                Image(nsImage: image).resizable().scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
            }
            Color.white.opacity(camera.flash ? 0.85 : 0)
            VStack {
                Spacer()
                Text(camera.captured == nil ? "Press the shortcut again or Space to take the photo · Esc to cancel" : "Saved")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(12)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { camera.shoot() }
    }
}
