// Nose-tracking demo: webcam -> Vision nose landmark -> live pointer, calibrated by reaching the 4 screen edges.
// The pointer follows your nose from the start, so you always see what the tracking does.
// Keys (global): Option+Return confirm calibration step / click · Option+M toggle mouse · Option+C recalibrate
//                Option+] / Option+[ more/less sensitive · Option+Esc quit
import AppKit
import AVFoundation
import Carbon
import Vision

let controlMouseAtStart = !CommandLine.arguments.contains("--no-mouse")

// MARK: - Global hotkeys (Carbon: no extra permission needed)

var hotKeyHandler: ((UInt32) -> Void)?
var hotKeyRefs: [EventHotKeyRef?] = []

func registerHotKeys() {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
        var hk = EventHotKeyID()
        GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                          MemoryLayout<EventHotKeyID>.size, nil, &hk)
        DispatchQueue.main.async { hotKeyHandler?(hk.id) }
        return noErr
    }, 1, &spec, nil, nil)
    let keys = [(1, kVK_Return), (2, kVK_ANSI_M), (3, kVK_ANSI_C), (4, kVK_Escape),
                (5, kVK_ANSI_RightBracket), (6, kVK_ANSI_LeftBracket)]
    for (id, key) in keys {
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(key), UInt32(optionKey), EventHotKeyID(signature: 0x4E4F5345, id: UInt32(id)),
                            GetApplicationEventTarget(), 0, &ref)
        hotKeyRefs.append(ref)
    }
}

// MARK: - Filters

/// One Euro filter: heavy smoothing when still, low lag when moving fast.
struct OneEuro {
    var minCutoff: Double, beta: Double, dCutoff = 1.0
    var x: Double?, dx = 0.0
    mutating func filter(_ v: Double, dt: Double) -> Double {
        func alpha(_ c: Double) -> Double { 1 / (1 + (1 / (2 * Double.pi * c)) / dt) }
        guard let px = x else { x = v; return v }
        dx += alpha(dCutoff) * ((v - px) / dt - dx)
        let nx = px + alpha(minCutoff + beta * abs(dx)) * (v - px)
        x = nx; return nx
    }
    mutating func reset() { x = nil; dx = 0 }
}

func median(_ a: [Double]) -> Double { let s = a.sorted(); return s[s.count / 2] }

// MARK: - Camera + Vision

final class Tracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "nosetrack.camera")
    let request = VNDetectFaceLandmarksRequest()
    var onNose: (([Double]?) -> Void)?
    var history: [[Double]] = []
    var smooth: [Double]?
    var lastSeen = Date.distantPast

    func start() throws {
        session.sessionPreset = .hd1280x720
        guard let dev = AVCaptureDevice.default(for: .video) else {
            throw NSError(domain: "nosetrack", code: 1, userInfo: [NSLocalizedDescriptionKey: "no camera"])
        }
        session.addInput(try AVCaptureDeviceInput(device: dev))
        let out = AVCaptureVideoDataOutput()
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(out)
        session.startRunning()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        try? VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up).perform([request])
        guard let face = request.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }),
              let nose = face.landmarks?.nose?.normalizedPoints, !nose.isEmpty else {
            if Date().timeIntervalSince(lastSeen) > 0.3 { history = []; smooth = nil; onNose?(nil) }
            return
        }
        lastSeen = Date()
        // Nose landmark points are relative to the face box; centroid of them is steadier than any single point.
        let bb = face.boundingBox
        let cx = nose.map { Double($0.x) }.reduce(0, +) / Double(nose.count)
        let cy = nose.map { Double($0.y) }.reduce(0, +) / Double(nose.count)
        let raw = [Double(bb.minX) + cx * Double(bb.width), Double(bb.minY) + cy * Double(bb.height)]
        history.append(raw); if history.count > 5 { history.removeFirst() }
        let med = (0..<2).map { j in median(history.map { $0[j] }) }
        if let s = smooth { smooth = (0..<2).map { s[$0] + 0.5 * (med[$0] - s[$0]) } } else { smooth = med }
        onNose?(smooth)
    }
}

// MARK: - UI

