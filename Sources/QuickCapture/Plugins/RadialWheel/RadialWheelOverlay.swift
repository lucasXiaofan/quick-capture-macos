import AppKit
import Carbon.HIToolbox
import SwiftUI

/// One slice of the wheel: an action of some plugin, or a reference that no longer resolves.
struct WheelEntry: Identifiable {
    let id: Int
    let ref: String
    let plugin: Plugin?
    let action: PluginAction?
    /// The plugin is switched on and the action can run right now.
    let ready: Bool

    var title: String { action?.shortTitle ?? "Missing" }
    var symbol: String { action?.symbol ?? "questionmark" }
    /// "<Plugin name>", or why it can't run.
    let subtitle: String
}

extension PluginAction {
    /// "Record (press again to pause)" → "Record": short enough for a wheel slice.
    var shortTitle: String {
        var t = title
        if let open = t.range(of: " (") { t = String(t[..<open.lowerBound]) }
        return t.replacingOccurrences(of: "…", with: "")
    }
}

/// Live state of an open wheel, shared with its SwiftUI view.
@MainActor
final class WheelModel: ObservableObject {
    let entries: [WheelEntry]
    let radius: CGFloat
    /// Wheel centre in the view's (top-left origin) coordinates.
    let center: CGPoint
    @Published var hovered: Int?
    /// Pointer direction in degrees clockwise from the top, while outside the dead zone.
    @Published var pointer: Double?
    @Published var shown = false
    /// The shortcut was released over the middle: the wheel waits for a click or a number key.
    @Published var sticky = false

    init(entries: [WheelEntry], radius: CGFloat, center: CGPoint) {
        self.entries = entries
        self.radius = radius
        self.center = center
    }

    var innerRadius: CGFloat { radius * 0.38 }
    var step: Double { 360 / Double(max(entries.count, 1)) }
}

/// Opens the wheel at the pointer and turns pointer direction into a choice. Hold the shortcut, point,
/// release — or tap it, then click a slice or press its number.
@MainActor
final class RadialWheelController {
    private var panel: OverlayPanel?
    private var model: WheelModel?
    private var timer: Timer?
    private var screenCenter = CGPoint.zero
    private var hold: Shortcut?
    private var onChoose: ((WheelEntry) -> Void)?

    var isOpen: Bool { panel != nil }

    func open(entries: [WheelEntry], scale: Double, shortcut: Shortcut?, onChoose: @escaping (WheelEntry) -> Void) {
        guard panel == nil, !entries.isEmpty, let screen = OverlayPanel.screenUnderMouse else { return }
        let radius = 170 * CGFloat(scale)
        let frame = screen.frame
        let mouse = NSEvent.mouseLocation
        let margin = radius + 40
        let cx = min(max(mouse.x, frame.minX + margin), frame.maxX - margin)
        let cy = min(max(mouse.y, frame.minY + margin), frame.maxY - margin)
        screenCenter = CGPoint(x: cx, y: cy)
        let model = WheelModel(entries: entries, radius: radius,
                               center: CGPoint(x: cx - frame.minX, y: frame.maxY - cy))
        let panel = OverlayPanel(frame: frame, content: RadialWheelView(model: model))
        panel.onKey = { [weak self] in self?.key($0) ?? false }
        panel.onMouseDown = { [weak self] event in
            if event.type == .leftMouseDown { self?.click() } else { self?.close() }
            return true
        }
        panel.onResignKey = { [weak self] in self?.close() }
        self.model = model
        self.panel = panel
        self.hold = shortcut
        self.onChoose = onChoose
        // While open, the wheel owns the keyboard: pressing the shortcut again arrives here as a key press.
        AppState.shared.pauseHotkeys(true)
        panel.show()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) { model.shown = true }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func close() { finish(nil) }

    private func finish(_ chosen: WheelEntry?) {
        guard let panel else { return }
        timer?.invalidate()
        timer = nil
        let onChoose = onChoose
        self.panel = nil
        self.onChoose = nil
        model = nil
        AppState.shared.pauseHotkeys(false)
        panel.dismiss {
            // After the wheel is gone, so screenshots and windows don't see it.
            if let chosen { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { onChoose?(chosen) } }
        }
    }

