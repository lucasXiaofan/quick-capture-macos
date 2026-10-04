import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// The key you hold to turn WASD into a mouse.
enum ActivationKey: String, CaseIterable, Identifiable {
    case rightOption = "right_option"
    case rightCommand = "right_command"
    case rightControl = "right_control"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rightOption: return "Right Option (⌥)"
        case .rightCommand: return "Right Command (⌘)"
        case .rightControl: return "Right Control (⌃) — external keyboards"
        }
    }

    var keyCode: Int {
        switch self {
        case .rightOption: return kVK_RightOption
        case .rightCommand: return kVK_RightCommand
        case .rightControl: return kVK_RightControl
        }
    }

    /// Device-dependent flag bits (IOLLEvent.h) that tell the right key from the left one.
    var deviceMask: UInt64 {
        switch self {
        case .rightOption: return 0x40
        case .rightCommand: return 0x10
        case .rightControl: return 0x2000
        }
    }
}

/// Turns keys into pointer movement and clicks while the activation key is held:
/// W A S D move, Space is the left button, E is the right button (tap a button twice quickly for a double click).
/// Needs Accessibility (to change and swallow key events) and Input Monitoring (to see them).
@MainActor
final class KeyboardMouseController {
    private enum Role { case up, down, left, right, leftButton, rightButton, panel(Int) }

    private static let roles: [Int: Role] = [
        kVK_ANSI_W: .up, kVK_ANSI_A: .left, kVK_ANSI_S: .down, kVK_ANSI_D: .right,
        kVK_Space: .leftButton, kVK_ANSI_E: .rightButton,
        kVK_ANSI_1: .panel(0), kVK_ANSI_2: .panel(1), kVK_ANSI_3: .panel(2),
        kVK_ANSI_4: .panel(3), kVK_ANSI_5: .panel(4), kVK_ANSI_6: .panel(5),
    ]

    /// The screen is split into a 3 × 2 grid laid out like the 1–6 keys: 1 2 3 on top, 4 5 6 below.
    private static let panelColumns = 3, panelRows = 2

    /// Pointer speed in points per second when a direction key is first pressed, and after it has been held.
    private static let startSpeed = 220.0
    private static let topSpeed = 1700.0
    private static let rampTime = 0.9
    private static let shiftBoost = 2.5

    var settings: KeyboardMouseSettings
    var paused = false { didSet { if paused { releaseEverything() } } }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var active = false
    private var directions = Set<Int>()
    private var swallowed = Set<Int>()
    private var buttonDown: CGMouseButton?
    private var lastClick: (button: CGMouseButton, time: TimeInterval, count: Int)?
    private var clickCount = 1
    private var timer: Timer?
    private var movingSince: TimeInterval?
    private var lastTick: TimeInterval = 0

    init(settings: KeyboardMouseSettings) { self.settings = settings }

    var isRunning: Bool { tap != nil }

    // MARK: Lifecycle

    /// False when macOS refuses the event tap (a permission is missing).
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask: CGEventMask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(0) { $0 | (1 << CGEventMask($1.rawValue)) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<KeyboardMouseController>.fromOpaque(refcon).takeUnretainedValue()
            // The tap runs on the main run loop, so this is already the main thread.
            let swallow = MainActor.assumeIsolated { controller.handle(type, event) }
            return swallow ? nil : Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let runLoopSource = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        (tap, source) = (port, runLoopSource)
        return true
    }

    func stop() {
        releaseEverything()
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        (tap, source) = (nil, nil)
    }

    // MARK: Events

