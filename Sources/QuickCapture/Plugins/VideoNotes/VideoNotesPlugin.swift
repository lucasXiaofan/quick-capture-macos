import AVFoundation
import AppKit
import SwiftUI

struct VideoNotesSettings: PluginSettings {
    /// Parent of the "quick-capture-video" folder. Empty means ~/Movies.
    var folder = ""
    /// Dashboard columns, left to right. Empty by default: add your own from the dashboard.
    var tags: [String] = []
    var microphone = true
    /// "off", "efficient" (HEVC) or "smart" (HEVC + blurred background); see VideoCompressor.
    var compression = VideoCompressor.Mode.smart.rawValue
    /// Playback volume in percent, on top of the system volume. Above 100 boosts quiet recordings.
    var volume = 100
    /// Screen + camera recordings: the camera square's side in percent of the video height, and its corner.
    var screenCameraSize = 25
    var screenCameraCorner = ScreenCamCapture.Corner.bottomLeft.rawValue

    /// Selfies are saved the way the preview shows them (mirrored, like looking in a mirror).
    var selfieMirror = true
    /// Meeting audio: also record the Mac's own sound (needs Screen Recording), stored at this quality.
    var meetingSystemAudio = true
    var meetingCompression = AudioCompression.compact.rawValue
    /// The small REC pill at the top right while a meeting is recorded (never visible in screen sharing).
    var meetingIndicator = true
    /// After a selfie / a meeting recording, ask for a tag and note (Skip leaves it untagged).
    var selfiePrompt = true
    var meetingPrompt = true
    /// Dashboard: the Untagged column after the tags instead of before them.
    var untaggedLast = false
    /// Speech to text once a meeting recording has stopped; see Transcriber.
    var transcriptionEngine = Transcriber.Engine.auto.rawValue
    /// Whisper language code ("zh", "en", …) or "auto".
    var transcriptionLanguage = "auto"
    /// Steers Whisper towards Simplified Chinese with English words left in English.
    var transcriptionPrompt = "以下是普通话和English混合的会议录音，请使用简体中文和英文。"
    /// A model file (.bin for whisper.cpp, .pt for OpenAI Whisper) or name; empty picks the best one found.
    var transcriptionModel = ""

    static let volumeRange = 25...800
    static let screenCameraSizeRange = 10...50

    enum CodingKeys: String, CodingKey {
        case folder, tags, microphone, compression, volume
        case screenCameraSize = "screen_camera_size", screenCameraCorner = "screen_camera_corner"
        case selfieMirror = "selfie_mirror"
        case meetingSystemAudio = "meeting_system_audio", meetingCompression = "meeting_compression"
        case meetingIndicator = "meeting_indicator"
        case selfiePrompt = "selfie_prompt", meetingPrompt = "meeting_prompt"
        case untaggedLast = "untagged_last"
        case transcriptionEngine = "transcription_engine", transcriptionLanguage = "transcription_language"
        case transcriptionPrompt = "transcription_prompt", transcriptionModel = "transcription_model"
    }
}

/// Media Capture (id "video_notes" for config compatibility): short self-control videos, daily selfies and
/// transcribed meeting recordings, each with one shortcut, all tagged and browsable in one dashboard.
@MainActor
final class VideoNotesPlugin: ObservableObject, Plugin {
    nonisolated static let pluginID = "video_notes"

    let id = VideoNotesPlugin.pluginID
    let name = "Media Capture"
    let summary = "Record a quick video, take a daily selfie, or record a meeting (transcribed on this Mac) with one shortcut; tag them and find them in one dashboard."
    let symbol = "video.badge.plus"
    var enabledByDefault: Bool { false }
    let actions = [
        PluginAction(id: "dashboard", title: "Media Dashboard", symbol: "rectangle.split.3x1", defaultShortcut: nil),
        PluginAction(id: "record", title: "Record (press again to pause)", symbol: "record.circle", defaultShortcut: "<ctrl>+<alt>+r"),
        PluginAction(id: "record_screen", title: "Record Screen + Camera (press again to pause)", symbol: "pip",
                     defaultShortcut: "<ctrl>+<alt>+<shift>+r"),
        PluginAction(id: "pause", title: "Pause / Resume Recording", symbol: "pause.circle", defaultShortcut: "<ctrl>+<alt>+p"),
        PluginAction(id: "stop", title: "Stop Recording", symbol: "stop.circle", defaultShortcut: "<ctrl>+<alt>+s"),
        PluginAction(id: "discard", title: "Discard Recording…", symbol: "trash", defaultShortcut: "<ctrl>+<alt>+x"),
        PluginAction(id: "quick_play", title: "Quick Play (then 1–5)", symbol: "play.circle", defaultShortcut: "<ctrl>+<alt>+v"),
        PluginAction(id: "selfie", title: "Selfie (press again to take it)", symbol: "camera", defaultShortcut: "<ctrl>+<alt>+f"),
        PluginAction(id: "meeting", title: "Record Meeting Audio (press again to pause)", symbol: "waveform.circle",
                     defaultShortcut: "<ctrl>+<alt>+a"),
        PluginAction(id: "meeting_stop", title: "Stop Meeting Recording", symbol: "stop.circle", defaultShortcut: "<ctrl>+<alt>+<shift>+a"),
    ] + (1...VideoStore.slotCount).map {
        PluginAction(id: "play_\($0)", title: "Play Quick Slot \($0) Directly", symbol: "\($0).circle", defaultShortcut: nil)
    }