    private func tick() {
        guard let model else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - screenCenter.x, dy = mouse.y - screenCenter.y
        let distance = hypot(dx, dy)
        var hovered: Int?
        var pointer: Double?
        if distance > model.innerRadius * 0.55 {
            var angle = atan2(dx, dy) * 180 / .pi
            if angle < 0 { angle += 360 }
            pointer = angle
            hovered = Int((angle + model.step / 2) / model.step) % model.entries.count
        }
        if hovered != model.hovered {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.7)) { model.hovered = hovered }
            if hovered != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        }
        model.pointer = pointer
        if !model.sticky, !isHeld() {
            if let hovered { finish(model.entries[hovered]) } else { withAnimation { model.sticky = true } }
        }
    }

    /// Whether the shortcut that opened the wheel is still held down.
    private func isHeld() -> Bool {
        guard let hold else { return false }
        let mods = hold.modifierFlags
        if !mods.isEmpty { return NSEvent.modifierFlags.intersection([.command, .option, .control, .shift]).isSuperset(of: mods) }
        return CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(hold.keyCode))
    }

    private func click() {
        guard let model else { return }
        if let hovered = model.hovered { finish(model.entries[hovered]) } else { close() }
    }

    private func key(_ event: NSEvent) -> Bool {
        guard let model else { return false }
        // Holding the shortcut auto-repeats its key into the wheel; only a fresh press counts.
        if event.isARepeat { return true }
        if let hold, Shortcut(event: event, allowBare: true) == hold { close(); return true }
        switch Int(event.keyCode) {
        case kVK_Escape: close()
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space: click()
        default:
            guard let digit = Int(event.charactersIgnoringModifiers ?? "") else { return false }
            let index = digit == 0 ? 9 : digit - 1
            if model.entries.indices.contains(index) { finish(model.entries[index]) } else { NSSound.beep() }
        }
        return true
    }
}

// MARK: - Drawing

/// A ring segment between two angles (degrees clockwise from the top).
struct RingSlice: Shape {
    var start: Double
    var end: Double
    var inner: CGFloat
    var outer: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(inner, outer) }
        set { inner = newValue.first; outer = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let steps = max(Int((end - start) / 3), 4)
        func point(_ deg: Double, _ r: CGFloat) -> CGPoint {
            let a = deg * .pi / 180
            return CGPoint(x: c.x + r * CGFloat(sin(a)), y: c.y - r * CGFloat(cos(a)))
        }
        var p = Path()
        p.move(to: point(start, outer))
        for i in 1...steps { p.addLine(to: point(start + (end - start) * Double(i) / Double(steps), outer)) }
        for i in (0...steps).reversed() { p.addLine(to: point(start + (end - start) * Double(i) / Double(steps), inner)) }
        p.closeSubpath()
        return p
    }
}

