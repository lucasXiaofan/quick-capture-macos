import AVFoundation
import Foundation
import Speech

/// Turns a finished recording into text on this Mac (never live, during the recording). Three engines, tried in this order by `auto`:
///
/// 1. **whisper.cpp** (`whisper-cli`, `brew install whisper-cpp`) with a ggml model — fast (Metal) and handles
///    Chinese and English mixed in one sentence. Models are found in Handy's folder or `~/.cache/whisper.cpp`.
/// 2. **openai-whisper** (`whisper`, `pip`/`brew install openai-whisper`) — same models, slower (CPU).
/// 3. **Apple** `SpeechTranscriber` (macOS 26) — built in, nothing to install, but one language per recording.
enum Transcriber {
    enum Engine: String, CaseIterable {
        case auto, whisperCpp = "whisper_cpp", openaiWhisper = "openai_whisper", apple, off

        var title: String {
            switch self {
            case .auto: "Automatic (best available)"
            case .whisperCpp: "whisper.cpp"
            case .openaiWhisper: "OpenAI Whisper (Python)"
            case .apple: "Apple Speech (macOS 26)"
            case .off: "Off"
            }
        }
    }

    struct Options {
        var engine: Engine
        /// Whisper language code ("zh", "en", …) or "auto". Apple maps "auto" to the Mac's language.
        var language: String
        /// Whisper's initial prompt: steers script (简体/繁體), punctuation and mixed-language output.
        var prompt: String
        /// A ggml (.bin) or PyTorch (.pt) model file, or a model name; empty finds one automatically.
        var model: String
    }

    struct Segment { var start: TimeInterval; var text: String }

    struct Result {
        var segments: [Segment]
        /// Engine and model, for the transcript header.
        var by: String
    }

    // MARK: Engine selection

    /// What `auto` would use right now, for Settings. nil when nothing is available.
    static func describeAvailable(_ options: Options) async -> String? {
        if let (cli, model) = await whisperCpp(options) {
            return "whisper.cpp · \((model as NSString).lastPathComponent) (\((cli as NSString).lastPathComponent))"
        }
        if let (_, model) = await openaiWhisper(options) { return "OpenAI Whisper · \(model)" }
        if #available(macOS 26, *) { return "Apple Speech" }
        return nil
    }

