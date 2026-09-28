import Foundation

/// One temporary conversation. Each turn runs the CLI once; later turns resume the CLI's own
/// session, so the agent keeps full context (files read, commands run) between messages.
@MainActor
final class ChatSession {
    private let detector: AgentDetector
    private(set) var model: ChatModel?
    private(set) var directory: URL
    private var sessionID: String?
    private var process: StreamingProcess?
    private var stopped = false
    private var running = false
    var onEvent: (([String: Any]) -> Void)?

    init(detector: AgentDetector, directory: URL) {
        self.detector = detector
        self.directory = directory
    }

    var isBusy: Bool { running }
    var hasHistory: Bool { sessionID != nil }

    /// Switching to another provider or folder can't continue the CLI session, so it starts over.
    /// Returns true when the conversation was reset.
    @discardableResult
    func setModel(_ next: ChatModel) -> Bool {
        let reset = model?.provider != next.provider && sessionID != nil
        model = next
        if reset { sessionID = nil }
        return reset
    }

    func setDirectory(_ url: URL) {
        directory = url
        sessionID = nil
    }

    func reset() {
        stop()
        sessionID = nil
    }

    func send(_ prompt: String, settings: AIChatSettings) {
        guard !running, let model else { return }
        guard let install = detector.installs[model.provider] else {
            emit(["type": "error", "message": "\(model.provider.displayName) isn't installed. \(model.provider.installHint)"])
            emit(["type": "done"])
            emit(["type": "idle"])
            return
        }
        stopped = false
        running = true
        let directory = self.directory
        let parser = ParserBox(AgentEventParser(provider: model.provider, directory: directory, sessionID: sessionID))
        let args = AgentCommand.arguments(provider: model.provider, model: model.id, permissions: settings.permissions,
                                          sessionID: sessionID, directory: directory)
        emit(["type": "status", "text": "Starting \(model.provider.displayName)…"])
        Task { [weak self] in
            let env = await LoginEnvironment.shared.environment(for: install.path)
            guard let self else { return }
            let process = StreamingProcess(executable: install.path, arguments: args, directory: directory,
                                           environment: env, input: prompt)
            process.onLine = { [weak self] line in
                guard let self else { return }
                for event in parser.value.parse(line) { self.emit(event) }
                if let id = parser.value.sessionID { self.sessionID = id }
            }
            process.onExit = { [weak self] status, stderr in
                guard let self else { return }
                self.process = nil
                defer { self.finishRun() }
                if let id = parser.value.sessionID { self.sessionID = id }
                if self.stopped {
                    self.emit(["type": "done", "stopped": true])
                } else if !parser.value.finished {
                    let detail = Self.lastLines(stderr)
                    self.emit(["type": "error", "message": status == 0 && detail.isEmpty
                               ? "\(model.provider.displayName) ended without a reply."
                               : "\(model.provider.displayName) exited (\(status)).\n\n" + detail])
                    self.emit(["type": "done"])
                }
            }
            if self.stopped {
                self.emit(["type": "done", "stopped": true])
                self.finishRun()
                return
            }
            self.process = process
            do { try process.start() } catch {
                self.process = nil
                self.emit(["type": "error", "message": "Couldn't start \(install.path): \(error.localizedDescription)"])
                self.emit(["type": "done"])
                self.finishRun()
            }
        }
    }

    func stop() {
        guard running else { return }
        stopped = true
        process?.stop()
    }

    private func finishRun() {
        running = false
        emit(["type": "idle"])
    }

    private func emit(_ event: [String: Any]) { onEvent?(event) }

    private static func lastLines(_ text: String) -> String {
        text.split(separator: "\n").suffix(8).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class ParserBox {
    var value: AgentEventParser
    init(_ value: AgentEventParser) { self.value = value }
}