    /// Videos; `selfies` and `recordings` are the other two libraries (see `MediaKind`).
    let store = VideoStore(kind: .video)
    let selfies = VideoStore(kind: .selfie)
    let recordings = VideoStore(kind: .audio)
    /// Tag and note given to a meeting before its file is ready (compression runs after stop), by base name.
    private var pendingMeta: [String: (tag: String?, note: String)] = [:]
    let recorder = VideoRecorder()
    let meeting = MeetingRecorder()
    private let selfie = SelfieCamera()
    /// Meeting recordings being compressed or transcribed, by file name.
    @Published private(set) var transcribing: Set<String> = []
    /// The dashboard's Tag Order panel is showing. Open by default; remembered on this Mac.
    @Published var arrangingTags = UserDefaults.standard.object(forKey: "MediaCaptureTagOrderPanel") as? Bool ?? true {
        didSet { UserDefaults.standard.set(arrangingTags, forKey: "MediaCaptureTagOrderPanel") }
    }
    private var dashboard: NSWindow?
    /// Which library the dashboard shows; lets the menu open it on Selfies or Recordings.
    let dashboardTab = DashboardTab()
    private var prompt: NSPanel?
    private var picker: KeyPanel?
    private let player = VideoPlayerWindow()
    /// Set when the user discards while recording: the file is trashed as soon as it's complete.
    private var discardWhenFinished = false
    /// The just-recorded video or selfie whose tag prompt is open (the discard shortcut applies to it).
    private var freshFile: (kind: MediaKind, file: String)?

    var settings: VideoNotesSettings { state.settings(VideoNotesSettings.self, for: id) }

    func update(_ change: (inout VideoNotesSettings) -> Void) throws {
        try state.updateSettings(VideoNotesSettings.self, for: id, change)
    }

    var libraryDirectory: URL {
        let path = (settings.folder as NSString).expandingTildeInPath
        let base = path.isEmpty
            ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies", isDirectory: true)
            : URL(fileURLWithPath: path, isDirectory: true)
        return base.appendingPathComponent("quick-capture-video", isDirectory: true)
    }

    /// Selfies and meeting audio sit next to the video library.
    var selfieDirectory: URL { directory(.selfie) }
    var audioDirectory: URL { directory(.audio) }

    func directory(_ kind: MediaKind) -> URL {
        libraryDirectory.deletingLastPathComponent().appendingPathComponent(kind.folderName, isDirectory: true)
    }

    func store(_ kind: MediaKind) -> VideoStore {
        switch kind {
        case .video: store
        case .selfie: selfies
        case .audio: recordings
        }
    }

    private func loadLibraries() {
        for kind in MediaKind.allCases { store(kind).load(from: directory(kind)) }
    }

    func defaultSettings() -> [String: JSONValue] { encodeDefaults(VideoNotesSettings.self) }

