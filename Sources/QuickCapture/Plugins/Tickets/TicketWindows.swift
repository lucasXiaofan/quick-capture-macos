import AppKit
import UniformTypeIdentifiers
import WebKit

/// A web view showing one of the pages in Resources/tickets/, talking to Swift through the "tk" message
/// handler. Attachments are served to the page through the `tkfile:` scheme, from the ticket folder only.
@MainActor
final class TicketWebHost: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: DropWebView
    /// A message from the page (already known to be an object with a "type").
    var onMessage: (([String: Any]) -> Void)?
    private var pageReady = false
    private var pending: [[String: Any]] = []
    private weak var window: NSWindow?

    init(page: String, store: @escaping () -> TicketStore?) {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(TicketFileScheme(store: store), forURLScheme: "tkfile")
        webView = DropWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        config.userContentController.add(TicketMessageHandler(self), name: "tk")
        if let url = Paths.resource(page, plugin: TicketsPlugin.pluginID) {
            // Markdown and math rendering are shared with AI Chat, so allow reading all of Resources/.
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent().deletingLastPathComponent())
        } else {
            Toast.show("Tickets files are missing from the app bundle.", isError: true)
        }
    }

    func attach(to window: NSWindow) { self.window = window }

    func send(_ event: [String: Any]) {
        guard pageReady else {
            // Only the newest full state matters while the page loads.
            if event["type"] as? String == "state" { pending.removeAll { $0["type"] as? String == "state" } }
            pending.append(event)
            return
        }
        guard JSONSerialization.isValidJSONObject(event), let data = try? JSONSerialization.data(withJSONObject: event),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.TK && TK.receive(\(json))")
    }

    fileprivate func receive(_ body: Any) {
        guard let msg = body as? [String: Any], let type = msg["type"] as? String else { return }
        if type == "ready" {
            pageReady = true
            let queued = pending
            pending = []
            onMessage?(msg)
            queued.forEach(send)
        } else {
            onMessage?(msg)
        }
    }

    func dispose() {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "tk")
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if action.navigationType == .linkActivated {
            decisionHandler(.cancel)
            if let url = action.request.url, ["http", "https", "mailto"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        if let window { alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) } }
        else { completionHandler(alert.runModal() == .alertFirstButtonReturn) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        pageReady = false
        webView.reload()
    }
}

private final class TicketMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: TicketWebHost?
    init(_ target: TicketWebHost) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        MainActor.assumeIsolated { target?.receive(body) }
    }
}

/// tkfile://a/<ticket id>/<name> is an attachment; tkfile://s/<name> is a staged (not yet sent) file;
/// tkfile://d/<path> is an image inside designs/.
private final class TicketFileScheme: NSObject, WKURLSchemeHandler {
    private let store: () -> TicketStore?
    init(store: @escaping () -> TicketStore?) { self.store = store }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let file: URL? = MainActor.assumeIsolated {
            guard let url = task.request.url, let store = store() else { return nil }
            let parts = url.pathComponents.filter { $0 != "/" }
            switch url.host {
            case "a" where parts.count == 2:
                guard let id = Int(parts[0]) else { return nil }
                return store.attachmentDir(id).appendingPathComponent((parts[1] as NSString).lastPathComponent)
            case "s" where parts.count == 1:
                return store.stagingDir.appendingPathComponent((parts[0] as NSString).lastPathComponent)
            case "d" where !parts.isEmpty:
                // An image on a design; only files inside designs/.
                return store.designAsset(parts.joined(separator: "/"))
            default:
                return nil
            }
        }
        guard let file, let url = task.request.url, let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

/// The main window: inbox, projects, habits, plan, library and the agent's rules and logs.
@MainActor
final class TicketsWindowController: NSObject, NSWindowDelegate {
    let host: TicketWebHost
    private let window: NSWindow

    init(plugin: TicketsPlugin) {
        host = TicketWebHost(page: "index.html") { [weak plugin] in plugin?.store }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Tickets"
        window.minSize = NSSize(width: 860, height: 520)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.contentView = host.webView
        window.center()
        window.setFrameAutosaveName("TicketsWindow")
        super.init()
        window.delegate = self
        host.attach(to: window)
    }

    var isVisible: Bool { window.isVisible }
    var isKey: Bool { window.isVisible && window.isKeyWindow }

    func show() { AppWindows.show(window) }

    func close() {
        window.orderOut(nil)
        AppWindows.hidden(window)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        close()
        return false
    }
}

/// The small "new ticket" window a shortcut opens: type, attach, send.
@MainActor
final class TicketComposeController: NSObject, NSWindowDelegate {
    let host: TicketWebHost
    private let panel: ComposePanel
    private var previous: NSRunningApplication?

    init(plugin: TicketsPlugin) {
        host = TicketWebHost(page: "compose.html") { [weak plugin] in plugin?.store }
        panel = ComposePanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        // A real title bar, kept apart from the page: that is what you drag. (A page under a transparent title bar
        // swallows the drag.)
        panel.title = "New Ticket"
        panel.titlebarAppearsTransparent = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 460, height: 260)
        panel.contentView = host.webView
        panel.center()
        panel.setFrameAutosaveName("TicketsComposePanel")
        super.init()
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.hide() }
        host.attach(to: panel)
    }

    var isVisible: Bool { panel.isVisible }

    func show() {
        let front = NSWorkspace.shared.frontmostApplication
        if let front, front.processIdentifier != ProcessInfo.processInfo.processIdentifier { previous = front }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        host.send(["type": "focus"])
    }

    /// Hides the panel; the draft stays for next time. `returnFocus` false while a screenshot is being taken.
    func hide(returnFocus: Bool = true) {
        panel.orderOut(nil)
        if returnFocus, let app = previous, !app.isTerminated,
           !NSApp.windows.contains(where: { $0.isVisible && $0.level == .normal && $0.canBecomeMain }) {
            app.activate(options: [])
        }
        if returnFocus { previous = nil }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }
}

private final class ComposePanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}
