import AVFoundation
import AppKit
import ScreenCaptureKit
import os

/// Meeting audio: the microphone plus the Mac's own sound (what the other people say), for as long as needed.
///
/// While recording, the two sources go to two AAC tracks in a fragmented `.mov` next to the final file, so an
/// hour-long recording survives a crash (the fragments written so far stay readable). On stop they're mixed
/// into one compact `.m4a` (see `AudioCompression`) and the partial file is removed.
/// The Mac's sound needs Screen Recording permission (ScreenCaptureKit); without it only the microphone is recorded.
/// Timestamps are on the host clock, pauses are cut out, and the file starts at zero.
final class AudioCapture: NSObject, SCStreamOutput, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let destination: URL
    /// The recording in progress; also what's left behind if the app quits mid-recording.
    let partial: URL
    let hasSystemAudio: Bool
    let compression: AudioCompression

    private let queue = DispatchQueue(label: "video-notes.audio", qos: .userInitiated)
    private let session = AVCaptureSession()
    private let micOutput = AVCaptureAudioDataOutput()
    private let stream: SCStream?
    private let writer: AVAssetWriter
    private var micIn: AVAssetWriterInput?
    private let systemIn: AVAssetWriterInput?
    private let elapsedLock = OSAllocatedUnfairLock(initialState: 0.0)

    // Touched only on `queue`.
    private var start: CMTime?
    private var pausedAt: CMTime?
    private var pauses: [(start: CMTime, end: CMTime)] = []
    private var stopping = false

    var elapsed: TimeInterval { elapsedLock.withLock { $0 } }

    static func partialURL(for destination: URL) -> URL {
        destination.deletingPathExtension().appendingPathExtension("part.mov")
    }

    /// Prepares the microphone and (when allowed) the Mac's sound; nothing runs until `start()`.
    static func make(to url: URL, microphone: Bool, systemAudio: Bool, compression: AudioCompression) async throws -> AudioCapture {
        var stream: SCStream?
        if systemAudio, CGPreflightScreenCaptureAccess(),
           let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
           let display = content.displays.first {
            let config = SCStreamConfiguration()
            // Audio is all we want; the smallest, slowest video ScreenCaptureKit allows.
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            config.queueDepth = 3
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
            stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: nil)
        }
        let capture = try AudioCapture(url: url, stream: stream, compression: compression)
        try capture.configure(microphone: microphone)
        guard capture.micIn != nil || stream != nil else {
            throw AppError("Nothing to record: allow the microphone (System Settings → Privacy → Microphone) or Screen Recording for the Mac's sound.")
        }
        return capture
    }

    private init(url: URL, stream: SCStream?, compression: AudioCompression) throws {
        destination = url
        partial = Self.partialURL(for: url)
        self.stream = stream
        self.compression = compression
        hasSystemAudio = stream != nil
        try? FileManager.default.removeItem(at: partial)
        writer = try AVAssetWriter(outputURL: partial, fileType: .mov)
        // Every 10 s the file is made readable up to that point, so a crash loses at most a few seconds.
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
        if stream != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.aac(channels: 2, bitRate: 128_000))
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            systemIn = input
        } else {
            systemIn = nil
        }
        super.init()
        if let stream {
            // ScreenCaptureKit complains when a stream has no screen output; its frames are ignored.
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }
    }

    private static func aac(channels: Int, bitRate: Int) -> [String: Any] {
        [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: channels,
         AVEncoderBitRateKey: bitRate]
    }

    private func configure(microphone: Bool) throws {
        guard microphone, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              let mic = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: mic) else { return }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canAddInput(input), session.canAddOutput(micOutput) else { return }
        session.addInput(input)
        micOutput.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ]
        micOutput.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(micOutput)
        let writerIn = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.aac(channels: 1, bitRate: 96_000))
        writerIn.expectsMediaDataInRealTime = true
        writer.add(writerIn)
        micIn = writerIn
    }

    func start() async throws {
        guard writer.startWriting() else { throw writer.error ?? AppError("Can't write the recording.") }
        writer.startSession(atSourceTime: .zero)
        if micIn != nil {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .userInitiated).async { [session] in
                    session.startRunning()
                    done.resume()
                }
            }
        }
        if let stream {
            do { try await stream.startCapture() } catch {
                guard micIn != nil else {
                    writer.cancelWriting()
                    throw AppError("Can't record the Mac's sound: \(error.localizedDescription)")
                }
                // Keep going with the microphone only.
            }
        }
    }

    func pause() { queue.async { [self] in if pausedAt == nil { pausedAt = Self.now } } }

    func resume() {
        queue.async { [self] in
            guard let p = pausedAt else { return }
            pauses.append((p, Self.now))
            pausedAt = nil
        }
    }

    /// Stops both sources and finishes the partial file. Call `AudioCompression.finalize` next.
    func stop() async -> Error? {
        try? await stream?.stopCapture()
        DispatchQueue.global(qos: .userInitiated).async { [session] in session.stopRunning() }
        let started: Bool = await withCheckedContinuation { done in
            queue.async { [self] in
                stopping = true
                done.resume(returning: start != nil)
            }
        }
        guard started else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: partial)
            return AppError("Nothing was recorded.")
        }
        micIn?.markAsFinished()
        systemIn?.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed ? nil : (writer.error ?? AppError("Writing the recording failed."))
    }

    // MARK: Samples (on `queue`)

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let systemIn else { return }
        append(sample, to: systemIn, host: CMSampleBufferGetPresentationTimeStamp(sample))
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let micIn else { return }
        var time = CMSampleBufferGetPresentationTimeStamp(sample)
        if let clock = session.synchronizationClock { time = CMSyncConvertTime(time, from: clock, to: CMClockGetHostTimeClock()) }
        append(sample, to: micIn, host: time)
    }

    private static var now: CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }

    /// Host time → file time with the pauses cut out; nil for anything recorded while paused.
    private func timeline(_ t: CMTime) -> CMTime? {
        if let pausedAt, t >= pausedAt { return nil }
        var offset = CMTime.zero
        for p in pauses {
            if t >= p.end { offset = offset + (p.end - p.start) } else if t >= p.start { return nil }
        }
        return t - offset
    }

    private func append(_ sample: CMSampleBuffer, to input: AVAssetWriterInput, host: CMTime) {
        guard !stopping, let t = timeline(host) else { return }
        if start == nil { start = t }
        guard let start, t >= start, input.isReadyForMoreMediaData else { return }
        var timing = CMSampleTimingInfo()
        guard CMSampleBufferGetSampleTimingInfo(sample, at: 0, timingInfoOut: &timing) == noErr else { return }
        timing.presentationTimeStamp = t - start
        timing.decodeTimeStamp = .invalid
        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: 1,
                                                    sampleTimingArray: &timing, sampleBufferOut: &copy) == noErr,
              let copy, input.append(copy) else { return }
        let end = (t - start + CMSampleBufferGetDuration(sample)).seconds
        if end.isFinite { elapsedLock.withLock { $0 = max($0, end) } }
    }
}