    func validate(_ config: AppConfig) throws {
        let s = try config.settings(VideoNotesSettings.self, for: id)
        if s.tags.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            throw AppError("video_notes.tags can't contain empty names.")
        }
        guard VideoNotesSettings.volumeRange.contains(s.volume) else {
            throw AppError("video_notes.volume must be between \(VideoNotesSettings.volumeRange.lowerBound) and \(VideoNotesSettings.volumeRange.upperBound) (percent).")
        }
        guard VideoCompressor.Mode(rawValue: s.compression) != nil else {
            throw AppError("video_notes.compression must be one of: \(VideoCompressor.Mode.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        guard VideoNotesSettings.screenCameraSizeRange.contains(s.screenCameraSize) else {
            throw AppError("video_notes.screen_camera_size must be between \(VideoNotesSettings.screenCameraSizeRange.lowerBound) and \(VideoNotesSettings.screenCameraSizeRange.upperBound) (percent of the video height).")
        }
        guard ScreenCamCapture.Corner(rawValue: s.screenCameraCorner) != nil else {
            throw AppError("video_notes.screen_camera_corner must be one of: \(ScreenCamCapture.Corner.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        guard AudioCompression(rawValue: s.meetingCompression) != nil else {
            throw AppError("video_notes.meeting_compression must be one of: \(AudioCompression.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        guard Transcriber.Engine(rawValue: s.transcriptionEngine) != nil else {
            throw AppError("video_notes.transcription_engine must be one of: \(Transcriber.Engine.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
    }

    // MARK: Actions

    func perform(_ action: PluginAction) {
        switch action.id {
        case "record":
            if recorder.isRecording { recorder.togglePause() } else { startRecording() }
        case "record_screen":
            if recorder.isRecording { recorder.togglePause() } else { startRecording(screen: true) }
        case "pause":
            if recorder.isRecording { recorder.togglePause() } else { Toast.show("Not recording", symbol: "video.slash", isError: true) }
        case "stop":
            if recorder.isRecording { recorder.stop() } else { Toast.show("Not recording", symbol: "video.slash", isError: true) }
        case "discard":
            if recorder.isRecording { discardRecording() }
            else if let fresh = freshFile, prompt?.isVisible == true { discard(fresh.file, kind: fresh.kind) }
            else { Toast.show("Nothing to discard", symbol: "video.slash", isError: true) }
        case "selfie": takeSelfie()
        case "meeting":
            if meeting.isRecording { meeting.togglePause() } else { startMeeting() }
        case "meeting_stop":
            if meeting.isRecording { meeting.stop() } else { Toast.show("No meeting recording", symbol: "waveform.slash", isError: true) }
        case "quick_play": showPicker()
        case "dashboard": showDashboard()
        default:
            if action.id.hasPrefix("play_"), let slot = Int(action.id.dropFirst(5)) { playSlot(slot) }
        }
    }

    /// The dashboard; while recording, Stop matters more than anything else.
    func primaryActions() -> [PluginAction] {
        if meeting.isRecording && !recorder.isRecording { return [action("meeting_stop"), action("meeting")].compactMap { $0 } }
        return [action(recorder.isRecording ? "stop" : "dashboard"), action("record")].compactMap { $0 }
    }

    /// Pause and Stop only matter while recording; per-slot play stays shortcut-only.
    func showsInMenu(_ action: PluginAction) -> Bool {
        switch action.id {
        case "pause", "stop", "discard": recorder.isRecording
        case "meeting_stop": meeting.isRecording
        default: !action.id.hasPrefix("play_")
        }
    }

    // MARK: Lifecycle

    func activate() {
        recorder.onFinish = { [weak self] url, error in self?.recordingFinished(url, error) }
        meeting.onFinish = { [weak self] capture, error in self?.meetingFinished(capture, error) }
        loadLibraries()
        player.gain = Float(settings.volume) / 100
        recoverMeetings()
    }

    func deactivate() {
        recorder.stop()
        meeting.stop()
        selfie.close()
        dashboard?.orderOut(nil)
        dashboard = nil
        prompt?.orderOut(nil)
        prompt = nil
        picker?.orderOut(nil)
        picker = nil
        player.close()
    }

    func configDidChange() {
        player.gain = Float(settings.volume) / 100
        if store.directory?.path != libraryDirectory.path { loadLibraries() }
    }

    // MARK: Recording

    private func startRecording(screen: Bool = false) {
        if screen && !CGPreflightScreenCaptureAccess() {
            state.requestScreenRecording()
            Toast.show("Screen + camera needs Screen Recording permission (System Settings → Privacy → Screen Recording).",
                       symbol: "lock", isError: true)
            return
        }
        Task {
            guard await requestAccess(.video) else {
                Toast.show("Media Capture needs camera access (System Settings → Privacy → Camera).", symbol: "camera", isError: true)
                return
            }
            let microphone = settings.microphone ? await requestAccess(.audio) : false
            let dir = libraryDirectory
            let stamp = DateFormatter()
            stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let s = settings
                let options = screen ? ScreenCamCapture.Options(
                    cameraSize: CGFloat(s.screenCameraSize) / 100,
                    corner: ScreenCamCapture.Corner(rawValue: s.screenCameraCorner) ?? .bottomLeft) : nil
                try await recorder.start(to: dir.appendingPathComponent("\(screen ? "Screen" : "Video") \(stamp.string(from: Date())).mov"),
                                         microphone: microphone, screen: options)
                Toast.show("Recording — \(shortcutText("stop")) to stop", symbol: "record.circle")
            } catch {
                Toast.show(error.localizedDescription, symbol: "video.slash", isError: true)
            }
        }
    }

    private func recordingFinished(_ url: URL, _ error: Error?) {
        if discardWhenFinished {
            discardWhenFinished = false
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            store.load(from: libraryDirectory)
            Toast.show("Recording discarded (moved to the Trash)", symbol: "trash")
            return
        }
        store.load(from: libraryDirectory)
        guard store.video(url.lastPathComponent) != nil else {
            Toast.show(error?.localizedDescription ?? "The recording was not saved.", symbol: "video.slash", isError: true)
            return
        }
        if let error { Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle", isError: true) }
        edit(url.lastPathComponent, fresh: true)
        if recorder.isScreenRecording { store.update(url.lastPathComponent) { $0.screen = true } }
        if let mode = VideoCompressor.Mode(rawValue: settings.compression), mode != .off {
            compress(url.lastPathComponent, mode: mode)
        }
    }

    /// Re-encodes a video in the background and swaps it in only if the result is complete and smaller.
    func compress(_ file: String, mode: VideoCompressor.Mode? = nil) {
        Task { await compressNow(file, mode: mode, announce: true) }
    }

    /// Compresses every video not yet at the current `VideoCompressor.version`, one after another.
    func compressAll() {
        let files = store.videos.filter { $0.compressionVersion < VideoCompressor.version }.map(\.file)
        guard !files.isEmpty else { Toast.show("Every video is already compressed.", symbol: "checkmark"); return }
        Toast.show("Compressing \(files.count) video\(files.count == 1 ? "" : "s") in the background…", symbol: "arrow.down.right.and.arrow.up.left")
        Task {
            var saved: Int64 = 0
            for file in files { saved += await compressNow(file, announce: false) }
            Toast.show("Done — saved \(formattedSize(saved))", symbol: "arrow.down.right.and.arrow.up.left")
        }
    }

    /// Returns the bytes saved.
    @discardableResult
    private func compressNow(_ file: String, mode: VideoCompressor.Mode? = nil, announce: Bool) async -> Int64 {
        let mode = mode ?? VideoCompressor.Mode(rawValue: settings.compression).flatMap { $0 == .off ? nil : $0 } ?? .smart
        guard let item = store.video(file), let source = store.url(item), !store.busy.contains(file) else { return 0 }
        store.setBusy(file, true)
        let before = item.size
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("quick-capture-\(UUID().uuidString).mov")
        defer { store.setBusy(file, false); try? FileManager.default.removeItem(at: temp) }
        let markDone = { self.store.update(file) { $0.compressed = true; $0.compressionVersion = VideoCompressor.version } }
        do {
            try await VideoCompressor.compress(source, to: temp, target: VideoCompressor.target(mode: mode, screen: item.screen)) { _ in }
            let sizeOf = { (u: URL) in Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            let after = sizeOf(temp)
            let original = try await AVURLAsset(url: source).load(.duration).seconds
            let result = try await AVURLAsset(url: temp).load(.duration).seconds
            guard after > 0, abs(original - result) < 1 else { throw AppError("Compression didn't finish cleanly; the original is untouched.") }
            guard store.video(file) != nil else { return 0 }   // discarded meanwhile
            guard after < before else {
                markDone()
                if announce { Toast.show("Already small — kept the original.", symbol: "arrow.down.right.and.arrow.up.left") }
                return 0
            }
            _ = try FileManager.default.replaceItemAt(source, withItemAt: temp)
            markDone()
            store.load(from: libraryDirectory)
            if announce { Toast.show("Compressed \(formattedSize(before)) → \(formattedSize(after))", symbol: "arrow.down.right.and.arrow.up.left") }
            return before - after
        } catch {
            guard store.video(file) != nil else { return 0 }   // discarded meanwhile
            Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle", isError: true)
            return 0
        }
    }

    // MARK: Selfie

    private func takeSelfie() {
        if selfie.isOpen { selfie.shoot(); return }
        if recorder.isRecording { Toast.show("The camera is busy recording.", symbol: "camera", isError: true); return }
        Task {
            guard await requestAccess(.video) else {
                Toast.show("Selfies need camera access (System Settings → Privacy → Camera).", symbol: "camera", isError: true)
                return
            }
            do {
                try selfie.open(saveIn: selfieDirectory, mirror: settings.selfieMirror) { [weak self] url in
                    guard let self else { return }
                    selfies.reload()
                    guard settings.selfiePrompt else { Toast.show("Selfie saved — \(url.lastPathComponent)", symbol: "camera"); return }
                    // After the photo has been on screen for a moment and the camera window is gone.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                        self?.edit(url.lastPathComponent, kind: .selfie, fresh: true)
                    }
                }
            } catch {
                Toast.show(error.localizedDescription, symbol: "camera", isError: true)
            }
        }
    }

    func revealSelfies() {
        try? FileManager.default.createDirectory(at: selfieDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(selfieDirectory)
    }

    // MARK: Meeting audio

    private func startMeeting() {
        let s = settings
        if s.meetingSystemAudio && !CGPreflightScreenCaptureAccess() { state.requestScreenRecording() }
        Task {
            let microphone = await requestAccess(.audio)
            let stamp = DateFormatter()
            stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
            do {
                try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
                try await meeting.start(to: audioDirectory.appendingPathComponent("Meeting \(stamp.string(from: Date())).m4a"),
                                        microphone: microphone, systemAudio: s.meetingSystemAudio,
                                        compression: AudioCompression(rawValue: s.meetingCompression) ?? .compact,
                                        indicator: s.meetingIndicator)
                let sources = [microphone ? "microphone" : nil, meeting.hasSystemAudio ? "Mac sound" : nil].compactMap { $0 }
                var message = "Recording \(sources.joined(separator: " + ")) — \(shortcutText("meeting_stop")) to stop"
                if s.meetingSystemAudio && !meeting.hasSystemAudio { message += " (no Mac sound: needs Screen Recording)" }
                Toast.show(message, symbol: "waveform.circle")
            } catch {
                Toast.show(error.localizedDescription, symbol: "waveform.slash", isError: true)
            }
        }
    }

    private func meetingFinished(_ capture: AudioCapture, _ error: Error?) {
        if let error, !FileManager.default.fileExists(atPath: capture.partial.path) {
            Toast.show(error.localizedDescription, symbol: "waveform.slash", isError: true)
            return
        }
        Toast.show("Meeting saved — compressing, then transcribing…", symbol: "waveform")
        process(partial: capture.partial, destination: capture.destination, compression: capture.compression)
        if settings.meetingPrompt { askAboutMeeting(capture.destination) }
    }

    /// Partial recordings left by a crash or quit: finish them like a normal stop.
    private func recoverMeetings() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: audioDirectory, includingPropertiesForKeys: nil)) ?? []
        for partial in files where partial.lastPathComponent.hasSuffix(".part.mov") {
            let base = partial.lastPathComponent.replacingOccurrences(of: ".part.mov", with: "")
            let destination = audioDirectory.appendingPathComponent(base + ".m4a")
            guard !fm.fileExists(atPath: destination.path) else { continue }
            process(partial: partial, destination: destination,
                    compression: AudioCompression(rawValue: settings.meetingCompression) ?? .compact)
        }
    }

    /// The tag-and-note prompt right after stopping, while the file is still being compressed. What you enter is
    /// kept until the file exists, then stored like a video's.
    private func askAboutMeeting(_ destination: URL) {
        let base = destination.deletingPathExtension().lastPathComponent
        showPrompt(title: base, question: "What was this meeting about?", tag: nil, note: "",
                   onSave: { [weak self] tag, note in
                       guard let self else { return }
                       if let tag { addTag(tag) }
                       if let item = recordings.videos.first(where: { $0.displayName == base }) {
                           recordings.update(item.file) { $0.tag = tag; $0.note = note }
                       } else {
                           pendingMeta[base] = (tag, note)
                       }
                       closePrompt()
                   }, onDiscard: nil)
    }

    private func applyPendingMeta() {
        for (base, meta) in pendingMeta {
            guard let item = recordings.videos.first(where: { $0.displayName == base }) else { continue }
            recordings.update(item.file) { $0.tag = meta.tag; $0.note = meta.note }
            pendingMeta[base] = nil
        }
    }

    /// Compresses the partial recording into the final .m4a, then writes a transcript next to it.
    private func process(partial: URL, destination: URL, compression: AudioCompression) {
        let file = destination.lastPathComponent
        guard !transcribing.contains(file) else { return }
        transcribing.insert(file)
        Task {
            defer { transcribing.remove(file) }
            var audio = destination
            defer { recordings.reload() }
            do {
                try await compression.finalize(partial, to: destination)
            } catch {
                // Keep the uncompressed recording rather than lose it.
                audio = destination.deletingPathExtension().appendingPathExtension("mov")
                try? FileManager.default.moveItem(at: partial, to: audio)
                Toast.show("Couldn't compress the recording (\(error.localizedDescription)); kept it as .mov.",
                           symbol: "exclamationmark.triangle", isError: true)
            }
            recordings.reload()
            applyPendingMeta()
            await transcribe(audio)
        }
    }

    /// Writes `<recording>.txt` next to the audio once the recording is finished. Also used by "Transcribe Again".
    func transcribe(_ audio: URL) async {
        let s = settings
        guard let engine = Transcriber.Engine(rawValue: s.transcriptionEngine), engine != .off else {
            Toast.show("Meeting saved — \(audio.lastPathComponent)", symbol: "waveform")
            return
        }
        let options = Transcriber.Options(engine: engine, language: s.transcriptionLanguage,
                                          prompt: s.transcriptionPrompt, model: s.transcriptionModel)
        let transcript = audio.deletingPathExtension().appendingPathExtension("txt")
        do {
            let result = try await Transcriber.transcribe(audio, options: options)
            let duration = try? await AVURLAsset(url: audio).load(.duration).seconds
            let title = audio.deletingPathExtension().lastPathComponent
            try Transcriber.text(result, title: title, duration: duration).write(to: transcript, atomically: true, encoding: .utf8)
            recordings.reload()
            Toast.show("Transcript ready — \(transcript.lastPathComponent)", symbol: "text.quote")
        } catch {
            Toast.show("Saved \(audio.lastPathComponent), but transcription failed: \(error.localizedDescription)",
                       symbol: "exclamationmark.triangle", isError: true)
        }
    }

    func revealAudio() {
        try? FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(audioDirectory)
    }

    /// Writes a recording's transcript again (dashboard card).
    func transcribeAgain(_ item: VideoItem) {
        guard let url = recordings.url(item), !transcribing.contains(item.file) else { return }
        Toast.show("Transcribing \(item.title)…", symbol: "text.quote")
        transcribing.insert(item.file)
        Task {
            await transcribe(url)
            transcribing.remove(item.file)
            recordings.reload()
        }
    }

    func openTranscript(_ item: VideoItem) {
        guard let url = recordings.transcriptURL(item) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Picks a recording and writes its transcript again (e.g. after installing whisper.cpp or changing the language).
    func transcribeAgain() {
        let panel = NSOpenPanel()
        panel.directoryURL = audioDirectory
        panel.allowedContentTypes = [.audio, .movie]
        panel.message = "Choose a recording to transcribe again."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Toast.show("Transcribing \(url.lastPathComponent)…", symbol: "text.quote")
        transcribing.insert(url.lastPathComponent)
        Task {
            await transcribe(url)
            transcribing.remove(url.lastPathComponent)
        }
    }

    func menuItems() -> [NSMenuItem] {
        [ClosureMenuItem("Selfies…", symbol: "person.crop.square") { [weak self] in self?.showDashboard(.selfie) },
         ClosureMenuItem("Meeting Recordings & Transcripts…", symbol: "waveform") { [weak self] in self?.showDashboard(.audio) },
         ClosureMenuItem("Transcribe a Recording Again…", symbol: "text.quote") { [weak self] in self?.transcribeAgain() }]
    }

    // MARK: Discarding

    /// Pauses, asks, then stops and trashes the recording — or resumes if you change your mind.
    private func discardRecording() {
        let wasRunning = recorder.phase == .recording
        if wasRunning { recorder.togglePause() }
        guard confirmDiscard(keepTitle: "Keep Recording") else {
            if wasRunning, recorder.phase == .paused { recorder.togglePause() }
            return
        }
        discardWhenFinished = true
        recorder.stop()
    }

    /// Throws away a recording or selfie whose tag prompt is open.
    private func discard(_ file: String, kind: MediaKind = .video) {
        guard confirmDiscard(keepTitle: "Keep", noun: kind == .selfie ? "selfie" : "recording") else { return }
        closePrompt()
        do {
            try store(kind).delete(file)
            Toast.show("\(kind == .selfie ? "Selfie" : "Recording") discarded (moved to the Trash)", symbol: "trash")
        } catch {
            Toast.show(error.localizedDescription, isError: true)
        }
    }

    private func confirmDiscard(keepTitle: String, noun: String = "recording") -> Bool {
        let alert = NSAlert()
        alert.messageText = "Discard this \(noun)?"
        alert.informativeText = "It moves to the Trash and won't appear in Media Capture."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: keepTitle)
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func requestAccess(_ type: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: type)
        default: return false
        }
    }

    func shortcutText(_ actionID: String) -> String {
        action(actionID).flatMap { state.config.shortcut($0, of: self)?.display } ?? "its shortcut"
    }

    // MARK: Tags

    /// Dashboard order: the saved list, then any tag found only on videos.
    var allTags: [String] {
        let used = Set(MediaKind.allCases.flatMap { store($0).videos.compactMap(\.tag) })
        return settings.tags + used.subtracting(settings.tags).sorted()
    }

    func setTags(_ tags: [String]) { try? update { $0.tags = tags } }

    /// New tags go next to Untagged, where they're easy to find.
    func addTag(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !allTags.contains(name) else { return }
        setTags([name] + allTags)
    }

    enum TagMove { case top, up, down, bottom }

    /// Moves the given tags as a group, keeping their order among themselves.
    func moveTags(_ names: Set<String>, _ move: TagMove) {
        var tags = allTags
        let selected = { (i: Int) in names.contains(tags[i]) }
        switch move {
        case .top: tags = tags.filter(names.contains) + tags.filter { !names.contains($0) }
        case .bottom: tags = tags.filter { !names.contains($0) } + tags.filter(names.contains)
        case .up:
            for i in tags.indices.dropFirst() where selected(i) && !selected(i - 1) { tags.swapAt(i, i - 1) }
        case .down:
            for i in tags.indices.dropLast().reversed() where selected(i) && !selected(i + 1) { tags.swapAt(i, i + 1) }
        }
        if tags != allTags { setTags(tags) }
    }

    /// Items per tag across videos, selfies and recordings.
    var tagCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for kind in MediaKind.allCases { for item in store(kind).videos { if let tag = item.tag { counts[tag, default: 0] += 1 } } }
        return counts
    }

