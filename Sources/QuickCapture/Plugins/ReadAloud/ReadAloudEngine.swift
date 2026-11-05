import AppKit
import AVFoundation
import Vision

/// Text in a screenshot, with Apple Vision (on-device). Accurate level without language correction: on a
/// 16-line paper abstract it gave the same words as with correction in 0.38 s instead of 0.65 s; the fast
/// level (0.06 s) made audible mistakes ("lts", "memo.ry.,").
enum ScreenOCR {
    static func text(in url: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            guard let image = NSImage(contentsOf: url) else { throw AppError("Could not read the screenshot.") }
            var rect = NSRect(origin: .zero, size: image.size)
            guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
                throw AppError("Could not read the screenshot.")
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: cg).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }.value
    }
}

/// The Kokoro process (Resources/read_aloud/kokoro_server.py) and the audio queue that plays its chunks.
/// The process is started on demand (on the shortcut, so model loading overlaps the region selection) and
/// exits by itself when idle or over the memory limit; the next request starts it again.
@MainActor
final class ReadAloudEngine {
    struct Launch { let python: String; let script: String; let args: [String]; let env: [String: String] }

    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    /// Created per reading and dropped when it ends: an idle AVQueuePlayer keeps the audio output open, and
    /// with it a "prevent idle sleep" assertion (seen in `pmset -g assertions`).
    private var player: AVQueuePlayer?
    private var generationDone = false
    private var endObserver: Any?
    private var currentID = ""
    private(set) var lastStats: [String: Any] = [:]
    private(set) var lastAudio: URL?
    var onStatus: ((String) -> Void)?

    var isRunning: Bool { process?.isRunning ?? false }
    var isPlaying: Bool { player.map { $0.rate > 0 || !$0.items().isEmpty } ?? false }

    init() {
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.releaseIfFinished() } }
        }
    }

    private func releaseIfFinished() {
        guard let player, generationDone, player.items().isEmpty || (player.items().count == 1 && player.rate == 0) else { return }
        releasePlayer()
    }

    private func releasePlayer() {
        player?.pause()
        player?.removeAllItems()
        player = nil
    }

    private func enqueue(_ url: URL) {
        let p = player ?? AVQueuePlayer()
        player = p
        p.insert(AVPlayerItem(url: url), after: nil)
        if p.rate == 0 { p.play() }
    }

    func start(_ launch: Launch) throws {
        guard !isRunning else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch.python)
        p.arguments = [launch.script, "serve"] + launch.args
        p.environment = launch.env
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.receive(data) }
        }
        p.terminationHandler = { [weak self] _ in DispatchQueue.main.async { self?.process = nil; self?.stdin = nil } }
        try p.run()
        process = p
        stdin = inPipe.fileHandleForWriting
    }

    /// Lines written before the model is loaded wait in the pipe; the server reads them once ready.
    func speak(_ text: String, voice: String, speed: Double) {
        releasePlayer()
        generationDone = false
        currentID = UUID().uuidString
        send(["cmd": "speak", "id": currentID, "text": text, "voice": voice, "speed": speed])
    }

    func stop() {
        releasePlayer()
        currentID = ""
        send(["cmd": "stop"])
    }

    func replay(_ url: URL) {
        releasePlayer()
        generationDone = true
        enqueue(url)
    }

    func shutdown() {
        releasePlayer()
        send(["cmd": "quit"])
        let p = process
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if p?.isRunning == true { p?.terminate() } }
    }

    func requestStats() { send(["cmd": "stats"]) }

    private func send(_ message: [String: Any]) {
        guard let stdin, let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        try? stdin.write(contentsOf: data + Data([0x0A]))
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            handle(event)
        }
    }

    private func handle(_ e: [String: Any]) {
        let kind = e["event"] as? String ?? ""
        if ["done", "stats", "exit", "ready"].contains(kind) { lastStats = e }
        let mine = (e["id"] as? String).map { $0 == currentID } ?? true
        switch kind {
        case "chunk" where mine:
            guard let path = e["path"] as? String else { return }
            enqueue(URL(fileURLWithPath: path))
        case "done" where mine:
            generationDone = true
            if let path = e["path"] as? String { lastAudio = URL(fileURLWithPath: path) }
            releaseIfFinished()
        case "error":
            onStatus?("Read Aloud: " + (e["message"] as? String ?? "error"))
        case "exit" where (e["reason"] as? String) == "memory":
            onStatus?("Read Aloud engine went over its memory limit and was stopped; it restarts on the next read.")
        default: break
        }
    }
}
