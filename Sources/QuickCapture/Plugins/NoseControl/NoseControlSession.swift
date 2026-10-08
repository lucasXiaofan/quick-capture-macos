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
    /// The panel (0…2) the pointer is confined to, and the nose pose that counts as its centre.
    private var activePanel: Int?
    private var reference: [Double]?
    private var legendTick = 0
    // TEMP diagnostics for the panel-jump bug: what the mapping produced on the latest tick.
    private var lastRaw: CGPoint?
    private var lastD: [Double]?
    private static let debugLog = Paths.data(for: NoseControlPlugin.pluginID).appendingPathComponent("debug.log")

    private func debug(_ line: String) {
        let text = "\(Date().formatted(.iso8601)) \(line)\n"
        try? FileManager.default.createDirectory(at: Self.debugLog.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: Self.debugLog) { h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close() }
        else { try? Data(text.utf8).write(to: Self.debugLog) }
    }
    private var trusted = AXIsProcessTrusted()
    private var trustCheckedAt = Date()

    private static let calibrationFile = Paths.data(for: NoseControlPlugin.pluginID).appendingPathComponent("calibration.json")

    init(plugin: NoseControlPlugin, settings: NoseSettings) {
        self.plugin = plugin
        self.settings = settings
    }

    /// The display the pointer is on when nose control starts; panels and the overlay belong to it.
    private lazy var screen: NSScreen =
        NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.screens[0]

    /// That display in the coordinates used to move the pointer (origin top-left of the primary display).
    private var displayFrame: CGRect {
        let f = screen.frame
        return CGRect(x: f.minX, y: NSScreen.screens[0].frame.height - f.maxY, width: f.width, height: f.height)
    }

    /// Pointer coordinates → coordinates inside the overlay view.
    private func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - displayFrame.minX, y: p.y - displayFrame.minY) }
    private func local(_ r: CGRect) -> CGRect { r.offsetBy(dx: -displayFrame.minX, dy: -displayFrame.minY) }

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
        activePanel = nil; reference = nil; view?.panelRect = nil
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
        activePanel = nil; reference = nil; view?.panelRect = nil
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

    // MARK: Panels

    /// Three equal panels, side by side or stacked.
    private func panelRect(_ i: Int) -> CGRect {
        let f = displayFrame
        if settings.panelLayout == "rows" {
            let h = f.height / 3
            return CGRect(x: f.minX, y: f.minY + h * CGFloat(i), width: f.width, height: h)
        }
        let w = f.width / 3
        return CGRect(x: f.minX + w * CGFloat(i), y: f.minY, width: w, height: f.height)
    }

    /// Jumps the pointer to the middle of panel `i` (0…2) and confines the nose to it, using the current head
    /// pose as that panel's centre. nil goes back to the whole screen.
    func focusPanel(_ i: Int?) {
        guard phase == .tracking else { return }
        filterX.reset(); filterY.reset()
        guard let i else {
            activePanel = nil; reference = nil; anchor = nil
            view?.panelRect = nil
            return
        }
        guard let nose = recent.last else { return }   // no nose in view: nothing to centre on
        let rect = panelRect(i)
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        activePanel = i; reference = nose; anchor = centre
        view?.panelRect = local(rect)
        view?.panelFlash = Date()
        movePointer(to: centre)
        debug("panel \(i + 1): layout=\(settings.panelLayout) display=\(displayFrame) rect=\(rect) centre=\(centre) "
              + "sens=\(settings.sensitivityX),\(settings.sensitivityY) cal=\(String(describing: calibration)) ref=\(nose)")
        for delay in [0.05, 0.3, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.debug("  +\(delay)s pointer=\(CGEvent(source: nil)?.location ?? .zero) anchor=\(String(describing: self.anchor)) "
                           + "raw=\(String(describing: self.lastRaw)) d=\(String(describing: self.lastD)) panel=\(String(describing: self.activePanel)) paused=\(self.paused)")
            }
        }
    }

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
            view?.clickAt = local(location)
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
        let rect = activePanel.map(panelRect) ?? displayFrame
        let w = Double(rect.width), h = Double(rect.height)
        let calCenter = calibration?.center ?? f
        let ref = reference ?? calCenter
        let d = [f[0] - ref[0], f[1] - ref[1]]
        let k = (w / 2) / (0.12 * 1280)                                  // default: 12% of the frame = half the panel
        let provisional = [-d[0] * 1280 * k, -d[1] * 720 * k]            // mirrored: turn left → pointer left
        var s = provisional
        if let cal = calibration, cal.extremes.count == 4 {
            func map(_ d: Double, _ minus: Double, _ plus: Double, _ half: Double, _ fallback: Double) -> Double {
                if d * plus >= 0 { return abs(plus) > 0.004 ? d / plus * half : fallback }
                return abs(minus) > 0.004 ? -(d / minus) * half : fallback
            }
            let e = cal.extremes   // limits are measured from the calibration centre, even when re-centred on a panel
            s[0] = map(d[0], e[0][0] - calCenter[0], e[1][0] - calCenter[0], w / 2 * 0.98, provisional[0])
            s[1] = map(d[1], e[2][1] - calCenter[1], e[3][1] - calCenter[1], h / 2 * 0.98, provisional[1])
        }
        return CGPoint(x: min(max(Double(rect.midX) + s[0] * settings.sensitivityX, Double(rect.minX)), Double(rect.maxX) - 1),
                       y: min(max(Double(rect.midY) + s[1] * settings.sensitivityY, Double(rect.minY)), Double(rect.maxY) - 1))
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
            lastRaw = raw
            lastD = reference.map { [nose[0] - $0[0], nose[1] - $0[1]] }
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
            if legendTick % 30 == 0 {
                view.legend = settings.showLegend ? plugin.legendLines() : []
                view.guide = settings.showLegend ? (0..<3).map { local(panelRect($0)) } : []
            }
            legendTick += 1
            view.pointer = nil
            let toggle = plugin.shortcutText("toggle")
            view.message = paused ? "Nose control paused — \(plugin.shortcutText("pause")) to resume"
                                  : "Nose control on — \(toggle) to stop"
            if !paused, let p = anchor { movePointer(to: p) }
        } else {
            view.pointer = anchor.map(local)        // calibration: show where the nose currently points
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