    /// Most used first; ties keep their current order.
    func sortTagsByUse() {
        let counts = tagCounts
        let tags = allTags.enumerated().sorted { a, b in
            let (ca, cb) = (counts[a.element] ?? 0, counts[b.element] ?? 0)
            return ca != cb ? ca > cb : a.offset < b.offset
        }.map(\.element)
        setTags(tags)
    }

    /// Asks first. The videos are kept and become untagged.
    @discardableResult
    func deleteTags(_ names: [String]) -> Bool {
        guard !names.isEmpty else { return false }
        let affected = MediaKind.allCases.flatMap { store($0).videos }.filter { $0.tag.map(names.contains) == true }.count
        let alert = NSAlert()
        alert.messageText = names.count == 1 ? "Delete the tag “\(names[0])”?" : "Delete \(names.count) tags?"
        alert.informativeText = (names.count > 1 ? names.joined(separator: ", ") + "\n\n" : "")
            + "\(affected) item\(affected == 1 ? "" : "s") will move to Untagged. Nothing is deleted."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete Tag\(names.count == 1 ? "" : "s")")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        for kind in MediaKind.allCases { store(kind).clearTags(Set(names)) }
        setTags(allTags.filter { !names.contains($0) })
        return true
    }

    /// Asks for a name and adds the tag.
    func promptNewTag() {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        let alert = NSAlert()
        alert.messageText = "New tag"
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { addTag(field.stringValue) }
    }

