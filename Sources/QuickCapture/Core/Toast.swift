import AppKit
import SwiftUI

/// Small, non-interactive confirmation bubble near the top of the screen.
@MainActor
enum Toast {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ message: String, symbol: String = "checkmark.circle.fill", isError: Bool = false) {
        let view = HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(isError ? Color.orange : Color.green)
            Text(message).lineLimit(3).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(maxWidth: 460)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator))
        .padding(12)
        .fixedSize()

        let host = NSHostingView(rootView: view)
        let p = panel ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.level = .statusBar
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel = p
            return p
        }()
        p.contentView = host
        let size = host.fittingSize
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrame(NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height - 8, width: size.width, height: size.height),
                       display: true)
        }
        p.alphaValue = 1
        p.orderFrontRegardless()
        hideWork?.cancel()
        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; p.animator().alphaValue = 0 }) { p.orderOut(nil) }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (isError ? 4 : 1.8), execute: work)
    }
}