    static func transcribe(_ audio: URL, options: Options) async throws -> Result {
        switch options.engine {
        case .off: throw AppError("Transcription is off.")
        case .whisperCpp:
            guard let (cli, model) = await whisperCpp(options) else {
                throw AppError("whisper.cpp isn't installed (brew install whisper-cpp), or no ggml model was found.")
            }
            return try await runWhisperCpp(audio, cli: cli, model: model, options: options)
        case .openaiWhisper:
            guard let (cli, model) = await openaiWhisper(options) else { throw AppError("OpenAI Whisper isn't installed.") }
            return try await runOpenAIWhisper(audio, cli: cli, model: model, options: options)
        case .apple:
            guard #available(macOS 26, *) else { throw AppError("Apple Speech transcription needs macOS 26.") }
            return try await runApple(audio, options: options)
        case .auto:
            var errors: [String] = []
            if let (cli, model) = await whisperCpp(options) {
                do { return try await runWhisperCpp(audio, cli: cli, model: model, options: options) }
                catch { errors.append("whisper.cpp: \(error.localizedDescription)") }
            }
            if let (cli, model) = await openaiWhisper(options) {
                do { return try await runOpenAIWhisper(audio, cli: cli, model: model, options: options) }
                catch { errors.append("Whisper: \(error.localizedDescription)") }
            }
            if #available(macOS 26, *) {
                do { return try await runApple(audio, options: options) }
                catch { errors.append("Apple Speech: \(error.localizedDescription)") }
            }
            throw AppError(errors.isEmpty
                ? "No speech-to-text engine found. Install whisper.cpp (brew install whisper-cpp) or update to macOS 26."
                : errors.joined(separator: "\n"))
        }
    }

    // MARK: Models

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Better models first; the first one found on disk wins.
    private static let preference = ["large-v3-turbo", "large-v3", "large-v2", "large", "medium", "small", "base", "tiny"]

    private static func rank(_ name: String) -> Int {
        let lower = name.lowercased()
        // ".en" models only know English, which breaks mixed Chinese/English.
        let englishOnly = lower.contains(".en")
        let index = preference.firstIndex { lower.contains($0) } ?? preference.count
        return index + (englishOnly ? 100 : 0)
    }

    private static func best(in dirs: [URL], ext: String) -> URL? {
        let fm = FileManager.default
        let files = dirs.flatMap { dir in
            ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == ext && !$0.lastPathComponent.hasPrefix("for-tests") }
        }
        return files.min { rank($0.lastPathComponent) < rank($1.lastPathComponent) }
    }

    /// Folders where ggml models usually live: Handy's (com.pais.handy), whisper.cpp's and MacWhisper-style caches.
    static var ggmlFolders: [URL] {
        let support = home.appendingPathComponent("Library/Application Support")
        return [support.appendingPathComponent("com.pais.handy/models"),
                home.appendingPathComponent(".cache/whisper.cpp"),
                home.appendingPathComponent(".cache/whisper"),
                support.appendingPathComponent("whisper.cpp/models"),
                URL(fileURLWithPath: "/opt/homebrew/share/whisper-cpp"),
                URL(fileURLWithPath: "/usr/local/share/whisper-cpp")]
    }

    private static func whisperCpp(_ options: Options) async -> (String, String)? {
        guard let cli = await LoginEnvironment.shared.find("whisper-cli") else { return nil }
        let model = (options.model as NSString).expandingTildeInPath
        if model.hasSuffix(".bin") { return FileManager.default.fileExists(atPath: model) ? (cli, model) : nil }
        return best(in: ggmlFolders, ext: "bin").map { (cli, $0.path) }
    }

    private static func openaiWhisper(_ options: Options) async -> (String, String)? {
        guard let cli = await LoginEnvironment.shared.find("whisper") else { return nil }
        let model = (options.model as NSString).expandingTildeInPath
        if model.hasSuffix(".pt") { return FileManager.default.fileExists(atPath: model) ? (cli, model) : nil }
        if !model.isEmpty && !model.hasSuffix(".bin") { return (cli, model) }   // a model name, e.g. "medium"
        // Use a model that's already downloaded; "small" otherwise (downloaded once, ~460 MB).
        let cached = best(in: [home.appendingPathComponent(".cache/whisper")], ext: "pt")
        return (cli, cached.map { $0.deletingPathExtension().lastPathComponent } ?? "small")
    }

    // MARK: Whisper

    /// 16 kHz mono 16-bit WAV, what whisper.cpp reads (and the fastest for Python Whisper's ffmpeg too).
    static func wav16k(_ source: URL) async throws -> URL {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("quick-capture-\(UUID().uuidString).wav")
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw AppError("The recording has no sound.") }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        reader.add(output)
        let writer = try AVAssetWriter(outputURL: out, fileType: .wav)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        writer.add(input)
        guard reader.startReading(), writer.startWriting() else { throw AppError("Can't prepare the audio for transcription.") }
        writer.startSession(atSourceTime: .zero)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: DispatchQueue(label: "video-notes.wav")) {
                while input.isReadyForMoreMediaData {
                    guard let sample = output.copyNextSampleBuffer(), input.append(sample) else {
                        input.markAsFinished()
                        done.resume()
                        return
                    }
                }
            }
        }
        await writer.finishWriting()
        guard reader.status != .failed, writer.status == .completed else {
            try? FileManager.default.removeItem(at: out)
            throw reader.error ?? writer.error ?? AppError("Can't prepare the audio for transcription.")
        }
        return out
    }

    /// Generous: Python Whisper on a slow Mac can take longer than the recording itself. whisper.cpp runs
    /// ~15× faster than real time on Apple silicon, so a much shorter limit lets `auto` fall back sooner if it hangs.
    private static func timeout(for audio: URL, factor: Double = 4) async -> TimeInterval {
        let seconds = (try? await AVURLAsset(url: audio).load(.duration).seconds) ?? 3600
        return max(300, (seconds.isFinite ? seconds : 3600) * factor)
    }

    private static func runWhisperCpp(_ audio: URL, cli: String, model: String, options: Options) async throws -> Result {
        let wav = try await wav16k(audio)
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("quick-capture-\(UUID().uuidString)")
        let json = base.appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: wav); try? FileManager.default.removeItem(at: json) }
        var args = ["-m", model, "-f", wav.path, "-l", options.language.isEmpty ? "auto" : options.language,
                    "-oj", "-of", base.path, "-np",
                    // Fewer repetition loops on long recordings with silences.
                    "-mc", "64",
                    "-t", "\(max(2, ProcessInfo.processInfo.activeProcessorCount - 2))"]
        if !options.prompt.isEmpty { args += ["--prompt", options.prompt] }
        let out = try await Shell.run(cli, args, environment: await LoginEnvironment.shared.environment(for: cli),
                                      timeout: await timeout(for: audio, factor: 1))
        guard out.status == 0, let data = try? Data(contentsOf: json) else {
            throw AppError(lastLine(out.stderr) ?? "whisper.cpp failed (exit \(out.status)).")
        }
        struct File: Decodable {
            struct Item: Decodable {
                struct Offsets: Decodable { var from: Double }
                var offsets: Offsets
                var text: String
            }
            var transcription: [Item]
        }
        let file = try JSONDecoder().decode(File.self, from: data)
        return Result(segments: file.transcription.map { Segment(start: $0.offsets.from / 1000, text: $0.text) },
                      by: "whisper.cpp · \((model as NSString).lastPathComponent)")
    }

    private static func runOpenAIWhisper(_ audio: URL, cli: String, model: String, options: Options) async throws -> Result {
        let wav = try await wav16k(audio)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quick-capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: wav); try? FileManager.default.removeItem(at: dir) }
        var args = [wav.path, "--model", model, "--output_format", "json", "--output_dir", dir.path,
                    "--condition_on_previous_text", "False", "--fp16", "False", "--verbose", "False"]
        if !options.language.isEmpty && options.language != "auto" { args += ["--language", options.language] }
        if !options.prompt.isEmpty { args += ["--initial_prompt", options.prompt] }
        let out = try await Shell.run(cli, args, environment: await LoginEnvironment.shared.environment(for: cli),
                                      timeout: await timeout(for: audio))
        let json = dir.appendingPathComponent(wav.deletingPathExtension().lastPathComponent + ".json")
        guard out.status == 0, let data = try? Data(contentsOf: json) else {
            throw AppError(lastLine(out.stderr) ?? "Whisper failed (exit \(out.status)).")
        }
        struct File: Decodable {
            struct Item: Decodable { var start: Double; var text: String }
            var segments: [Item]
        }
        let file = try JSONDecoder().decode(File.self, from: data)
        return Result(segments: file.segments.map { Segment(start: $0.start, text: $0.text) }, by: "OpenAI Whisper · \(model)")
    }

    private static func lastLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
    }

    // MARK: Apple

    @available(macOS 26, *)
    private static func runApple(_ audio: URL, options: Options) async throws -> Result {
        let wanted = options.language.isEmpty || options.language == "auto" ? Locale.current : Locale(identifier: appleLocale(options.language))
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) else {
            throw AppError("Apple Speech doesn't support \(wanted.identifier).")
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedTranscriptionWithAlternatives)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()   // the language model, once
        }
        let file = try AVAudioFile(forReading: audio)
        let collect = Task {
            var segments: [Segment] = []
            for try await result in transcriber.results where result.isFinal {
                let text = String(result.text.characters)
                if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                    segments.append(Segment(start: result.range.start.seconds, text: text))
                }
            }
            return segments
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        do {
            if let end = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: end)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            await analyzer.cancelAndFinishNow()
            collect.cancel()
            throw error
        }
        return Result(segments: try await collect.value, by: "Apple Speech · \(locale.identifier)")
    }

    /// Whisper's two-letter codes → a locale Apple understands.
    private static func appleLocale(_ code: String) -> String {
        switch code {
        case "zh": "zh-CN"
        case "en": "en-US"
        case "ja": "ja-JP"
        default: code
        }
    }

    // MARK: Output

    /// Plain text next to the recording: a header, then one timestamped line per sentence or so.
    static func text(_ result: Result, title: String, duration: TimeInterval?) -> String {
        var meta = ["Transcribed with \(result.by)"]
        if let duration, duration.isFinite { meta.insert("Length \(clock(duration))", at: 0) }
        var lines = [title, meta.joined(separator: " · "), ""]
        let sentences = sentences(result.segments)
        lines += sentences.map { "[\(clock($0.start))] \($0.text)" }
        if sentences.isEmpty { lines.append("(No speech found.)") }
        return lines.joined(separator: "\n") + "\n"
    }

    private static let sentenceEnd: Set<Character> = ["。", "！", "？", ".", "!", "?", "…"]
    private static let leadingPunctuation = CharacterSet(charactersIn: "，。、！？,.!?;；:： ")

    /// Joins fragments into sentences (Apple Speech reports a word or two at a time) and drops the
    /// lines Whisper sometimes repeats over silence.
    static func sentences(_ segments: [Segment]) -> [Segment] {
        var out: [Segment] = []
        var current: Segment?
        var previous = ""
        func flush() {
            if let c = current {
                let text = c.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty && text != previous { out.append(Segment(start: c.start, text: text)); previous = text }
            }
            current = nil
        }
        for segment in segments {
            var text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if var c = current {
                // Punctuation that starts a fragment belongs to the sentence before it.
                let lead = String(text.unicodeScalars.prefix { leadingPunctuation.contains($0) })
                text = String(text.dropFirst(lead.count))
                c.text += lead.trimmingCharacters(in: .whitespaces)
                current = c
                if let last = c.text.last, sentenceEnd.contains(last) { flush() }
                guard !text.isEmpty else { continue }
            }
            // Whisper's segments are already whole phrases; only short fragments are joined.
            if let c = current, c.text.count >= 30 { flush() }
            if var c = current {
                // A space between Latin words, none between Chinese characters.
                let joinsLatin = (c.text.last.map { $0.isASCII && $0.isLetter } ?? false) && (text.first.map { $0.isASCII } ?? false)
                c.text += (joinsLatin ? " " : "") + text
                current = c
            } else {
                current = Segment(start: segment.start, text: text)
            }
            if let c = current, let last = c.text.last, sentenceEnd.contains(last) || c.text.count > 120 { flush() }
        }
        flush()
        return out
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = Int(max(0, t))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }
}