    // MARK: Library actions

    /// Videos and recordings play in the small player; selfies open in Preview.
    func play(_ item: VideoItem, kind: MediaKind = .video) {
        guard let url = store(kind).url(item) else { return }
        if kind == .selfie { NSWorkspace.shared.open(url) } else { player.play(url, title: item.title) }
    }

    func openInDefaultPlayer(_ item: VideoItem, kind: MediaKind = .video) {
        guard let url = store(kind).url(item) else { return }
        NSWorkspace.shared.open(url)
    }

    func reveal(_ item: VideoItem, kind: MediaKind = .video) {
        guard let url = store(kind).url(item) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func revealLibrary(_ kind: MediaKind = .video) {
        let dir = directory(kind)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    func delete(_ item: VideoItem, kind: MediaKind = .video) {
        let alert = NSAlert()
        alert.messageText = "Move this \(kind.noun) to the Trash?"
        alert.informativeText = "\(item.title) · \(formattedSize(item.size))"
            + (kind == .audio && store(kind).transcriptURL(item) != nil ? "\nIts transcript goes too." : "")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try store(kind).delete(item.file) } catch { Toast.show(error.localizedDescription, isError: true) }
    }

    // MARK: Windows

    private func present(_ panel: NSPanel) {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Tag-and-note prompt for one item. `fresh` (just recorded or taken) adds a Discard button.
    func edit(_ file: String, kind: MediaKind = .video, fresh: Bool = false) {
        let library = store(kind)
        library.reload()
        guard let item = library.video(file) else { return }
        freshFile = fresh ? (kind, file) : nil
        let question = switch kind {
        case .video: "What's this video about?"
        case .selfie: "How are you today?"
        case .audio: "What was this meeting about?"
        }
        showPrompt(title: item.displayName, question: question, tag: item.tag, note: item.note,
                   onSave: { [weak self] tag, note in
                       guard let self else { return }
                       if let tag { addTag(tag) }
                       store(kind).update(file) { $0.tag = tag; $0.note = note }
                       closePrompt()
                   },
                   onDiscard: fresh ? { [weak self] in self?.discard(file, kind: kind) } : nil)
    }

    private func closePrompt() {
        prompt?.orderOut(nil)
        freshFile = nil
    }

    private func showPrompt(title: String, question: String, tag: String?, note: String,
                            onSave: @escaping (String?, String) -> Void, onDiscard: (() -> Void)?) {
        prompt?.orderOut(nil)
        let view = VideoPromptView(
            title: title, question: question, tags: allTags, tag: tag, note: note,
            onSave: onSave,
            onCancel: { [weak self] in self?.closePrompt() },
            onDiscard: onDiscard)
        let host = NSHostingView(rootView: view)
        // Non-activating, like Spotlight: it takes the keyboard even when macOS doesn't let a menu-bar app come to
        // the front (it often doesn't after a global shortcut), so typing goes into the prompt, not the app behind it.
        let panel = KeyPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                             styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.becomesKeyOnlyIfNeeded = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        panel.center()
        prompt = panel
        present(panel)
    }

    private func showPicker() {
        if let picker, picker.isVisible { picker.orderOut(nil); return }
        store.load(from: libraryDirectory)
        let slots = (1...VideoStore.slotCount).map { store.video(slot: $0) }
        let view = QuickPlayView(videos: slots) { [weak self] slot in self?.playSlot(slot) }
        let host = NSHostingView(rootView: view)
        let panel = KeyPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.closeWhenResigned = true
        panel.contentView = host
        panel.onKey = { [weak self] event in
            if event.keyCode == 53 { self?.picker?.orderOut(nil); return true }
            if let slot = Int(event.charactersIgnoringModifiers ?? ""), (1...VideoStore.slotCount).contains(slot) {
                self?.playSlot(slot)
                return true
            }
            return false
        }
        panel.center()
        picker = panel
        present(panel)
    }

    private func playSlot(_ slot: Int) {
        guard let item = store.video(slot: slot) else { return }
        picker?.orderOut(nil)
        play(item)
    }

    func showDashboard(_ kind: MediaKind? = nil) {
        loadLibraries()
        if let kind { dashboardTab.kind = kind }
        if dashboard == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Media Capture"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: VideoDashboardView(plugin: self, tab: dashboardTab, state: state,
                                                                            recorder: recorder, meeting: meeting))
            window.setFrameAutosaveName("VideoNotesDashboard")
            window.center()
            dashboard = window
        }
        NSApp.activate(ignoringOtherApps: true)
        dashboard?.makeKeyAndOrderFront(nil)
    }

    // MARK: Setup & settings

    var setupIssues: [String] {
        let camera = AVCaptureDevice.authorizationStatus(for: .video)
        return camera == .denied || camera == .restricted ? ["Media Capture needs camera access."] : []
    }

    func setupView() -> AnyView? { AnyView(VideoNotesSetupSteps(state: state)) }
    func overviewView() -> AnyView? { AnyView(VideoNotesOverview(plugin: self, store: store)) }
    func settingsView() -> AnyView? { AnyView(VideoNotesSettingsSections(plugin: self, state: state, store: store)) }
}

