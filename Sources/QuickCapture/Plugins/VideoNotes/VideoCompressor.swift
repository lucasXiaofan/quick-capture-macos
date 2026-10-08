import AVFoundation
import CoreImage
import Vision

/// Shrinks a recording to a fixed, measured target (see `target(mode:screen:)` and docs/video-compression.md).
///
/// Video is ~95% of a recording's size, so that's where the savings are:
/// - Camera videos go to 720p HEVC (a 1080p face gains almost nothing from the extra pixels). "smart"
///   also blurs everything except the person (Vision segmentation), so the bits go to the face.
/// - Screen + camera videos go to HEVC at 15 fps: a screen is mostly still, and at the same bit rate
///   each frame gets twice the bits, which keeps text sharp where 30 fps smears it.
/// - Audio is re-encoded as AAC at 64 kbit/s mono (voice) or 96 kbit/s stereo (screen sound) — inaudible
///   for speech, and it was 130–150 kbit/s.
enum VideoCompressor {
    /// Bumped when the targets change, so videos compressed by an older version are offered again.
    /// 1: 1080p HEVC by bits per pixel, audio copied. 2: measured targets below (720p, audio re-encoded).
    static let version = 2

    enum Mode: String, CaseIterable {
        case off, efficient, smart
    }

    /// What a compressed video looks like. Chosen from measurements on real recordings
    /// (docs/video-compression.md): 720p is enough for a face; a still screen needs few frames,
    /// so halving the frame rate doubles the bits each frame gets and keeps text sharp.
    struct Target: Equatable {
        var maxHeight: Int
        /// nil keeps the source frame rate.
        var fps: Double?
        var bitRate: Int
        var blur: Bool
        var audioChannels: Int
        var audioBitRate: Int
    }

    static func target(mode: Mode, screen: Bool) -> Target {
        if screen {
            // Screen + camera: HEVC 15 fps 0.8 Mbit/s ≈ 6.5 MB/min with sound; text measured as sharp as 30 fps at 1.2.
            return Target(maxHeight: 720, fps: 15, bitRate: 800_000, blur: false, audioChannels: 2, audioBitRate: 96_000)
        }
        // Camera: 720p HEVC ≈ 4 MB/min with sound (SSIM 0.99 vs. the 1080p original); voice in mono AAC.
        return Target(maxHeight: 720, fps: nil, bitRate: mode == .smart ? 500_000 : 700_000, blur: mode == .smart,
                      audioChannels: 1, audioBitRate: 64_000)
    }

    /// Writes a compressed copy of `source` to `destination` (an .mov that doesn't exist yet).
    /// `progress` is called with 0…1 from a background queue.
    static func compress(_ source: URL, to destination: URL, target: Target,
                         progress: @escaping @Sendable (Double) -> Void) async throws {
        let job = try await Job(source: source, destination: destination, target: target, progress: progress)
        try await job.run()
    }
}

private final class Job: @unchecked Sendable {
    private let reader: AVAssetReader
    private let writer: AVAssetWriter
    private let videoOut: AVAssetReaderTrackOutput
    private let videoIn: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var audioOut: AVAssetReaderTrackOutput?
    private var audioIn: AVAssetWriterInput?
    private let target: VideoCompressor.Target
    private let sourceSize: CGSize
    private let outputSize: CGSize
    private let duration: Double
    private let progress: @Sendable (Double) -> Void
    private let context = CIContext()
    private let segmentation = VNGeneratePersonSegmentationRequest()
    private let sequence = VNSequenceRequestHandler()
    private var nextFrame = -Double.infinity

    init(source: URL, destination: URL, target: VideoCompressor.Target, progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw AppError("The recording has no video.")
        }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let sourceFPS = max(1, Double(try await track.load(.nominalFrameRate)))
        duration = max(0.1, try await asset.load(.duration).seconds)
        self.target = target
        self.progress = progress
        sourceSize = size
        let scale = min(1, CGFloat(target.maxHeight) / max(1, size.height))
        outputSize = CGSize(width: (size.width * scale / 2).rounded() * 2, height: (size.height * scale / 2).rounded() * 2)

        reader = try AVAssetReader(asset: asset)
        let pixelFormat: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOut = AVAssetReaderTrackOutput(track: track, outputSettings: pixelFormat)
        reader.add(videoOut)

        writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        let width = Int(outputSize.width), height = Int(outputSize.height)
        videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: target.bitRate,
                AVVideoExpectedSourceFrameRateKey: min(sourceFPS, target.fps ?? sourceFPS),
                AVVideoMaxKeyFrameIntervalDurationKey: 4,   // long groups of pictures: a still camera needs few key frames
            ],
        ])
        videoIn.transform = transform
        videoIn.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(videoIn)

        // Audio is re-encoded as AAC at a rate that is transparent for voice (it was ~130–150 kbit/s).
        if let audio = try await asset.loadTracks(withMediaType: .audio).first {
            let out = AVAssetReaderTrackOutput(track: audio, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: target.audioChannels,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
            ])
            reader.add(out)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: target.audioChannels, AVEncoderBitRateKey: target.audioBitRate,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioOut = out
            audioIn = input
        }
        segmentation.qualityLevel = .balanced
        segmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8
    }

    func run() async throws {
        guard reader.startReading() else { throw reader.error ?? AppError("Can't read the recording.") }
        guard writer.startWriting() else { throw writer.error ?? AppError("Can't write the compressed video.") }
        writer.startSession(atSourceTime: .zero)

        let group = DispatchGroup()
        pump(videoIn, group: group, queue: DispatchQueue(label: "video-notes.compress.video")) { [self] in
            guard let sample = videoOut.copyNextSampleBuffer() else { return false }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            progress(min(1, time.seconds / duration))
            // Lower frame rate: keep a frame only once its slot comes up.
            if let fps = target.fps {
                guard time.seconds >= nextFrame - 0.01 else { return true }
                nextFrame = max(nextFrame + 1 / fps, time.seconds + 0.5 / fps)
            }
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { return true }
            guard let out = process(pixels) else { return true }
            return adaptor.append(out, withPresentationTime: time)
        }
        if let audioIn, let audioOut {
            pump(audioIn, group: group, queue: DispatchQueue(label: "video-notes.compress.audio")) {
                guard let sample = audioOut.copyNextSampleBuffer() else { return false }
                return audioIn.append(sample)
            }
        }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            group.notify(queue: .global()) { done.resume() }
        }
        if reader.status == .failed { writer.cancelWriting(); throw reader.error ?? AppError("Reading the recording failed.") }
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? AppError("Writing the compressed video failed.") }
    }

    /// Blurs the background (smart) and scales down to the target size; the source buffer when neither applies.
    private func process(_ pixels: CVPixelBuffer) -> CVPixelBuffer? {
        let scaled = outputSize != sourceSize
        guard target.blur || scaled else { return pixels }
        var image = CIImage(cvPixelBuffer: pixels)
        if target.blur, let blurred = blurBackground(image, pixels) { image = blurred }
        if scaled {
            let sy = outputSize.height / sourceSize.height, sx = outputSize.width / sourceSize.width
            image = image.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: sy, kCIInputAspectRatioKey: sx / sy,
            ])
        }
        guard let pool = adaptor.pixelBufferPool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out else { return nil }
        context.render(image, to: out, bounds: CGRect(origin: .zero, size: outputSize), colorSpace: CGColorSpaceCreateDeviceRGB())
        return out
    }

    /// Feeds `input` until `next` returns false (no more samples or an append failed), then closes it.
    private func pump(_ input: AVAssetWriterInput, group: DispatchGroup, queue: DispatchQueue, next: @escaping () -> Bool) {
        group.enter()
        input.requestMediaDataWhenReady(on: queue) {
            while input.isReadyForMoreMediaData {
                if !next() {
                    input.markAsFinished()
                    group.leave()
                    return
                }
            }
        }
    }

    /// Keeps the person sharp and blurs the rest.
    private func blurBackground(_ image: CIImage, _ pixels: CVPixelBuffer) -> CIImage? {
        guard (try? sequence.perform([segmentation], on: pixels)) != nil,
              let mask = segmentation.results?.first?.pixelBuffer else { return nil }
        let extent = image.extent
        var maskImage = CIImage(cvPixelBuffer: mask)
        maskImage = maskImage.transformed(by: CGAffineTransform(scaleX: extent.width / maskImage.extent.width,
                                                                y: extent.height / maskImage.extent.height))
        // A slightly soft mask edge hides the cut-out line.
        maskImage = maskImage.clampedToExtent().applyingGaussianBlur(sigma: 3).cropped(to: extent)
        let blurred = image.clampedToExtent().applyingGaussianBlur(sigma: Double(extent.height) / 45).cropped(to: extent)
        return CIFilter(name: "CIBlendWithMask", parameters: [
            kCIInputImageKey: image, kCIInputBackgroundImageKey: blurred, kCIInputMaskImageKey: maskImage,
        ])?.outputImage
    }
}
