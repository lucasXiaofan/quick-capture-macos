import AVFoundation
import AppKit
import CoreImage
import ScreenCaptureKit
import os

/// Screen + camera recording: the main display at 720p with your camera as a rounded square in a corner,
/// the Mac's sound and (optionally) the microphone. Written as H.264 in real time; `VideoCompressor` shrinks it afterwards.
///
/// Camera frames drive the output, so the video stays at a steady frame rate even while the screen is
/// still (ScreenCaptureKit only sends frames when something changes); each camera frame is drawn over
/// the latest screen frame. This app's own windows (the preview, toasts) are left out of the capture.
/// System sound and microphone go to two audio tracks while recording and are mixed into one at the end.
/// All timestamps are moved onto the host clock, pauses are cut out, and the file starts at zero.
final class ScreenCamCapture: NSObject, SCStreamOutput, SCStreamDelegate,
    AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {

    enum Corner: String, CaseIterable {
        case bottomLeft = "bottom_left", bottomRight = "bottom_right", topLeft = "top_left", topRight = "top_right"

        var title: String {
            switch self {
            case .bottomLeft: "Bottom left"
            case .bottomRight: "Bottom right"
            case .topLeft: "Top left"
            case .topRight: "Top right"
            }
        }

        /// The camera square inside `bounds` (bottom-left origin, like Core Image and AppKit screens).
        func rect(side: CGFloat, in bounds: CGRect) -> CGRect {
            let margin = (bounds.height * 0.025).rounded()
            let x = self == .bottomLeft || self == .topLeft ? bounds.minX + margin : bounds.maxX - side - margin
            let y = self == .bottomLeft || self == .bottomRight ? bounds.minY + margin : bounds.maxY - side - margin
            return CGRect(x: x, y: y, width: side, height: side)
        }
    }

    struct Options {
        /// Camera square side as a fraction of the video height.
        var cameraSize: CGFloat
        var corner: Corner
    }

    static let height = 720
    static let frameRate: Int32 = 30

    let options: Options
    let size: CGSize
    /// The recorded display in AppKit screen coordinates, for placing the preview over the camera square.
    let displayFrame: CGRect?
    private let stream: SCStream
    private let queue = DispatchQueue(label: "video-notes.screen-cam", qos: .userInitiated)
    let cameraOutput = AVCaptureVideoDataOutput()
    let micOutput = AVCaptureAudioDataOutput()
    private var sessionClock: CMClock?
    private let destination: URL
    private let raw: URL

    private let writer: AVAssetWriter
    private let videoIn: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let systemIn: AVAssetWriterInput
    private var micIn: AVAssetWriterInput?
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let elapsedLock = OSAllocatedUnfairLock(initialState: 0.0)

    // Touched only on `queue`.
    private var screenFrame: CVPixelBuffer?
    private var start: CMTime?
    private var lastVideo = CMTime.invalid
    private var pausedAt: CMTime?
    private var pauses: [(start: CMTime, end: CMTime)] = []
    private var stopping = false
    private var mask: (CGRect, CIImage)?

    var elapsed: TimeInterval { elapsedLock.withLock { $0 } }

    /// Finds the display under the main screen and prepares the stream and the writer; nothing runs yet.
    static func make(to url: URL, options: Options) async throws -> ScreenCamCapture {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw AppError("Screen + camera needs Screen Recording permission (System Settings → Privacy → Screen Recording).")
        }
        let (id, frame) = await MainActor.run {
            let screen = NSScreen.main
            return ((screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value, screen?.frame)
        }
        guard let display = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first else {
            throw AppError("No display to record.")
        }
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
        return try ScreenCamCapture(url: url, options: options, display: display, filter: filter,
                                    displayFrame: display.displayID == id ? frame : nil)
    }

    private init(url: URL, options: Options, display: SCDisplay, filter: SCContentFilter, displayFrame: CGRect?) throws {
        self.options = options
        self.displayFrame = displayFrame
        destination = url
        raw = FileManager.default.temporaryDirectory.appendingPathComponent("quick-capture-\(UUID().uuidString).mov")
        // 720 high, as wide as the display's shape allows (even numbers for the encoder).
        let aspect = CGFloat(display.width) / CGFloat(max(1, display.height))
        let width = Int((CGFloat(Self.height) * aspect / 2).rounded()) * 2
        size = CGSize(width: width, height: Self.height)

        let config = SCStreamConfiguration()
        config.width = width
        config.height = Self.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: Self.frameRate)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.queueDepth = 6
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        stream = SCStream(filter: filter, configuration: config, delegate: nil)

        writer = try AVAssetWriter(outputURL: raw, fileType: .mov)
        videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: Self.height,
            AVVideoCompressionPropertiesKey: [
                // Generous for 720p, so screen text stays crisp; the file is never re-encoded.
                AVVideoAverageBitRateKey: 6_000_000,
                AVVideoExpectedSourceFrameRateKey: Self.frameRate,
                AVVideoMaxKeyFrameIntervalKey: Int(Self.frameRate) * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        videoIn.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: Self.height,
        ])
        systemIn = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.aac(channels: 2))
        systemIn.expectsMediaDataInRealTime = true
        writer.add(videoIn)
        writer.add(systemIn)
        super.init()
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
    }

    private static func aac(channels: Int) -> [String: Any] {
        [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: channels,
         AVEncoderBitRateKey: channels * 96_000]
    }

    /// Adds the camera (and microphone) outputs to a session that already has their inputs.
    /// Call inside `beginConfiguration` / `commitConfiguration`, before the session starts.
    func attach(to session: AVCaptureSession, microphone: Bool) throws {
        cameraOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        cameraOutput.alwaysDiscardsLateVideoFrames = true
        cameraOutput.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(cameraOutput) else { throw AppError("Can't start the camera.") }
        session.addOutput(cameraOutput)
        if microphone, session.canAddOutput(micOutput) {
            micOutput.audioSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
            ]
            micOutput.setSampleBufferDelegate(self, queue: queue)
            session.addOutput(micOutput)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.aac(channels: 1))
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            micIn = input
        }
        sessionClock = session.synchronizationClock
    }

    func startStream() async throws {
        do { try await stream.startCapture() } catch {
            throw AppError("Can't record the screen: \(error.localizedDescription)")
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

    /// Stops the stream, finishes the file and mixes the audio. Returns an error if nothing usable was written.
    func stop() async -> Error? {
        try? await stream.stopCapture()
        let started: Bool = await withCheckedContinuation { done in
            queue.async { [self] in
                stopping = true
                done.resume(returning: start != nil)
            }
        }
        guard started else { writer.cancelWriting(); return AppError("Nothing was recorded.") }
        videoIn.markAsFinished()
        systemIn.markAsFinished()
        micIn?.markAsFinished()
        writer.endSession(atSourceTime: lastVideo)
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: raw)
            return writer.error ?? AppError("Writing the recording failed.")
        }
        do {
            try await Self.mixAudio(raw, to: destination)
            try? FileManager.default.removeItem(at: raw)
        } catch {
            // Keep the recording with its two audio tracks rather than lose it.
            try? FileManager.default.moveItem(at: raw, to: destination)
        }
        return nil
    }

    // MARK: Samples (on `queue`)

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            guard let info = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let status = info.first?[.status] as? Int, SCFrameStatus(rawValue: status) == .complete,
                  let pixels = CMSampleBufferGetImageBuffer(sample) else { return }
            screenFrame = pixels
        case .audio:
            append(sample, to: systemIn, host: CMSampleBufferGetPresentationTimeStamp(sample))
        default:
            break
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        var time = CMSampleBufferGetPresentationTimeStamp(sample)
        if let sessionClock { time = CMSyncConvertTime(time, from: sessionClock, to: CMClockGetHostTimeClock()) }
        if output === cameraOutput {
            writeFrame(camera: CMSampleBufferGetImageBuffer(sample), host: time)
        } else if output === micOutput, let micIn {
            append(sample, to: micIn, host: time)
        }
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

    private func writeFrame(camera: CVPixelBuffer?, host: CMTime) {
        guard !stopping, let t = timeline(host) else { return }
        if start == nil {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: .zero)
            start = t
        }
        guard let start else { return }
        let time = t - start   // the file starts at zero
        guard !lastVideo.isValid || time > lastVideo, videoIn.isReadyForMoreMediaData,
              let pool = adaptor.pixelBufferPool else { return }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out else { return }
        context.render(compose(camera), to: out, bounds: CGRect(origin: .zero, size: size), colorSpace: colorSpace)
        if adaptor.append(out, withPresentationTime: time) {
            lastVideo = time
            elapsedLock.withLock { $0 = time.seconds }
        }
    }

    private func append(_ sample: CMSampleBuffer, to input: AVAssetWriterInput, host: CMTime) {
        guard !stopping, let start, let t = timeline(host), t >= start, input.isReadyForMoreMediaData else { return }
        var timing = CMSampleTimingInfo()
        guard CMSampleBufferGetSampleTimingInfo(sample, at: 0, timingInfoOut: &timing) == noErr else { return }
        timing.presentationTimeStamp = t - start
        timing.decodeTimeStamp = .invalid
        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: 1,
                                                    sampleTimingArray: &timing, sampleBufferOut: &copy) == noErr,
              let copy else { return }
        input.append(copy)
    }

    /// The latest screen frame with the camera's centre square on top, corners rounded.
    private func compose(_ camera: CVPixelBuffer?) -> CIImage {
        let bounds = CGRect(origin: .zero, size: size)
        let black = CIImage(color: .black).cropped(to: bounds)
        let screen = screenFrame.map { CIImage(cvPixelBuffer: $0).composited(over: black) } ?? black
        guard let camera else { return screen }
        let image = CIImage(cvPixelBuffer: camera)
        let e = image.extent
        let s = min(e.width, e.height)
        let side = (size.height * options.cameraSize).rounded()
        let rect = options.corner.rect(side: side, in: bounds)
        let scale = side / s
        let square = image
            .cropped(to: CGRect(x: e.midX - s / 2, y: e.midY - s / 2, width: s, height: s))
            .transformed(by: CGAffineTransform(translationX: -(e.midX - s / 2), y: -(e.midY - s / 2))
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
        return CIFilter(name: "CIBlendWithMask", parameters: [
            kCIInputImageKey: square, kCIInputBackgroundImageKey: screen, kCIInputMaskImageKey: roundedMask(rect),
        ])?.outputImage ?? screen
    }

    private func roundedMask(_ rect: CGRect) -> CIImage {
        if let mask, mask.0 == rect { return mask.1 }
        let image = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(cgRect: rect), "inputRadius": rect.width * 0.12, "inputColor": CIColor.white,
        ])?.outputImage ?? CIImage(color: .white).cropped(to: rect)
        mask = (rect, image)
        return image
    }

    // MARK: Audio mixdown

    /// Copies the video untouched and mixes every audio track into one stereo AAC track, so every player
    /// (and the playback volume boost) hears both the Mac's sound and your voice.
    static func mixAudio(_ source: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        guard audio.count > 1, let video = try await asset.loadTracks(withMediaType: .video).first else {
            try FileManager.default.moveItem(at: source, to: destination)
            return
        }
        let reader = try AVAssetReader(asset: asset)
        let videoOut = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
        let audioOut = AVAssetReaderAudioMixOutput(audioTracks: audio, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(videoOut)
        reader.add(audioOut)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        let hint = try await video.load(.formatDescriptions).first
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: hint)
        let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: aac(channels: 2))
        writer.add(videoIn)
        writer.add(audioIn)
        guard reader.startReading() else { throw reader.error ?? AppError("Can't read the recording.") }
        guard writer.startWriting() else { throw writer.error ?? AppError("Can't write the recording.") }
        writer.startSession(atSourceTime: .zero)
        let group = DispatchGroup()
        for (input, output, label) in [(videoIn, videoOut as AVAssetReaderOutput, "video"), (audioIn, audioOut, "audio")] {
            group.enter()
            input.requestMediaDataWhenReady(on: DispatchQueue(label: "video-notes.mix.\(label)")) {
                while input.isReadyForMoreMediaData {
                    guard let sample = output.copyNextSampleBuffer(), input.append(sample) else {
                        input.markAsFinished()
                        group.leave()
                        return
                    }
                }
            }
        }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            group.notify(queue: .global()) { done.resume() }
        }
        if reader.status == .failed { writer.cancelWriting(); throw reader.error ?? AppError("Mixing the audio failed.") }
        await writer.finishWriting()
        if writer.status != .completed {
            try? FileManager.default.removeItem(at: destination)
            throw writer.error ?? AppError("Mixing the audio failed.")
        }
    }
}