private struct VideoNotesSetupSteps: View {
    @ObservedObject var state: AppState
    @State private var camera = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 10) {
            row(.video, status: camera, symbol: "camera", title: "Camera", optional: false,
                detail: "Needed to record. Videos stay on this Mac.", pane: "Privacy_Camera")
            row(.audio, status: microphone, symbol: "mic", title: "Microphone", optional: true,
                detail: "Records your voice with the video.", pane: "Privacy_Microphone")
            StepRow(done: state.screenGranted, symbol: "pip", title: "Screen Recording",
                    detail: state.screenGranted ? "Granted."
                        : "Only for Screen + Camera recordings and the Mac's sound in meeting recordings.", optional: true) {
                if !state.screenGranted {
                    HStack {
                        Button(state.screenRequested ? "Open Settings" : "Grant Access…") { state.requestScreenRecording() }
                        if state.screenRequested { Button("Relaunch") { state.relaunch() } }
                    }
                }
            }
        }
        .onReceive(timer) { _ in
            state.refreshPermissions()
            camera = AVCaptureDevice.authorizationStatus(for: .video)
            microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        }
    }

    private func row(_ type: AVMediaType, status: AVAuthorizationStatus, symbol: String, title: String,
                     optional: Bool, detail: String, pane: String) -> some View {
        StepRow(done: status == .authorized, symbol: symbol, title: title,
                detail: status == .authorized ? "Granted." : detail, optional: optional) {
            if status != .authorized {
                Button(status == .notDetermined ? "Grant Access…" : "Open Settings") {
                    if status == .notDetermined { AVCaptureDevice.requestAccess(for: type) { _ in } }
                    else { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!) }
                }
            }
        }
    }
}

