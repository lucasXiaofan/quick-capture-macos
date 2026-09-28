import AppKit
import WebKit

/// The chat window: a web view (Resources/ai_chat/index.html) that renders Markdown + LaTeX,
/// talking to Swift through the "qc" message handler.
@MainActor
final class ChatWindowController: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    private unowned let plugin: AIChatPlugin
    private let window: NSWindow
    private let webView: DropWebView
    private let indexURL = Paths.resource("index.html", plugin: AIChatPlugin.pluginID)
    private let session: ChatSession
    private var pageReady = false
    private var pending: [[String: Any]] = []

    init(plugin: AIChatPlugin) {
        self.plugin = plugin
        session = ChatSession(detector: plugin.detector, directory: plugin.workingDirectory)

        let config = WKWebViewConfiguration()
        webView = DropWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")  // No white flash in dark mode.
        if #available(macOS 13.3, *) { webView.isInspectable = true }

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 680),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "AI Chat"
        window.minSize = NSSize(width: 420, height: 360)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.contentView = webView
        window.center()
        window.setFrameAutosaveName("AIChatWindow")
        super.init()

        window.delegate = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        config.userContentController.add(WeakMessageHandler(self), name: "qc")
        session.onEvent = { [weak self] in self?.send($0) }
        webView.onDropFiles = { [weak self] urls in self?.insertPaths(urls) }
        if let index = indexURL {
            webView.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
        }
        selectDefaultModel()
    }

    // MARK: Showing and hiding

    var isVisible: Bool { window.isVisible }

    func toggle() {
        if window.isVisible && window.isKeyWindow && NSApp.isActive { hide() } else { show() }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        send(["type": "focus"])
    }

    func hide() {
        window.orderOut(nil)
        // Give focus back to the previous app when nothing else of ours is on screen.
        if !NSApp.windows.contains(where: { $0.isVisible && $0.level == .normal && $0 !== window }) { NSApp.hide(nil) }
    }

    func newChat() {
        session.reset()
        send(["type": "reset"])
        pushState()
    }

    func close() {
        session.reset()
        window.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false  // Keep the conversation until "New Chat".
    }

    // MARK: State

    func configDidChange() {
        if session.model == nil || !plugin.detector.models(including: plugin.settings.defaultModel).contains(where: { $0 == session.model }) {
            selectDefaultModel()
        }
        pushState()
    }

    private func selectDefaultModel() {
        let models = plugin.detector.models(including: plugin.settings.defaultModel)
        if let model = models.first(where: { $0.key == plugin.settings.defaultModel }) ?? models.first {
            session.setModel(model)
        }
    }

    private func pushState() {
        let models = plugin.detector.models(including: plugin.settings.defaultModel)
        let dir = session.directory
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        send([
            "type": "state",
            "models": models.map { ["key": $0.key, "label": $0.label, "provider": $0.provider.displayName] },
            "model": session.model?.key ?? "",
            "directory": dir.path,
            "directoryLabel": dir.path == home ? "~" : dir.lastPathComponent,
            "detecting": plugin.detector.detecting,
            "missing": models.isEmpty ? "No Claude Code or Codex found. " + Provider.allCases.map(\.installHint).joined(separator: " ") : "",
            "permissions": plugin.settings.permissions,
            "busy": session.isBusy,
        ])
    }

    private func send(_ event: [String: Any]) {
        guard pageReady else { pending.append(event); return }
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.qc && qc.receive(\(json))")
    }

    // MARK: Messages from the page

    fileprivate func handle(_ body: Any) {
        guard let msg = body as? [String: Any], let type = msg["type"] as? String else { return }
        switch type {
        case "ready":
            pageReady = true
            pushState()
            pending.forEach(send)
            pending.removeAll()
        case "send":
            guard let text = msg["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            Task {
                if plugin.detector.installs.isEmpty { await plugin.detectAgents() }
                session.send(text, settings: plugin.settings)
            }
        case "stop": session.stop()
        case "new_chat": newChat()
        case "hide": hide()
        case "set_model":
            guard let key = msg["key"] as? String,
                  let model = plugin.detector.models(including: plugin.settings.defaultModel).first(where: { $0.key == key }) else { return }
            if session.isBusy { session.stop() }
            if session.setModel(model) {
                send(["type": "reset", "notice": "Switched to \(model.provider.displayName) — started a new conversation."])
            }
            pushState()
        case "choose_folder": chooseFolder()
        case "open": open(msg["href"] as? String ?? "", reveal: msg["reveal"] as? Bool ?? false)
        case "copy":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(msg["text"] as? String ?? "", forType: .string)
        default: break
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.message = "Choose the folder the AI works in. It can read and edit files inside it."
        panel.prompt = "Use Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = session.directory
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.session.stop()
            try? self.plugin.update { $0.workingDirectory = url.path }
            self.session.setDirectory(url)
            self.send(["type": "reset", "notice": "Working in \(url.path) — started a new conversation."])
            self.pushState()
        }
    }

    /// Opens web links in the browser and file links (absolute, ~, or relative to the working
    /// folder; `path:12` and `#L12` suffixes allowed) in their default app.
    private func open(_ href: String, reveal: Bool) {
        let trimmed = href.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme.count > 1, scheme != "file" {
            if ["javascript", "data"].contains(scheme) { return }
            NSWorkspace.shared.open(url)
            return
        }
        var path = trimmed
        if path.lowercased().hasPrefix("file://") { path = URL(string: path)?.path ?? String(path.dropFirst(7)) }
        path = path.removingPercentEncoding ?? path
        if let hash = path.firstIndex(of: "#") { path = String(path[..<hash]) }
        path = path.replacingOccurrences(of: #"(:\d+){1,2}$"#, with: "", options: .regularExpression)
        path = (path as NSString).expandingTildeInPath
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : session.directory.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            Toast.show("File not found: \(path)", symbol: "questionmark.folder", isError: true)
            return
        }
        if reveal { NSWorkspace.shared.activateFileViewerSelecting([url]) } else { NSWorkspace.shared.open(url) }
    }

    /// Dropped files become references in the message: relative to the working folder when inside it.
    private func insertPaths(_ urls: [URL]) {
        let base = session.directory.path.hasSuffix("/") ? session.directory.path : session.directory.path + "/"
        let paths = urls.map { url -> String in
            let path = url.path.hasPrefix(base) ? String(url.path.dropFirst(base.count)) : url.path
            return path.contains(" ") ? "\"\(path)\"" : path
        }
        send(["type": "insert", "text": paths.joined(separator: " ")])
        show()
    }

    // MARK: Navigation: the page itself never navigates away

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if action.navigationType == .linkActivated, let url = action.request.url {
            decisionHandler(.cancel)
            open(url.absoluteString, reveal: false)
            return
        }
        decisionHandler(action.request.url?.path == indexURL?.path ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { open(url.absoluteString, reveal: false) }
        return nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        pageReady = false
        webView.reload()
    }
}

/// Accepts files dragged from Finder (the page can't see their paths).
final class DropWebView: WKWebView {
    var onDropFiles: (([URL]) -> Void)?

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        onDropFiles?(urls)
        return true
    }
}

/// WKUserContentController retains its handlers; this avoids a retain cycle with the controller.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: ChatWindowController?
    init(_ target: ChatWindowController) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        MainActor.assumeIsolated { target?.handle(body) }
    }
}
