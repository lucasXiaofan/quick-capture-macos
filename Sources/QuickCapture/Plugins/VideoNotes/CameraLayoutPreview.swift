import AVFoundation
import AppKit
import SwiftUI

/// Settings → Media Capture → Screen + camera: the recording's frame (your main display, with its wallpaper)
/// and the camera square where the next recording puts it. Drag the square to another corner; drag its
/// handle to resize. Same geometry as `ScreenCamCapture.compose` (`Corner.rect`, side = height × size).
struct CameraLayoutPreview: View {
    @ObservedObject var plugin: VideoNotesPlugin
    @State private var dragSize: CGFloat?
    @State private var dragOffset: CGSize = .zero
    @State private var liveCamera = false

    private var aspect: CGFloat {
        let f = NSScreen.screens.first?.frame.size ?? CGSize(width: 16, height: 9)
        return f.width / max(1, f.height)
    }

    var body: some View {
        let s = plugin.settings
        let corner = ScreenCamCapture.Corner(rawValue: s.screenCameraCorner) ?? .bottomLeft
        let range = VideoNotesSettings.screenCameraSizeRange
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                let bounds = CGRect(origin: .zero, size: geo.size)
                let size = dragSize ?? CGFloat(s.screenCameraSize) / 100
                let side = (bounds.height * size).rounded()
                // Corner.rect works bottom-up; SwiftUI is top-down.
                let r = corner.rect(side: side, in: bounds)
                let rect = CGRect(x: r.minX, y: bounds.height - r.maxY, width: side, height: side)
                ZStack(alignment: .topLeading) {
                    Wallpaper().frame(width: bounds.width, height: bounds.height).clipped()
                    square(side: side)
                        .frame(width: side, height: side)
                        .offset(x: rect.minX + dragOffset.width, y: rect.minY + dragOffset.height)
                        .gesture(DragGesture()
                            .onChanged { dragOffset = $0.translation }
                            .onEnded { v in
                                let c = CGPoint(x: rect.midX + v.translation.width, y: rect.midY + v.translation.height)
                                let left = c.x < bounds.midX, top = c.y < bounds.midY
                                let new: ScreenCamCapture.Corner = top ? (left ? .topLeft : .topRight) : (left ? .bottomLeft : .bottomRight)
                                dragOffset = .zero
                                if new != corner { try? plugin.update { $0.screenCameraCorner = new.rawValue } }
                            })
                    handle
                        .position(handlePoint(rect, corner: corner))
                        .offset(dragOffset)
                        .gesture(DragGesture(coordinateSpace: .named("frame"))
                            .onChanged { v in
                                // The square grows toward the middle of the frame, from its fixed outer corner.
                                let anchor = outerPoint(rect, corner: corner)
                                let w = abs(v.location.x - anchor.x), h = abs(v.location.y - anchor.y)
                                let lo = CGFloat(range.lowerBound) / 100, hi = CGFloat(range.upperBound) / 100
                                dragSize = min(hi, max(lo, (max(w, h) / bounds.height * 100).rounded() / 100))
                            }
                            .onEnded { _ in
                                guard let d = dragSize else { return }
                                try? plugin.update { $0.screenCameraSize = Int((d * 100).rounded()) }
                                dragSize = nil
                            })
                }
                .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
                .coordinateSpace(name: "frame")
            }
            .aspectRatio(aspect, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)

            HStack {
                Toggle("Show my camera", isOn: $liveCamera).toggleStyle(.checkbox)
                Spacer()
                Text("\(Int(((dragSize ?? CGFloat(s.screenCameraSize) / 100) * 100).rounded()))% of the height · \(corner.title.lowercased())")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.callout)
        }
        .onDisappear { liveCamera = false }
    }

    @ViewBuilder private func square(side: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: side * 0.12, style: .continuous)
        ZStack {
            if liveCamera {
                CameraPreviewLayerView().clipShape(shape)
            } else {
                shape.fill(Color(white: 0.22))
                Image(systemName: "person.fill").font(.system(size: side * 0.45)).foregroundStyle(Color(white: 0.55))
            }
        }
        .overlay(shape.stroke(Color.white.opacity(0.85), lineWidth: 1.5))
        .shadow(radius: 3)
        .contentShape(shape)
        .help("Drag to another corner")
    }

    private var handle: some View {
        Circle().fill(.white).frame(width: 14, height: 14)
            .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
            .shadow(radius: 1.5)
            .contentShape(Circle().inset(by: -6))
            .help("Drag to resize")
    }

    /// The square's corner that points at the middle of the frame (where the handle sits).
    private func handlePoint(_ r: CGRect, corner: ScreenCamCapture.Corner) -> CGPoint {
        switch corner {
        case .bottomLeft: CGPoint(x: r.maxX, y: r.minY)
        case .bottomRight: CGPoint(x: r.minX, y: r.minY)
        case .topLeft: CGPoint(x: r.maxX, y: r.maxY)
        case .topRight: CGPoint(x: r.minX, y: r.maxY)
        }
    }

    /// The square's corner nearest the frame's corner; it stays put while resizing.
    private func outerPoint(_ r: CGRect, corner: ScreenCamCapture.Corner) -> CGPoint {
        switch corner {
        case .bottomLeft: CGPoint(x: r.minX, y: r.maxY)
        case .bottomRight: CGPoint(x: r.maxX, y: r.maxY)
        case .topLeft: CGPoint(x: r.minX, y: r.minY)
        case .topRight: CGPoint(x: r.maxX, y: r.minY)
        }
    }
}

/// The main display's wallpaper, standing in for the screen.
private struct Wallpaper: View {
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.25, green: 0.35, blue: 0.55), Color(red: 0.55, green: 0.4, blue: 0.6)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
        }
        .task {
            guard let screen = NSScreen.screens.first, let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return }
            image = await Task.detached(priority: .utility) { () -> NSImage? in
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                          kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1200,
                      ] as CFDictionary) else { return nil }
                return NSImage(cgImage: cg, size: .zero)
            }.value
        }
    }
}

/// A live, unmirrored camera view (the recording isn't mirrored either). Runs only while shown.
private struct CameraPreviewLayerView: NSViewRepresentable {
    final class Box: NSView {
        let session = AVCaptureSession()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            self.layer = layer
            DispatchQueue.global(qos: .userInitiated).async { [session] in
                guard let camera = AVCaptureDevice.default(for: .video),
                      let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else { return }
                session.beginConfiguration()
                if session.canSetSessionPreset(.medium) { session.sessionPreset = .medium }
                session.addInput(input)
                session.commitConfiguration()
                session.startRunning()
                DispatchQueue.main.async {
                    if let c = layer.connection, c.isVideoMirroringSupported {
                        c.automaticallyAdjustsVideoMirroring = false
                        c.isVideoMirrored = false
                    }
                }
            }
        }
        required init?(coder: NSCoder) { fatalError() }
        func stop() { DispatchQueue.global().async { [session] in session.stopRunning() } }
    }

    func makeNSView(context: Context) -> Box { Box(frame: .zero) }
    func updateNSView(_ nsView: Box, context: Context) {}
    static func dismantleNSView(_ nsView: Box, coordinator: ()) { nsView.stop() }
}