/// Top of the Settings page: the dashboard is what people come here for.
private struct VideoNotesOverview: View {
    @ObservedObject var plugin: VideoNotesPlugin
    @ObservedObject var store: VideoStore

    var body: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.split.3x1.fill").font(.system(size: 22)).foregroundStyle(.tint).frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dashboard").font(.headline)
                    Text("\(store.videos.count) video\(store.videos.count == 1 ? "" : "s") · \(plugin.selfies.videos.count) selfie\(plugin.selfies.videos.count == 1 ? "" : "s") · \(plugin.recordings.videos.count) recording\(plugin.recordings.videos.count == 1 ? "" : "s") · \(plugin.allTags.count) tag\(plugin.allTags.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Show in Finder") { plugin.revealLibrary(); }
                Button("Open Dashboard") { plugin.action("dashboard").map(plugin.perform) }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.vertical, 4)
        }
    }
}

private struct VideoNotesSettingsSections: View {
    @ObservedObject var plugin: VideoNotesPlugin
    @ObservedObject var state: AppState
    @ObservedObject var store: VideoStore

    var body: some View {
        let s = plugin.settings
        Section {
            VolumeSlider(plugin: plugin)
        } header: {
            Text("Playback")
        } footer: {
            Text("Makes every video louder (or quieter) without changing your Mac's volume. Applies to the player in Quick Capture, not QuickTime.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            ForEach(1...VideoStore.slotCount, id: \.self) { slot in
                LabeledContent("\(slot)") {
                    Text(store.video(slot: slot)?.title ?? "Empty — drag a video onto a slot in the dashboard")
                        .foregroundStyle(.secondary).lineLimit(1)
                }
            }
        } header: {
            Text("Quick play")
        } footer: {
            Text("Press \(plugin.shortcutText("quick_play")), then 1–5; the video opens and starts playing.").font(.caption).foregroundStyle(.secondary)
        }
        Section {
            HStack {
                TextField("Folder", text: Binding(get: { s.folder }, set: { v in try? plugin.update { $0.folder = v } }),
                          prompt: Text("~/Movies"))
                Button("Choose…", action: chooseFolder)
            }
            Picker("Compression", selection: Binding(get: { VideoCompressor.Mode(rawValue: s.compression) ?? .smart },
                                                     set: { v in try? plugin.update { $0.compression = v.rawValue } })) {
                Text("Off").tag(VideoCompressor.Mode.off)
                Text("Efficient (HEVC)").tag(VideoCompressor.Mode.efficient)
                Text("Smart (HEVC + blurred background)").tag(VideoCompressor.Mode.smart)
            }
            Toggle("Record the microphone", isOn: Binding(get: { s.microphone }, set: { v in try? plugin.update { $0.microphone = v } }))
        } header: {
            Text("Recording")
        } footer: {
            Text("Compression runs in the background after each recording (camera videos to 720p, about 4 MB per minute) and keeps the original if the result isn't smaller. Details: docs/video-compression.md.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            CameraSizeSlider(plugin: plugin)
            Picker("Camera corner", selection: Binding(get: { ScreenCamCapture.Corner(rawValue: s.screenCameraCorner) ?? .bottomLeft },
                                                       set: { v in try? plugin.update { $0.screenCameraCorner = v.rawValue } })) {
                ForEach(ScreenCamCapture.Corner.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        } header: {
            Text("Screen + camera")
        } footer: {
            Text("\(plugin.shortcutText("record_screen")) records the screen at 720p with your camera in a corner, the Mac's sound and the microphone. Unless compression is off, they're shrunk afterwards to 15 fps HEVC (text stays sharp).")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            Toggle("Ask for a tag and note after each selfie", isOn: Binding(get: { s.selfiePrompt }, set: { v in try? plugin.update { $0.selfiePrompt = v } }))
            Toggle("Save selfies mirrored (as in the preview)", isOn: Binding(get: { s.selfieMirror }, set: { v in try? plugin.update { $0.selfieMirror = v } }))
            LabeledContent("Folder") {
                Button("Show in Finder") { plugin.revealSelfies() }
            }
        } header: {
            Text("Selfie")
        } footer: {
            Text("\(plugin.shortcutText("selfie")) shows the camera; press it again (or Space) to take the photo. Saved as JPEG in “quick-capture-selfie” next to the videos.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            Toggle("Also record the Mac's sound (the other people)", isOn: Binding(get: { s.meetingSystemAudio }, set: { v in try? plugin.update { $0.meetingSystemAudio = v } }))
            Picker("Quality", selection: Binding(get: { AudioCompression(rawValue: s.meetingCompression) ?? .compact },
                                                 set: { v in try? plugin.update { $0.meetingCompression = v.rawValue } })) {
                ForEach(AudioCompression.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Toggle("Ask for a tag and note when a recording stops", isOn: Binding(get: { s.meetingPrompt }, set: { v in try? plugin.update { $0.meetingPrompt = v } }))
            Toggle("Show a REC timer at the top right", isOn: Binding(get: { s.meetingIndicator }, set: { v in try? plugin.update { $0.meetingIndicator = v } }))
            LabeledContent("Folder") {
                Button("Show in Finder") { plugin.revealAudio() }
            }
        } header: {
            Text("Meeting audio")
        } footer: {
            Text("\(plugin.shortcutText("meeting")) starts (press again to pause / resume), \(plugin.shortcutText("meeting_stop")) stops. The microphone and the Mac's sound are mixed into one .m4a in “quick-capture-audio”; the Mac's sound needs Screen Recording permission. The timer never shows up in screen sharing.")
                .font(.caption).foregroundStyle(.secondary)
        }
        TranscriptionSection(plugin: plugin)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Videos go in a “quick-capture-video” folder inside this one."
        if panel.runModal() == .OK, let url = panel.url { try? plugin.update { $0.folder = url.path } }
    }
}

/// Which speech-to-text engine runs after a meeting recording, and how.
private struct TranscriptionSection: View {
    @ObservedObject var plugin: VideoNotesPlugin
    @State private var available: String?
    @State private var checked = false

    var body: some View {
        let s = plugin.settings
        Section {
            Picker("Engine", selection: Binding(get: { Transcriber.Engine(rawValue: s.transcriptionEngine) ?? .auto },
                                                set: { v in try? plugin.update { $0.transcriptionEngine = v.rawValue } })) {
                ForEach(Transcriber.Engine.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Language", selection: Binding(get: { s.transcriptionLanguage }, set: { v in try? plugin.update { $0.transcriptionLanguage = v } })) {
                Text("Detect automatically").tag("auto")
                Text("Chinese (with English words)").tag("zh")
                Text("English").tag("en")
                if !["auto", "zh", "en"].contains(s.transcriptionLanguage) { Text(s.transcriptionLanguage).tag(s.transcriptionLanguage) }
            }
            TextField("Hint for Whisper", text: Binding(get: { s.transcriptionPrompt }, set: { v in try? plugin.update { $0.transcriptionPrompt = v } }),
                      prompt: Text("Names, jargon, or the script to use"))
            TextField("Model", text: Binding(get: { s.transcriptionModel }, set: { v in try? plugin.update { $0.transcriptionModel = v } }),
                      prompt: Text("Automatic (Handy's or whisper.cpp's best model)"))
            LabeledContent("Will use") {
                Text(checked ? (available ?? "Nothing installed — see below") : "Checking…").foregroundStyle(.secondary).lineLimit(1)
            }
            Button("Transcribe a Recording Again…") { plugin.transcribeAgain() }
        } header: {
            Text("Transcription")
        } footer: {
            Text("Starts when a meeting recording stops (nothing runs during the meeting) and saves a .txt transcript next to the audio, on this Mac. For Chinese and English in one meeting use Whisper: brew install whisper-cpp (fast, uses Handy's downloaded models). Apple Speech (macOS 26) needs nothing installed but hears one language per recording.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task(id: s.transcriptionModel + s.transcriptionEngine) {
            let options = Transcriber.Options(engine: .auto, language: s.transcriptionLanguage, prompt: "", model: s.transcriptionModel)
            available = await Transcriber.describeAvailable(options)
            checked = true
        }
    }
}

/// Size of the camera square in screen + camera recordings, in percent of the video height.
private struct CameraSizeSlider: View {
    @ObservedObject var plugin: VideoNotesPlugin
    @State private var value: Double?

    var body: some View {
        let range = VideoNotesSettings.screenCameraSizeRange
        let current = value ?? Double(plugin.settings.screenCameraSize)
        HStack(spacing: 8) {
            Text("Camera size")
            Slider(value: Binding(get: { current }, set: { value = $0 }),
                   in: Double(range.lowerBound)...Double(range.upperBound), step: 5) { editing in
                guard !editing, let v = value else { return }
                try? plugin.update { $0.screenCameraSize = Int(v) }
                value = nil
            }
            Text("\(Int(current))%").monospacedDigit().frame(width: 44, alignment: .trailing).foregroundStyle(.secondary)
        }
    }
}

/// Playback volume, 25–800%. Shared by Settings and the dashboard toolbar.
struct VolumeSlider: View {
    @ObservedObject var plugin: VideoNotesPlugin
    var compact = false
    @State private var value: Double?

    var body: some View {
        let range = VideoNotesSettings.volumeRange
        let current = value ?? Double(plugin.settings.volume)
        HStack(spacing: 8) {
            if !compact { Text("Volume") }
            Image(systemName: "speaker.wave.1").foregroundStyle(.secondary)
            Slider(value: Binding(get: { current }, set: { value = $0 }),
                   in: Double(range.lowerBound)...Double(range.upperBound), step: 25) { editing in
                guard !editing, let v = value else { return }
                try? plugin.update { $0.volume = Int(v) }
                value = nil
            }
            .frame(minWidth: compact ? 110 : 160)
            Image(systemName: "speaker.wave.3").foregroundStyle(.secondary)
            Text("\(Int(current))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                .foregroundStyle(current > 100 ? Color.accentColor : .secondary)
            if !compact && Int(current) != 100 {
                Button("Reset") { try? plugin.update { $0.volume = 100 } }
            }
        }
    }
}
