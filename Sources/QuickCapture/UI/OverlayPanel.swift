import AppKit
import SwiftUI

/// A borderless panel that takes the keyboard without activating the app, so the app you were in stays
/// frontmost (and gets focus back) once it closes. Used for the radial wheel and the Esc stop prompt.
final class OverlayPanel: NSPanel {
    /// Return true when the key was handled.
    var onKey: ((NSEvent) -> Bool)?
    /// Sees every mouse-down before the views do; return true to swallow it.
    var onMouseDown: ((NSEvent) -> Bool)?
    var onResignKey: (() -> Void)?

    init(frame: NSRect, content: some View) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        contentView = host
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    override func sendEvent(_ event: NSEvent) {
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type), onMouseDown?(event) == true { return }
        super.sendEvent(event)
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    func show() {
        alphaValue = 0
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; animator().alphaValue = 1 }
    }

    func dismiss(then: (() -> Void)? = nil) {
        onResignKey = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.1; animator().alphaValue = 0 }) { [weak self] in
            self?.orderOut(nil)
            // Drop the content and handlers: they often capture the panel, which would keep it alive.
            self?.contentView = nil
            self?.onKey = nil
            self?.onMouseDown = nil
            then?()
        }
    }

    /// The screen under the mouse pointer.
    static var screenUnderMouse: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }
}