private let wheelGlow = Color(red: 0.25, green: 0.85, blue: 1.0)
private let wheelHot = LinearGradient(colors: [Color(red: 0.2, green: 0.8, blue: 1.0), Color(red: 0.55, green: 0.35, blue: 1.0)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing)

struct RadialWheelView: View {
    @ObservedObject var model: WheelModel

    var body: some View {
        GeometryReader { geo in
          ZStack {
            // Dim the screen, brightest around the wheel.
            RadialGradient(colors: [.black.opacity(0.12), .black.opacity(0.45)],
                           center: UnitPoint(x: model.center.x / max(geo.size.width, 1), y: model.center.y / max(geo.size.height, 1)),
                           startRadius: model.radius * 0.8, endRadius: model.radius * 5)
                .opacity(model.shown ? 1 : 0)

            WheelFace(model: model, interactive: true)
                .frame(width: model.radius * 2 + 60, height: model.radius * 2 + 60)
                .scaleEffect(model.shown ? 1 : 0.6)
                .rotationEffect(.degrees(model.shown ? 0 : -25))
                .opacity(model.shown ? 1 : 0)
                .position(model.center)

            hint
                .position(x: model.center.x, y: model.center.y + model.radius + 44)
                .opacity(model.shown ? 1 : 0)
          }
        }
        .ignoresSafeArea()
    }

    private var hint: some View {
        let count = min(model.entries.count, 10)
        let keys = count > 1 ? "1–\(count == 10 ? 0 : count)" : "1"
        return Text(model.sticky ? "Click a slice  ·  \(keys)  ·  esc to cancel" : "Point and release  ·  \(keys)  ·  esc")
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.black.opacity(0.45), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
    }
}

/// The wheel itself, also used as a still preview in Settings.
struct WheelFace: View {
    @ObservedObject var model: WheelModel
    var interactive: Bool

    var body: some View {
        let r = model.radius, inner = model.innerRadius
        let gap = min(1.6, model.step * 0.04)
        ZStack {
            // Outer track and the pointer's direction marker.
            Circle()
                .stroke(.white.opacity(0.07), lineWidth: 2)
                .frame(width: (r + 16) * 2, height: (r + 16) * 2)
            if interactive, let pointer = model.pointer {
                RingSlice(start: pointer - 9, end: pointer + 9, inner: r + 13, outer: r + 19)
                    .fill(wheelGlow)
                    .shadow(color: wheelGlow, radius: 8)
            }

            ForEach(model.entries) { entry in
                let mid = Double(entry.id) * model.step
                let hot = model.hovered == entry.id
                RingSlice(start: mid - model.step / 2 + gap, end: mid + model.step / 2 - gap,
                          inner: inner + (hot ? 4 : 0), outer: r + (hot ? 10 : 0))
                    .fill(hot ? AnyShapeStyle(wheelHot) : AnyShapeStyle(Color(white: 0.09).opacity(0.86)))
                    .overlay(
                        RingSlice(start: mid - model.step / 2 + gap, end: mid + model.step / 2 - gap,
                                  inner: inner + (hot ? 4 : 0), outer: r + (hot ? 10 : 0))
                            .stroke(.white.opacity(hot ? 0.5 : 0.09), lineWidth: 1)
                    )
                    .shadow(color: hot ? wheelGlow.opacity(0.7) : .clear, radius: hot ? 18 : 0)
                slice(entry, mid: mid, hot: hot)
            }

            // Hub.
            Circle()
                .fill(Color(white: 0.06).opacity(0.92))
                .overlay(Circle().strokeBorder(.white.opacity(0.1)))
                .frame(width: (inner - 8) * 2, height: (inner - 8) * 2)
            hub.frame(width: (inner - 18) * 2)
        }
        .frame(width: (r + 30) * 2, height: (r + 30) * 2)
    }

    private func slice(_ entry: WheelEntry, mid: Double, hot: Bool) -> some View {
        let r = model.radius, inner = model.innerRadius
        let at = (inner + r) / 2 + (hot ? 5 : 0)
        let a = mid * .pi / 180
        let arc = CGFloat(model.step * .pi / 180) * at
        return ZStack {
            VStack(spacing: 4) {
                Image(systemName: entry.symbol)
                    .font(.system(size: (hot ? 25 : 21) * r / 170, weight: hot ? .bold : .medium))
                    .symbolRenderingMode(.hierarchical)
                Text(entry.title)
                    .font(.system(size: 10 * r / 170, weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .frame(width: min(arc * 0.86, (r - inner) * 0.95))
            }
            .foregroundStyle(.white.opacity(entry.ready ? 1 : 0.35))
            .offset(x: at * CGFloat(sin(a)), y: -at * CGFloat(cos(a)))

            if entry.id < 10 {
                let n = r - 12
                Text("\(entry.id == 9 ? 0 : entry.id + 1)")
                    .font(.system(size: 9 * r / 170, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(hot ? 0.9 : 0.35))
                    .offset(x: n * CGFloat(sin(a)), y: -n * CGFloat(cos(a)))
            }
        }
    }

    @ViewBuilder private var hub: some View {
        if let i = model.hovered, model.entries.indices.contains(i) {
            let entry = model.entries[i]
            VStack(spacing: 3) {
                Text(entry.title)
                    .font(.system(size: 13 * model.radius / 170, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(entry.subtitle)
                    .font(.system(size: 9.5 * model.radius / 170, weight: .medium))
                    .foregroundStyle(entry.ready ? wheelGlow : .orange)
            }
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.6)
            .id(i)
            .transition(.opacity.combined(with: .scale(scale: 0.85)))
        } else {
            Image(systemName: "circle.grid.cross")
                .font(.system(size: 20 * model.radius / 170, weight: .light))
                .foregroundStyle(.white.opacity(0.4))
        }
    }
}