/// Small mirrored camera preview with a green dot on the detected nose.
final class PreviewBox: NSView {
    let pl: AVCaptureVideoPreviewLayer
    let dot = CAShapeLayer()
    init(session: AVCaptureSession) {
        pl = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: NSRect(x: 0, y: 0, width: 256, height: 144))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = 10; layer?.masksToBounds = true
        pl.frame = bounds; pl.videoGravity = .resizeAspect
        layer?.addSublayer(pl)
        dot.path = CGPath(ellipseIn: CGRect(x: -6, y: -6, width: 12, height: 12), transform: nil)
        dot.fillColor = NSColor.systemGreen.cgColor; dot.strokeColor = NSColor.white.cgColor; dot.lineWidth = 2
        dot.isHidden = true
        layer?.addSublayer(dot)
    }
    required init?(coder: NSCoder) { fatalError() }

    func mirror() {
        pl.connection?.automaticallyAdjustsVideoMirroring = false
        pl.connection?.isVideoMirrored = true
    }
    func setNose(_ p: [Double]?) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if let p = p {
            dot.isHidden = false
            dot.position = CGPoint(x: (1 - p[0]) * bounds.width, y: p[1] * bounds.height)
        } else { dot.isHidden = true }
        CATransaction.commit()
    }
}

final class Overlay: NSView {
    override var isFlipped: Bool { true }
    var dot: CGPoint?; var dotRadius: CGFloat = 20; var dotColor = NSColor.systemRed
    var gaze: CGPoint?; var message = ""; var dim = false
    var clickAt: CGPoint?; var clickTime = Date.distantPast
    var edge: Int?; var crosshair = false   // calibration hints: 0 left 1 right 2 top 3 bottom

    override func draw(_ r: NSRect) {
        if dim { NSColor.black.withAlphaComponent(0.45).setFill(); bounds.fill() }
        if let e = edge {
            NSColor.systemYellow.setFill()
            let t: CGFloat = 16
            [NSRect(x: 0, y: 0, width: t, height: bounds.height), NSRect(x: bounds.width - t, y: 0, width: t, height: bounds.height),
             NSRect(x: 0, y: 0, width: bounds.width, height: t), NSRect(x: 0, y: bounds.height - t, width: bounds.width, height: t)][e].fill()
        }
        if crosshair {
            NSColor.systemYellow.setStroke()
            let c = NSPoint(x: bounds.midX, y: bounds.midY)
            let p = NSBezierPath(); p.lineWidth = 3
            p.move(to: NSPoint(x: c.x - 30, y: c.y)); p.line(to: NSPoint(x: c.x + 30, y: c.y))
            p.move(to: NSPoint(x: c.x, y: c.y - 30)); p.line(to: NSPoint(x: c.x, y: c.y + 30)); p.stroke()
        }
        if let d = dot {
            dotColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: d.x - dotRadius, y: d.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)).fill()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: d.x - 3, y: d.y - 3, width: 6, height: 6)).fill()
        }
        if let g = gaze {
            NSColor.systemGreen.withAlphaComponent(0.55).setFill()
            NSBezierPath(ovalIn: NSRect(x: g.x - 18, y: g.y - 18, width: 36, height: 36)).fill()
        }
        if let c = clickAt {
            let t = Date().timeIntervalSince(clickTime)
            if t < 0.35 {
                let rad = CGFloat(14 + t * 120)
                NSColor.systemOrange.withAlphaComponent(1 - t / 0.35).setStroke()
                let ring = NSBezierPath(ovalIn: NSRect(x: c.x - rad, y: c.y - rad, width: rad * 2, height: rad * 2))
                ring.lineWidth = 4; ring.stroke()
            }
        }
        let s = NSAttributedString(string: message, attributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 15, weight: .medium)])
        let sz = s.size()
        let box = NSRect(x: bounds.midX - sz.width / 2 - 14, y: 22, width: sz.width + 28, height: sz.height + 14)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10).fill()
        s.draw(at: NSPoint(x: box.minX + 14, y: box.minY + 7))
    }
}

final class Win: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class App: NSObject, NSApplicationDelegate {
    enum Phase { case finding, step(Int), tracking }
    var phase = Phase.finding
    var win: Win!; var view: Overlay!; var preview: PreviewBox!
    let tracker = Tracker()
    let lock = NSLock()
    var latest: [Double]?; var latestAt = Date.distantPast
    var controlMouse = controlMouseAtStart
    var gainX = UserDefaults.standard.object(forKey: "gainX") as? Double ?? 1.0
    var gainY = UserDefaults.standard.object(forKey: "gainY") as? Double ?? 1.0
    var panel: NSPanel!, sliderX: NSSlider!, sliderY: NSSlider!, labelX: NSTextField!, labelY: NSTextField!, mouseBox: NSButton!
    var smoothed: CGPoint?, anchor: CGPoint?
    var fx = OneEuro(minCutoff: 1.2, beta: 0.01), fy = OneEuro(minCutoff: 1.2, beta: 0.01)
    let deadZone: CGFloat = 8
    var recent: [[Double]] = []
    var center: [Double]?, extremes: [[Double]?] = [nil, nil, nil, nil]   // left, right, top, bottom
    var calibrated = false
    var seenSince: Date?
    var loop: Timer?
    var screenSize: CGSize { NSScreen.main!.frame.size }