    /// Returns true to swallow the event so the front app never sees it.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            releaseEverything()
            return false
        case .flagsChanged:
            let key = ActivationKey(rawValue: settings.activationKey) ?? .rightOption
            let down = event.flags.rawValue & key.deviceMask != 0
            if down != active {
                active = down
                if !active { releaseEverything() }
            }
            return false
        case .keyDown:
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            guard active, !paused, let role = Self.roles[code],
                  !event.flags.contains(.maskCommand), !event.flags.contains(.maskControl) else { return false }
            swallowed.insert(code)
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { press(role, code) }
            return true
        case .keyUp:
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            guard swallowed.remove(code) != nil, let role = Self.roles[code] else { return false }
            release(role, code)
            return true
        default:
            return false
        }
    }

    private func press(_ role: Role, _ code: Int) {
        switch role {
        case .leftButton: mouseButton(.left, down: true)
        case .rightButton: mouseButton(.right, down: true)
        case .panel(let index): jump(toPanel: index)
        default:
            directions.insert(code)
            if timer == nil { startMoving() }
        }
    }

    private func release(_ role: Role, _ code: Int) {
        switch role {
        case .leftButton: mouseButton(.left, down: false)
        case .rightButton: mouseButton(.right, down: false)
        case .panel: break
        default:
            directions.remove(code)
            if directions.isEmpty { stopMoving() }
        }
    }

    /// Lets go of any held button and stops moving, e.g. when the activation key is released.
    private func releaseEverything() {
        active = active && !paused
        swallowed.removeAll()
        directions.removeAll()
        stopMoving()
        if let button = buttonDown { mouseButton(button, down: false) }
    }

    // MARK: Clicks

    /// Down on key press and up on key release, so holding Space and moving with WASD drags.
    /// A second press within the system's double-click time counts as a double click.
    private func mouseButton(_ button: CGMouseButton, down: Bool) {
        guard down != (buttonDown == button) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if down {
            if let last = lastClick, last.button == button, now - last.time <= NSEvent.doubleClickInterval {
                clickCount = last.count + 1
            } else {
                clickCount = 1
            }
            lastClick = (button, now, clickCount)
            buttonDown = button
        } else {
            lastClick?.time = now
            buttonDown = nil
        }
        let type: CGEventType
        switch (button, down) {
        case (.left, true): type = .leftMouseDown
        case (.left, false): type = .leftMouseUp
        default: type = down ? .rightMouseDown : .rightMouseUp
        }
        post(type, at: CGEvent(source: nil)?.location ?? .zero, button: button)
    }

    private func post(_ type: CGEventType, at location: CGPoint, button: CGMouseButton, delta: CGPoint = .zero) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: button) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(delta.x.rounded()))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(delta.y.rounded()))
        event.post(tap: .cghidEventTap)
    }

    // MARK: Movement

    /// Jumps to the centre of a panel of the display the pointer is on; WASD then refines the position.
    private func jump(toPanel index: Int) {
        guard let from = CGEvent(source: nil)?.location else { return }
        var display: CGDirectDisplayID = CGMainDisplayID()
        var count: UInt32 = 0
        CGGetDisplaysWithPoint(from, 1, &display, &count)
        let bounds = CGDisplayBounds(display)
        let column = index % Self.panelColumns, row = index / Self.panelColumns
        let target = CGPoint(x: bounds.minX + bounds.width * (Double(column) + 0.5) / Double(Self.panelColumns),
                             y: bounds.minY + bounds.height * (Double(row) + 0.5) / Double(Self.panelRows))
        let type: CGEventType = buttonDown == .left ? .leftMouseDragged : buttonDown == .right ? .rightMouseDragged : .mouseMoved
        post(type, at: target, button: buttonDown ?? .left, delta: CGPoint(x: target.x - from.x, y: target.y - from.y))
    }

    private func startMoving() {
        movingSince = ProcessInfo.processInfo.systemUptime
        lastTick = movingSince ?? 0
        let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopMoving() {
        timer?.invalidate()
        timer = nil
        movingSince = nil
    }

    /// Speed grows the longer a direction is held: slow for precise nudges, fast for crossing the screen.
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = min(now - lastTick, 0.05)
        lastTick = now
        let held = now - (movingSince ?? now)
        let ramp = min(held / Self.rampTime, 1)
        var speed = Self.startSpeed + (Self.topSpeed * settings.speed - Self.startSpeed) * ramp * ramp
        if CGEventSource.flagsState(.combinedSessionState).contains(.maskShift) { speed *= Self.shiftBoost }

        var dx = 0.0, dy = 0.0
        for code in directions {
            switch Self.roles[code] {
            case .left: dx -= 1
            case .right: dx += 1
            case .up: dy -= 1
            case .down: dy += 1
            default: break
            }
        }
        let length = hypot(dx, dy)
        guard length > 0, let from = CGEvent(source: nil)?.location else { return }
        let step = speed * dt / length
        let to = Self.clamped(CGPoint(x: from.x + dx * step, y: from.y + dy * step))

        let type: CGEventType
        switch buttonDown {
        case .left?: type = .leftMouseDragged
        case .right?: type = .rightMouseDragged
        default: type = .mouseMoved
        }
        post(type, at: to, button: buttonDown ?? .left, delta: CGPoint(x: to.x - from.x, y: to.y - from.y))
    }

    /// Keeps the pointer inside the area covered by the connected displays.
    private static func clamped(_ p: CGPoint) -> CGPoint {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        CGGetActiveDisplayList(16, &ids, &count)
        let bounds = ids.prefix(Int(count)).map { CGDisplayBounds($0) }.reduce(CGRect.null) { $0.union($1) }
        guard !bounds.isNull else { return p }
        return CGPoint(x: min(max(p.x, bounds.minX), bounds.maxX - 1), y: min(max(p.y, bounds.minY), bounds.maxY - 1))
    }
}
