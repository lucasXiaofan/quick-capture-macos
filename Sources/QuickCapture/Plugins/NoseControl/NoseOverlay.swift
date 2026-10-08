import AppKit
import AVFoundation

/// Small mirrored camera preview with a green dot on the detected nose.
final class NosePreviewBox: NSView {
    private let previewLayer: AVCaptureVideoPreviewLayer
    private let dot = CAShapeLayer()

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: NSRect(x: 0, y: 0, width: 224, height: 126))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        previewLayer.frame = bounds
        previewLayer.videoGravity = .resizeAspect
        layer?.addSublayer(previewLayer)
        dot.path = CGPath(ellipseIn: CGRect(x: -6, y: -6, width: 12, height: 12), transform: nil)
        dot.fillColor = NSColor.systemGreen.cgColor
        dot.strokeColor = NSColor.white.cgColor
        dot.lineWidth = 2
        dot.isHidden = true
        layer?.addSublayer(dot)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func mirror() {
        previewLayer.connection?.automaticallyAdjustsVideoMirroring = false
        previewLayer.connection?.isVideoMirrored = true
    }

    func setNose(_ p: [Double]?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let p {
            dot.isHidden = false
            dot.position = CGPoint(x: (1 - p[0]) * bounds.width, y: p[1] * bounds.height)
        } else {
            dot.isHidden = true
        }
        CATransaction.commit()
    }
}

/// Full-screen, click-through drawing surface: calibration hints, the live pointer circle, a status line.
final class NoseOverlayView: NSView {
    override var isFlipped: Bool { true }
    var dim = false
    var pointer: CGPoint?
    var message = ""
    var edge: Int?               // calibration hint: 0 left, 1 right, 2 top, 3 bottom
    var crosshair = false
    var panelRect: CGRect?       // the panel the pointer is confined to
    var panelFlash = Date.distantPast
    var guide: [CGRect] = []     // the three panels: dividers and numbers at the jump points
    var legend: [String] = []    // shortcut cheat sheet, bottom-left
    var clickAt: CGPoint?
    var clickTime = Date.distantPast

    override func draw(_ dirtyRect: NSRect) {
        if dim { NSColor.black.withAlphaComponent(0.45).setFill(); bounds.fill() }
        if let e = edge {
            NSColor.systemYellow.setFill()
            let t: CGFloat = 16
            [NSRect(x: 0, y: 0, width: t, height: bounds.height),
             NSRect(x: bounds.width - t, y: 0, width: t, height: bounds.height),
             NSRect(x: 0, y: 0, width: bounds.width, height: t),
             NSRect(x: 0, y: bounds.height - t, width: bounds.width, height: t)][e].fill()
        }
        if crosshair {
            NSColor.systemYellow.setStroke()
            let c = NSPoint(x: bounds.midX, y: bounds.midY)
            let path = NSBezierPath()
            path.lineWidth = 3
            path.move(to: NSPoint(x: c.x - 30, y: c.y)); path.line(to: NSPoint(x: c.x + 30, y: c.y))
            path.move(to: NSPoint(x: c.x, y: c.y - 30)); path.line(to: NSPoint(x: c.x, y: c.y + 30))
            path.stroke()
        }
        if !guide.isEmpty {
            NSColor.white.withAlphaComponent(0.22).setStroke()
            let dividers = NSBezierPath()
            dividers.lineWidth = 2
            dividers.setLineDash([8, 8], count: 2, phase: 0)
            for r in guide.dropFirst() {
                if guide[0].width < bounds.width * 0.9 {   // columns: vertical dividers
                    dividers.move(to: NSPoint(x: r.minX, y: r.minY)); dividers.line(to: NSPoint(x: r.minX, y: r.maxY))
                } else {                                    // rows: horizontal dividers
                    dividers.move(to: NSPoint(x: r.minX, y: r.minY)); dividers.line(to: NSPoint(x: r.maxX, y: r.minY))
                }
            }
            dividers.stroke()
            for (i, r) in guide.enumerated() {
                let label = NSAttributedString(string: "\(i + 1)", attributes: [
                    .foregroundColor: NSColor.white.withAlphaComponent(0.3), .font: NSFont.systemFont(ofSize: 72, weight: .bold)])
                let size = label.size()
                label.draw(at: NSPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2))
            }
        }
        if let r = panelRect {
            let t = Date().timeIntervalSince(panelFlash)
            if t < 0.4 { NSColor.systemGreen.withAlphaComponent(0.18 * (1 - t / 0.4)).setFill(); r.fill() }
            NSColor.systemGreen.withAlphaComponent(0.6).setStroke()
            let outline = NSBezierPath(rect: r.insetBy(dx: 2, dy: 2))
            outline.lineWidth = 4
            outline.stroke()
        }
        if let p = pointer {
            NSColor.systemGreen.withAlphaComponent(0.55).setFill()
            NSBezierPath(ovalIn: NSRect(x: p.x - 18, y: p.y - 18, width: 36, height: 36)).fill()
        }
        if let c = clickAt {
            let t = Date().timeIntervalSince(clickTime)
            if t < 0.35 {
                let radius = CGFloat(14 + t * 120)
                NSColor.systemOrange.withAlphaComponent(1 - t / 0.35).setStroke()
                let ring = NSBezierPath(ovalIn: NSRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))
                ring.lineWidth = 4
                ring.stroke()
            }
        }
        if !legend.isEmpty {
            let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
            let text = NSAttributedString(string: legend.joined(separator: "\n"), attributes: [
                .foregroundColor: NSColor.white, .font: font,
                .paragraphStyle: { let p = NSMutableParagraphStyle(); p.lineSpacing = 4; return p }()])
            let size = text.size()
            let box = NSRect(x: 20, y: bounds.height - size.height - 34, width: size.width + 28, height: size.height + 20)
            NSColor.black.withAlphaComponent(0.72).setFill()
            NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10).fill()
            text.draw(at: NSPoint(x: box.minX + 14, y: box.minY + 10))
        }
        guard !message.isEmpty else { return }
        let text = NSAttributedString(string: message, attributes: [
            .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 15, weight: .medium)])
        let size = text.size()
        let box = NSRect(x: bounds.midX - size.width / 2 - 14, y: 22, width: size.width + 28, height: size.height + 14)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10).fill()
        text.draw(at: NSPoint(x: box.minX + 14, y: box.minY + 7))
    }
}

/// Never takes focus, so the app you are working in stays frontmost and clicks land in it.
final class NoseOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