/// How meeting recordings are stored. Speech needs far less than music: mono, and a sample rate that
/// keeps everything up to 12–16 kHz (speech recognisers only look below 8 kHz).
enum AudioCompression: String, CaseIterable {
    /// HE-AAC mono 32 kbps, about 16 MB per hour. Clear speech, the smallest file.
    case compact
    /// AAC mono 64 kbps, about 29 MB per hour. Cleaner music and laughter, still small.
    case standard
    /// AAC stereo 128 kbps, about 58 MB per hour. Keeps the Mac's sound in stereo.
    case high

    var title: String {
        switch self {
        case .compact: "Compact — HE-AAC mono 32 kbps (~16 MB/hour)"
        case .standard: "Standard — AAC mono 64 kbps (~29 MB/hour)"
        case .high: "High — AAC stereo 128 kbps (~58 MB/hour)"
        }
    }

    var outputSettings: [String: Any] {
        switch self {
        case .compact:
            [AVFormatIDKey: kAudioFormatMPEG4AAC_HE, AVSampleRateKey: 32_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000]
        case .standard:
            [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 32_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000]
        case .high:
            [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000]
        }
    }

    /// Mixes every audio track of `source` into one track at this quality, written to `destination` (.m4a).
    /// Removes `source` on success; on failure leaves it alone so nothing is lost.
    func finalize(_ source: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw AppError("The recording has no sound.") }
        let reader = try AVAssetReader(asset: asset)
        let channels = outputSettings[AVNumberOfChannelsKey] as? Int ?? 1
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: outputSettings[AVSampleRateKey] ?? 48_000,
            AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: outputSettings)
        writer.add(input)
        guard reader.startReading() else { throw reader.error ?? AppError("Can't read the recording.") }
        guard writer.startWriting() else { throw writer.error ?? AppError("Can't write the recording.") }
        writer.startSession(atSourceTime: .zero)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: DispatchQueue(label: "video-notes.audio.mix")) {
                while input.isReadyForMoreMediaData {
                    guard let sample = output.copyNextSampleBuffer(), input.append(sample) else {
                        input.markAsFinished()
                        done.resume()
                        return
                    }
                }
            }
        }
        if reader.status == .failed {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: destination)
            throw reader.error ?? AppError("Compressing the recording failed.")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: destination)
            throw writer.error ?? AppError("Compressing the recording failed.")
        }
        try? FileManager.default.removeItem(at: source)
    }
}
