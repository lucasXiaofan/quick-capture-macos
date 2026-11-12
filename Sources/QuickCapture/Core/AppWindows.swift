import AppKit

/// Windows that behave like an ordinary app's (the Brake reader, AI Chat): a normal window level, on the
/// Space it opened in, and Quick Capture in the Dock and ⌘-Tab while one is open.
///
/// Closing one hands focus back to the app you came from by activating that app — never with
/// `NSApp.hide`, which would also hide every other Quick Capture window (the selfie camera, a recording
/// bar, a capture panel) and make plugins step on each other.
@MainActor
enum AppWindows {
    private static var open = Set<ObjectIdentifier>()
    private static var previous: NSRunningApplication?

    /// Shows the window in front, as the active app.
    static func show(_ window: NSWindow) {
        let front = NSWorkspace.shared.frontmostApplication
        if let front, front.processIdentifier != ProcessInfo.processInfo.processIdentifier { previous = front }
        open.insert(ObjectIdentifier(window))
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Call once the window is closed or ordered out.
    static func hidden(_ window: NSWindow) {
        guard open.remove(ObjectIdentifier(window)) != nil, open.isEmpty else { return }
        NSApp.setActivationPolicy(.accessory)
        // Leave focus alone when another normal window of ours (Settings) is still up.
        let others = NSApp.windows.contains { $0.isVisible && $0.level == .normal && $0 !== window && !($0 is NSPanel && $0.styleMask.contains(.nonactivatingPanel)) }
        if !others, let app = previous, !app.isTerminated { app.activate(options: []) }
        previous = nil
    }
}
