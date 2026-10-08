import AVFoundation
import MediaToolbox

/// Plays a video's audio louder (or quieter) than recorded without touching the system volume.
/// `AVPlayer.volume` stops at 100%, so this multiplies the samples in an audio tap instead, with a soft
/// limiter so loud parts round off rather than crackle. Change `gain` while playing; it applies at once.
final class VideoGain: @unchecked Sendable {
    /// 1 = as recorded. Read on the audio thread; a Float store is atomic enough for a volume knob.
    var gain: Float
    fileprivate var isFloat = false

    init(gain: Float) { self.gain = gain }

    /// An audio mix that applies this gain to the item's first audio track, or nil if it has none.
    func audioMix(for asset: AVAsset) async -> AVAudioMix? {
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { return nil }
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(self).toOpaque(),
            init: { _, clientInfo, storage in storage.pointee = clientInfo },
            finalize: { tap in Unmanaged<VideoGain>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
            prepare: { tap, _, format in
                let gain = Unmanaged<VideoGain>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let f = format.pointee
                gain.isFloat = f.mFormatID == kAudioFormatLinearPCM && f.mFormatFlags & kAudioFormatFlagIsFloat != 0
                    && f.mBitsPerChannel == 32
            },
            unprepare: nil,
            process: { tap, frames, _, buffers, framesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, nil, framesOut) == noErr else { return }
                let box = Unmanaged<VideoGain>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let g = box.gain
                guard box.isFloat, g != 1 else { return }
                for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                    guard let data = buffer.mData else { continue }
                    let samples = data.assumingMemoryBound(to: Float.self)
                    for i in 0..<Int(buffer.mDataByteSize) / MemoryLayout<Float>.size {
                        samples[i] = VideoGain.limit(samples[i] * g)
                    }
                }
            })
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr,
              let tap else {
            Unmanaged.passUnretained(self).release()
            return nil
        }
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        return mix
    }

    /// Linear up to 0.9, then eases toward 1 so boosted peaks never clip hard.
    private static func limit(_ x: Float) -> Float {
        let a = abs(x)
        guard a > 0.9 else { return x }
        let y = 0.9 + 0.1 * tanh((a - 0.9) / 0.1)
        return x < 0 ? -y : y
    }
}
