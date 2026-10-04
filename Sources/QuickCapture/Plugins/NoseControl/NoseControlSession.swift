import AppKit
import ApplicationServices

/// Where the nose sat at the neutral pose and at the four comfortable limits.
struct NoseCalibration: Codable, Equatable {
    var center: [Double]
    var extremes: [[Double]]   // left, right, top, bottom
}

/// One run of nose control: camera, overlay, calibration, pointer and clicks.
/// Created when the mode starts and thrown away when it stops.
@MainActor
final class NoseControlSession {
    enum Phase: Equatable { case finding, step(Int), tracking }

    private(set) var phase = Phase.finding
    private(set) var paused = false
    var settings: NoseSettings

    private unowned let plugin: NoseControlPlugin
    private let tracker = NoseTracker()
    private var panel: NoseOverlayPanel?
    private var view: NoseOverlayView?
    private var preview: NosePreviewBox?
    private var loop: Timer?

    private var recent: [[Double]] = []
    private var calibration: NoseCalibration?
    private var captured: [[Double]] = []
    private var seenSince: Date?

    private var filterX = OneEuro(minCutoff: 0.4, beta: 0.004)
    private var filterY = OneEuro(minCutoff: 0.4, beta: 0.004)
    private var anchor: CGPoint?
    private var trusted = AXIsProcessTrusted()
    private var trustCheckedAt = Date()

    private static let calibrationFile = Paths.data(for: NoseControlPlugin.pluginID).appendingPathComponent("calibration.json")

    init(plugin: NoseControlPlugin, settings: NoseSettings) {
        self.plugin = plugin
        self.settings = settings
    }

    /// The primary display: its frame matches the global coordinates used to move the pointer.
    private var screen: NSScreen { NSScreen.screens.first ?? NSScreen.main! }

    // MARK: Lifecycle

    func start() throws {
        try tracker.start()
        let frame = screen.frame
        let overlay = NoseOverlayView(frame: NSRect(origin: .zero, size: frame.size))
        let preview = NosePreviewBox(session: tracker.session)
        preview.frame.origin = NSPoint(x: frame.width - preview.frame.width - 20, y: frame.height - preview.frame.height - 20)
        overlay.addSubview(preview)
        let panel = NoseOverlayPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = overlay
        panel.orderFrontRegardless()
        (self.panel, self.view, self.preview) = (panel, overlay, preview)
        preview.mirror()

        if settings.reuseCalibration, let saved = Self.loadCalibration() {
            calibration = saved
            beginTracking()
        } else {
            overlay.dim = true
        }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        loop = timer
    }

    func stop() {
        loop?.invalidate()
        loop = nil
        tracker.stop()
        panel?.orderOut(nil)
        panel = nil; view = nil; preview = nil
    }

    // MARK: Calibration

    func recalibrate() {
        calibration = nil; captured = []; recent = []; seenSince = nil
        anchor = nil; filterX.reset(); filterY.reset()
        phase = .finding
        view?.dim = true; view?.pointer = nil
        view?.edge = nil; view?.crosshair = false
    }

    private func enterStep(_ i: Int) {
        phase = .step(i)
        view?.edge = i == 0 ? nil : i - 1
        view?.crosshair = i == 0
        view?.message = Self.stepText(i, key: plugin.shortcutText("left_click"))
    }

    private static func stepText(_ i: Int, key: String) -> String {
        let steps = [
            "1/5  Face the screen, relax, nose toward the CENTER",
            "2/5  Turn your head LEFT, as far as is comfortable",
            "3/5  Turn your head RIGHT, as far as is comfortable",
            "4/5  Tilt your head UP, as far as is comfortable",
            "5/5  Tilt your head DOWN, as far as is comfortable",
        ]
        return "\(steps[i]) — then press \(key)"
    }

    private func beginTracking() {
        phase = .tracking
        view?.dim = false; view?.edge = nil; view?.crosshair = false; view?.pointer = nil
        anchor = nil; filterX.reset(); filterY.reset()
    }

    /// The left-click shortcut doubles as "next" during calibration.
    private func confirmStep(_ i: Int) {
        guard recent.count >= 5 else { view?.message = "Nose not visible — face the camera"; return }
        let med = (0..<2).map { j in median(recent.map { $0[j] }) }
        if i == 0 { calibration = NoseCalibration(center: med, extremes: []); return enterStep(1) }
        guard var cal = calibration else { return recalibrate() }
        let axis = i <= 2 ? 0 : 1
        if abs(med[axis] - cal.center[axis]) < 0.01 {
            view?.message = "Too small — turn further, then press \(plugin.shortcutText("left_click"))"
            return
        }
        cal.extremes.append(med)
        calibration = cal
        if i < 4 { return enterStep(i + 1) }
        try? FileManager.default.createDirectory(at: Self.calibrationFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(cal).write(to: Self.calibrationFile)
        beginTracking()
    }

    static func loadCalibration() -> NoseCalibration? {
        guard let data = try? Data(contentsOf: calibrationFile),
              let cal = try? JSONDecoder().decode(NoseCalibration.self, from: data),
              cal.center.count == 2, cal.extremes.count == 4, cal.extremes.allSatisfy({ $0.count == 2 }) else { return nil }
        return cal
    }

    static func forgetCalibration() { try? FileManager.default.removeItem(at: calibrationFile) }

    // MARK: Actions

    func togglePause() {
        guard phase == .tracking else { return }
        paused.toggle()
    }

    /// Left click, right click or double click at the pointer. During calibration, left click confirms the step.
    func click(_ button: CGMouseButton, count: Int = 1) {
        switch phase {
        case .finding: return
        case .step(let i): if button == .left, count == 1 { confirmStep(i) }
        case .tracking:
            guard refreshTrust() else {
                Toast.show("Allow Quick Capture under Accessibility to click.", symbol: "hand.raised", isError: true)
                _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
                return
            }
            let location = CGEvent(source: nil)?.location ?? .zero
            let (down, up): (CGEventType, CGEventType) = button == .left ? (.leftMouseDown, .leftMouseUp) : (.rightMouseDown, .rightMouseUp)
            for n in 1...count {
                for type in [down, up] {
                    let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: button)
                    event?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
                    event?.post(tap: .cghidEventTap)
                }
            }
            view?.clickAt = location
            view?.clickTime = Date()
        }
    }

