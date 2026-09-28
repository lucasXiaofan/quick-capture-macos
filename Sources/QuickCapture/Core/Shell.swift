import Foundation

enum Shell {
    struct Output { let status: Int32; let stdout: String; let stderr: String }

    static func run(_ path: String, _ args: [String], environment: [String: String]? = nil,
                    timeout: TimeInterval = 60) async throws -> Output {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = args
                if let environment { process.environment = environment }
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch { cont.resume(throwing: error); return }
                let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                var errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                killer.cancel()
                cont.resume(returning: Output(status: process.terminationStatus,
                                              stdout: String(decoding: outData, as: UTF8.self),
                                              stderr: String(decoding: errData, as: UTF8.self)))
            }
        }
    }
}

/// Runs a long-lived command and delivers its stdout line by line on the main thread.
final class StreamingProcess {
    private let process = Process()
    private let queue = DispatchQueue(label: "StreamingProcess")
    private var buffer = Data()
    private var stderrTail = Data()
    private let finished = DispatchGroup()
    private var stdoutClosed = false, stderrClosed = false
    var onLine: ((String) -> Void)?
    /// Exit status and the end of stderr (for error messages).
    var onExit: ((Int32, String) -> Void)?

    private let input: String?

    /// `input` is written to stdin, which is then closed.
    init(executable: String, arguments: [String], directory: URL, environment: [String: String], input: String? = nil) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        self.input = input
    }

    func start() throws {
        let out = Pipe(), err = Pipe()
        let stdin = input.map { _ in Pipe() }
        process.standardInput = stdin ?? FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err
        finished.enter(); finished.enter(); finished.enter()
        // EOF can be reported more than once, so the handler is removed right away and each
        // stream leaves the group exactly once.
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            guard let self else { return }
            self.queue.async {
                if data.isEmpty {
                    guard !self.stdoutClosed else { return }
                    self.stdoutClosed = true
                    self.flush(final: true)
                    self.finished.leave()
                } else {
                    self.buffer.append(data)
                    self.flush(final: false)
                }
            }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            guard let self else { return }
            self.queue.async {
                if data.isEmpty {
                    guard !self.stderrClosed else { return }
                    self.stderrClosed = true
                    self.finished.leave()
                } else {
                    self.stderrTail.append(data)
                    if self.stderrTail.count > 8000 { self.stderrTail = self.stderrTail.suffix(4000) }
                }
            }
        }
        process.terminationHandler = { [weak self] _ in self?.finished.leave() }
        try process.run()
        if let stdin, let input {
            let handle = stdin.fileHandleForWriting
            DispatchQueue.global().async {
                try? handle.write(contentsOf: Data(input.utf8))
                try? handle.close()
            }
        }
        finished.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.onExit?(self.process.terminationStatus, String(decoding: self.stderrTail, as: UTF8.self))
            self.onExit = nil
            self.onLine = nil
        }
    }

    private func flush(final: Bool) {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...newline)
            deliver(line)
        }
        if final, !buffer.isEmpty {
            deliver(String(decoding: buffer, as: UTF8.self))
            buffer.removeAll()
        }
    }

    private func deliver(_ line: String) {
        guard !line.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in self?.onLine?(line) }
    }

    var isRunning: Bool { process.isRunning }

    /// Interrupts (like Ctrl-C), then terminates if the command ignores it.
    func stop() {
        guard process.isRunning else { return }
        process.interrupt()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [process] in
            if process.isRunning { process.terminate() }
        }
    }
}

/// Apps opened from Finder get a minimal PATH, so tools installed with npm, nvm, Homebrew, etc.
/// aren't visible. This asks the user's login shell for its PATH once and adds common install
/// locations, so command-line tools are found the same way on any Mac.
actor LoginEnvironment {
    static let shared = LoginEnvironment()
    private var cachedPath: [String]?

    func searchPath() async -> [String] {
        if let cachedPath { return cachedPath }
        var dirs: [String] = []
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let marker = "__QC_PATH__"
        // Interactive login shell so ~/.zshrc (where nvm & co. usually live) is read too.
        if let out = try? await Shell.run(shell, ["-ilc", "printf '\(marker)%s\(marker)' \"$PATH\""], timeout: 8),
           let start = out.stdout.range(of: marker),
           let end = out.stdout.range(of: marker, range: start.upperBound..<out.stdout.endIndex) {
            dirs = out.stdout[start.upperBound..<end.lowerBound].split(separator: ":").map(String.init)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        dirs += ["\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin",
                 "\(home)/.npm-global/bin", "\(home)/.bun/bin", "\(home)/.volta/bin", "\(home)/.cargo/bin",
                 "\(home)/bin", "\(home)/Library/pnpm", "\(home)/.local/share/pnpm"]
        // nvm installs: newest Node first.
        let nvm = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            dirs += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }.map { "\(nvm)/\($0)/bin" }
        }
        dirs += (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        var seen = Set<String>()
        let result = dirs.filter { !$0.isEmpty && seen.insert($0).inserted }
        cachedPath = result
        return result
    }

    func find(_ name: String, extraCandidates: [String] = []) async -> String? {
        let fm = FileManager.default
        for dir in await searchPath() {
            let path = (dir as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: path) { return path }
        }
        return extraCandidates.first { fm.isExecutableFile(atPath: $0) }
    }

    /// Environment for running a found tool: the full search PATH, with the tool's own folder
    /// first (so `#!/usr/bin/env node` scripts find the Node they were installed with).
    func environment(for executable: String) async -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let toolDir = ((executable as NSString).resolvingSymlinksInPath as NSString).deletingLastPathComponent
        let linkDir = (executable as NSString).deletingLastPathComponent
        env["PATH"] = ([linkDir, toolDir] + (await searchPath())).joined(separator: ":")
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        return env
    }

    func reset() { cachedPath = nil }
}