    let stepText = [
        "1/5  Face the screen, relax, nose toward the CENTER — then press ⌥Return",
        "2/5  Turn your head LEFT, as far as is comfortable — then press ⌥Return",
        "3/5  Turn your head RIGHT, as far as is comfortable — then press ⌥Return",
        "4/5  Tilt your head UP, as far as is comfortable — then press ⌥Return",
        "5/5  Tilt your head DOWN, as far as is comfortable — then press ⌥Return",
    ]

    func applicationDidFinishLaunching(_ n: Notification) {
        let frame = NSScreen.main!.frame
        win = Win(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.level = .screenSaver; win.isOpaque = false; win.backgroundColor = .clear; win.hasShadow = false
        view = Overlay(frame: NSRect(origin: .zero, size: frame.size)); win.contentView = view
        preview = PreviewBox(session: tracker.session)
        preview.frame.origin = NSPoint(x: frame.width - 256 - 20, y: 20)   // bottom-right
        view.addSubview(preview)
        win.makeKeyAndOrderFront(nil)
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == UInt16(kVK_Escape) { NSApp.terminate(nil) }
            return e
        }
        // Posting synthetic clicks needs Accessibility; this shows the system prompt once if missing.
        if !AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) {
            print("Grant Accessibility permission so Option+Return can click, then restart the demo.")
        }
        hotKeyHandler = { [self] id in
            switch id {
            case 1: confirm()
            case 2: controlMouse.toggle(); syncPanel()
            case 3: restartCalibration()
            case 5: gainX = min(gainX * 1.15, 6); gainY = min(gainY * 1.15, 6); syncPanel()
            case 6: gainX = max(gainX / 1.15, 0.3); gainY = max(gainY / 1.15, 0.3); syncPanel()
            default: NSApp.terminate(nil)
            }
        }
        registerHotKeys()
        buildPanel()
        AVCaptureDevice.requestAccess(for: .video) { ok in
            DispatchQueue.main.async { ok ? self.begin() : self.fail("Camera access denied. Enable it in System Settings → Privacy → Camera.") }
        }
    }

    // MARK: Sensitivity panel (separate non-activating window, so it stays clickable over the overlay)
    func buildPanel() {
        let f = NSScreen.main!.frame
        panel = NSPanel(contentRect: NSRect(x: 20, y: f.height - 200, width: 280, height: 150),
                        styleMask: [.titled, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Nose pointer"; panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.hidesOnDeactivate = false
        let v = panel.contentView!
        func label(_ t: String, _ y: CGFloat) -> NSTextField {
            let l = NSTextField(labelWithString: t); l.frame = NSRect(x: 14, y: y, width: 252, height: 16); v.addSubview(l); return l
        }
        func slider(_ y: CGFloat, _ val: Double) -> NSSlider {
            let sl = NSSlider(value: val, minValue: 0.3, maxValue: 6, target: self, action: #selector(sliderMoved))
            sl.frame = NSRect(x: 14, y: y, width: 252, height: 20); sl.isContinuous = true; v.addSubview(sl); return sl
        }
        labelX = label("", 122); sliderX = slider(100, gainX)
        labelY = label("", 72); sliderY = slider(50, gainY)
        mouseBox = NSButton(checkboxWithTitle: "Control the mouse  (⌥M)", target: self, action: #selector(sliderMoved))
        mouseBox.frame = NSRect(x: 14, y: 14, width: 252, height: 20); v.addSubview(mouseBox)
        syncPanel()
        panel.orderFrontRegardless()
    }

    @objc func sliderMoved() {
        gainX = sliderX.doubleValue; gainY = sliderY.doubleValue
        controlMouse = mouseBox.state == .on
        syncPanel()
    }

    func syncPanel() {
        sliderX.doubleValue = gainX; sliderY.doubleValue = gainY
        labelX.stringValue = String(format: "Horizontal sensitivity ×%.1f", gainX)
        labelY.stringValue = String(format: "Vertical sensitivity ×%.1f", gainY)
        mouseBox.state = controlMouse ? .on : .off
        UserDefaults.standard.set(gainX, forKey: "gainX"); UserDefaults.standard.set(gainY, forKey: "gainY")
    }

    func fail(_ m: String) { view.dim = true; view.message = m; view.needsDisplay = true; print(m)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { NSApp.terminate(nil) } }

    func begin() {
        tracker.onNose = { [self] f in lock.lock(); latest = f; latestAt = Date(); lock.unlock() }
        do { try tracker.start() } catch { return fail("Camera error: \(error.localizedDescription)") }
        preview.mirror()
        restartCalibration()
        loop = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [self] _ in tick() }
    }

    func current() -> [Double]? {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(latestAt) < 0.3 ? latest : nil
    }

    func restartCalibration() {
        center = nil; extremes = [nil, nil, nil, nil]; calibrated = false; seenSince = nil
        recent = []; smoothed = nil; anchor = nil; fx.reset(); fy.reset()
        phase = .finding; view.dim = true; view.edge = nil; view.crosshair = false
        win.ignoresMouseEvents = false
    }

    func enterStep(_ i: Int) {
        phase = .step(i)
        view.edge = i == 0 ? nil : i - 1
        view.crosshair = i == 0
        view.message = stepText[i]
    }

    /// Option+Return: confirm the current calibration step, or click when tracking.
    func confirm() {
        switch phase {
        case .finding: return
        case .tracking: click()
        case .step(let i):
            guard recent.count >= 5 else { view.message = "Nose not visible — face the camera"; return }
            let med = (0..<2).map { j in median(recent.map { $0[j] }) }
            if i == 0 { center = med; return enterStep(1) }
            let axis = i <= 2 ? 0 : 1
            if abs(med[axis] - center![axis]) < 0.01 { view.message = "Too small — turn your head further, then press ⌥Return"; return }
            extremes[i - 1] = med
            if i < 4 { return enterStep(i + 1) }
            calibrated = true; phase = .tracking
            view.dim = false; view.edge = nil; view.crosshair = false; win.ignoresMouseEvents = true
            anchor = nil; fx.reset(); fy.reset()
        }
    }

    /// Left click at the pointer target (mouse control on) or at the current pointer (off).
    func click() {
        let loc = (controlMouse ? smoothed : nil) ?? CGEvent(source: nil)?.location ?? .zero
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: loc, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        view.clickAt = loc; view.clickTime = Date()
    }

    /// Nose position -> screen point. Before calibration: a default gain around the neutral pose,
    /// so the pointer already moves while you calibrate. After: your measured extremes map to the screen edges.
    func target(_ f: [Double]) -> CGPoint {
        let w = Double(screenSize.width), h = Double(screenSize.height)
        let c = center ?? f
        let d = [f[0] - c[0], f[1] - c[1]]
        let k = (w / 2) / (0.12 * 1280)               // default: 12% of the frame width = half the screen
        let provisional = [-d[0] * 1280 * k, -d[1] * 720 * k]   // mirrored: turn left -> pointer left
        var s = provisional
        if calibrated, let l = extremes[0], let r = extremes[1], let t = extremes[2], let b = extremes[3] {
            func map(_ d: Double, _ minus: Double, _ plus: Double, _ half: Double, _ fallback: Double) -> Double {
                if d * plus >= 0 { return abs(plus) > 0.004 ? d / plus * half : fallback }
                return abs(minus) > 0.004 ? -(d / minus) * half : fallback
            }
            s[0] = map(d[0], l[0] - c[0], r[0] - c[0], w / 2 * 0.98, provisional[0])
            s[1] = map(d[1], t[1] - c[1], b[1] - c[1], h / 2 * 0.98, provisional[1])
        }
        return CGPoint(x: min(max(w / 2 + s[0] * gainX, 0), w - 1), y: min(max(h / 2 + s[1] * gainY, 0), h - 1))
    }

    func tick() {
        let f = current()
        preview.setNose(f)
        if case .finding = phase {
            if f != nil {
                seenSince = seenSince ?? Date()
                let held = Date().timeIntervalSince(seenSince!)
                view.message = "Nose found ✓ (green dot in the preview) — hold still…"
                if held > 1.5 { enterStep(0) }
            } else {
                seenSince = nil
                view.message = "Looking for your nose… face the camera in good light"
            }
            view.needsDisplay = true; return
        }
        if let f = f {
            recent.append(f); if recent.count > 15 { recent.removeFirst() }
            let p = target(f)
            let q = CGPoint(x: fx.filter(Double(p.x), dt: 1.0 / 60), y: fy.filter(Double(p.y), dt: 1.0 / 60))
            // Tiny dead-zone so sensor noise never nudges a pointer you are holding still.
            if let a = anchor, hypot(q.x - a.x, q.y - a.y) <= deadZone {} else { anchor = q }
            smoothed = anchor
        }
        view.gaze = smoothed
        if case .tracking = phase {
            view.message = "Mouse \(controlMouse ? "ON" : "OFF") · ⌥Return click · ⌥M toggle · ⌥[ ] sensitivity · ⌥C recalibrate · ⌥Esc quit"
            if controlMouse, let s = smoothed { CGWarpMouseCursorPosition(s) }
        }
        view.needsDisplay = true
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = App()
app.delegate = delegate
app.activate(ignoringOtherApps: true)
app.run()
