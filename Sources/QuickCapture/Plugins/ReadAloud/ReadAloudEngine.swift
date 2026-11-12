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
    /// The panel model for the reading in progress; the engine feeds it chunk text and playback position.
    private(set) var session: ReadAloudSession?
    private var itemIndex: [ObjectIdentifier: Int] = [:]
    private var items: [Int: AVPlayerItem] = [:]
    private var ticker: Timer?
    private(set) var paused = false
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
        session?.finish()
        stopTicking()
    }

    private func releasePlayer() {
        player?.pause()
        player?.removeAllItems()
        player = nil
        itemIndex = [:]
        items = [:]
    }

    private func enqueue(_ url: URL, index: Int) {
        let p = player ?? AVQueuePlayer()
        player = p
        let item = AVPlayerItem(url: url)
        itemIndex[ObjectIdentifier(item)] = index
        items[index] = item
        p.insert(item, after: nil)
        if p.rate == 0 && !paused { p.play() }
        if session?.status != .paused { session?.status = .reading }
        startTicking()
    }

    // MARK: Panel state

    private func startTicking() {
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func stopTicking() { ticker?.invalidate(); ticker = nil }

    private func tick() {
        guard let s = session, s.isActive else { stopTicking(); return }
        guard let p = player else { return }
        for (i, item) in items where s.durations[i] == nil {
            let d = item.duration.seconds
            if d.isFinite, d > 0 { s.durations[i] = d }
        }
        if let item = p.currentItem, let idx = itemIndex[ObjectIdentifier(item)] {
            s.buffering = false
            let t = max(0, item.currentTime().seconds)
            let d = s.durations[idx] ?? item.duration.seconds
            s.current = idx
            s.fraction = d.isFinite && d > 0 ? min(1, t / d) : 0
            s.elapsed = (0..<idx).reduce(0) { $0 + (s.durations[$1] ?? 0) } + t
        } else if !generationDone {
            s.buffering = true
        }
        s.refreshTotal()
    }

    /// Attach the panel model. Called before `speak` / `replay`.
    func attach(_ session: ReadAloudSession) {
        self.session = session
        paused = false
        session.onTogglePause = { [weak self] in self?.togglePause() }
    }

    func togglePause() {
        guard let p = player, let s = session, s.isActive else { return }
        paused.toggle()
        if paused { p.pause(); s.status = .paused } else { p.play(); s.status = .reading }
    }

    func fail(_ message: String) {
        session?.fail(message)
        stopTicking()
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
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.process = nil; self.stdin = nil
                // Died mid-reading (a normal idle exit only happens with no reading in progress).
                if let s = self.session, s.isActive, !self.generationDone, !self.currentID.isEmpty {
                    self.fail("The voice engine stopped unexpectedly. Try again.")
                }
            }
        }
        try p.run()
        process = p
        stdin = inPipe.fileHandleForWriting
    }

    /// Lines written before the model is loaded wait in the pipe; the server reads them once ready.
    func speak(_ text: String, voice: String, speed: Double) {
        releasePlayer()
        paused = false
        generationDone = false
        session?.status = .preparing("Preparing voice…")
        currentID = UUID().uuidString
        send(["cmd": "speak", "id": currentID, "text": text, "voice": voice, "speed": speed])
    }

    /// Ends the reading: playback and generation stop; the panel is closed by whoever asked.
    func stop() {
        releasePlayer()
        stopTicking()
        paused = false
        currentID = ""
        send(["cmd": "stop"])
    }

    func replay(_ url: URL, session replaySession: ReadAloudSession) {
        releasePlayer()
        attach(replaySession)
        generationDone = true
        let text = (try? String(contentsOf: url.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)) ?? ""
        if !text.isEmpty { replaySession.setChunks([text]) }
        replaySession.current = 0
        enqueue(url, index: 0)
    }

    func shutdown() {
        session?.onClose?()
        session = nil
        stopTicking()
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
        case "ready" where session?.isActive == true && !generationDone:
            if case .preparing = session?.status { session?.status = .preparing("Generating voice…") }
        case "start" where mine:
            if let list = e["chunks"] as? [String], !list.isEmpty { session?.setChunks(list) }
        case "chunk" where mine:
            guard let path = e["path"] as? String else { return }
            let index = e["index"] as? Int ?? 0
            if let d = e["audio_s"] as? Double, d > 0 { session?.durations[index] = d }
            enqueue(URL(fileURLWithPath: path), index: index)
        case "done" where mine:
            generationDone = true
            if let path = e["path"] as? String { lastAudio = URL(fileURLWithPath: path) }
            releaseIfFinished()
        case "error":
            let message = "Read Aloud: " + (e["message"] as? String ?? "error")
            fail(message)
            onStatus?(message)
        case "exit" where (e["reason"] as? String) == "memory":
            if session?.isActive == true, !generationDone { fail("The voice engine went over its memory limit and was stopped. Try again, or raise the limit in Settings.") }
            onStatus?("Read Aloud engine went over its memory limit and was stopped; it restarts on the next read.")
        default: break
        }
    }
}