    private func refreshTrust() -> Bool {
        if Date().timeIntervalSince(trustCheckedAt) > 1 { trusted = AXIsProcessTrusted(); trustCheckedAt = Date() }
        return trusted
    }

    // MARK: Mapping

    /// Nose position → screen point. Before calibration: a default gain around the neutral pose, so the
    /// pointer already moves while you calibrate. After: your measured limits map to the screen edges.
    private func target(_ f: [Double]) -> CGPoint {
        let w = Double(screen.frame.width), h = Double(screen.frame.height)
        let center = calibration?.center ?? f
        let d = [f[0] - center[0], f[1] - center[1]]
        let k = (w / 2) / (0.12 * 1280)                                  // default: 12% of the frame = half the screen
        let provisional = [-d[0] * 1280 * k, -d[1] * 720 * k]            // mirrored: turn left → pointer left
        var s = provisional
        if let cal = calibration, cal.extremes.count == 4 {
            func map(_ d: Double, _ minus: Double, _ plus: Double, _ half: Double, _ fallback: Double) -> Double {
                if d * plus >= 0 { return abs(plus) > 0.004 ? d / plus * half : fallback }
                return abs(minus) > 0.004 ? -(d / minus) * half : fallback
            }
            let e = cal.extremes
            s[0] = map(d[0], e[0][0] - center[0], e[1][0] - center[0], w / 2 * 0.98, provisional[0])
            s[1] = map(d[1], e[2][1] - center[1], e[3][1] - center[1], h / 2 * 0.98, provisional[1])
        }
        return CGPoint(x: min(max(w / 2 + s[0] * settings.sensitivityX, 0), w - 1),
                       y: min(max(h / 2 + s[1] * settings.sensitivityY, 0), h - 1))
    }

    // MARK: Loop

    private func tick() {
        guard let view else { return }
        let nose = tracker.latest
        preview?.setNose(nose)
        preview?.isHidden = phase == .tracking && !settings.showPreview

        if phase == .finding {
            if nose != nil {
                seenSince = seenSince ?? Date()
                view.message = "Nose found ✓ (green dot in the preview) — hold still…"
                if Date().timeIntervalSince(seenSince!) > 1.5 { enterStep(0) }
            } else {
                seenSince = nil
                view.message = "Looking for your nose… face the camera in good light"
            }
            view.needsDisplay = true
            return
        }

        if let nose {
            recent.append(nose)
            if recent.count > 15 { recent.removeFirst() }
            // Steadiness trades responsiveness for calm: lower filter cutoff + a leash that lets the
            // pointer stay put while the raw estimate wobbles inside it.
            let s = min(max(settings.steadiness, 0), 1)
            filterX.minCutoff = 1.5 * pow(0.1, s); filterY.minCutoff = filterX.minCutoff
            let raw = target(nose)
            let q = CGPoint(x: filterX.filter(Double(raw.x), dt: 1.0 / 60), y: filterY.filter(Double(raw.y), dt: 1.0 / 60))
            let leash = CGFloat((4 + 36 * s) * max(1, (settings.sensitivityX + settings.sensitivityY) / 2).squareRoot())
            if let a = anchor {
                let dx = q.x - a.x, dy = q.y - a.y, dist = hypot(dx, dy)
                if dist > leash { anchor = CGPoint(x: q.x - dx / dist * leash, y: q.y - dy / dist * leash) }
            } else {
                anchor = q
            }
        }

        if phase == .tracking {
            view.pointer = nil
            let toggle = plugin.shortcutText("toggle")
            view.message = paused ? "Nose control paused — \(plugin.shortcutText("pause")) to resume"
                                  : "Nose control on — \(toggle) to stop"
            if !paused, let p = anchor { movePointer(to: p) }
        } else {
            view.pointer = anchor        // calibration: show where the nose currently points
        }
        view.needsDisplay = true
    }

    private func movePointer(to p: CGPoint) {
        if refreshTrust(), let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left) {
            event.post(tap: .cghidEventTap)
        } else {
            CGWarpMouseCursorPosition(p)
        }
    }
}
