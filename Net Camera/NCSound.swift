import AVFoundation
import CoreMedia
import Foundation

// MARK: - DC blocker

/// Takes a constant offset out of sound, leaving everything audible alone.
///
/// Some capture devices deliver silence that is not zero: the Macrosilicon
/// dongle this was written against sits at a fifth of full scale. Nothing of
/// that can be heard, until the sound stops for a moment — a gap in playback,
/// the start of a recording — and the level drops to zero and jumps back,
/// which is heard as a click every time. With the offset gone, the same gaps
/// fall silent.
///
/// A one-pole high-pass filter, `y[n] = x[n] - x[n-1] + r * y[n-1]`, at 10 Hz:
/// below anything a speaker reproduces, and so slow to settle that it moves
/// nothing but the offset. The first sample it sees is taken as the level it
/// starts from, so it does not itself begin with a step.
struct NCDCBlocker {
    static let cutoff: Double = 10

    private var previousInput: [Float] = []
    private var previousOutput: [Float] = []
    private var sampleRate: Double = 0

    /// Filters a buffer in place. Only 32-bit float, non-interleaved sound is
    /// filtered; anything else passes unchanged. A change of channel count or
    /// sample rate starts the filter afresh.
    mutating func process(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData, !buffer.format.isInterleaved else { return }
        let channelCount = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        if previousInput.count != channelCount || sampleRate != buffer.format.sampleRate {
            sampleRate = buffer.format.sampleRate
            previousInput = (0..<channelCount).map { channels[$0][0] }
            previousOutput = Array(repeating: 0, count: channelCount)
        }

        let r = Float(1 - 2 * Double.pi * Self.cutoff / sampleRate)
        for channel in 0..<channelCount {
            let samples = channels[channel]
            var lastIn = previousInput[channel]
            var lastOut = previousOutput[channel]
            for index in 0..<frames {
                let input = samples[index]
                let output = input - lastIn + r * lastOut
                samples[index] = output
                lastIn = input
                lastOut = output
            }
            previousInput[channel] = lastIn
            previousOutput[channel] = lastOut
        }
    }

    /// Forgets the level, for when the sound comes from somewhere else.
    mutating func reset() {
        previousInput = []
        previousOutput = []
        sampleRate = 0
    }
}

// MARK: - Buffers

/// Moving sound between Core Media's sample buffers, which capture and the
/// asset writer use, and AVFoundation's PCM buffers, which filtering and
/// playback use.
enum NCSoundBuffers {
    /// The sound in a captured sample buffer, as 32-bit float non-interleaved
    /// PCM at its own sample rate and channel count, converting it if it does
    /// not arrive that way. `nil` if it cannot be read.
    static func pcmBuffer(from sample: CMSampleBuffer, converter: inout AVAudioConverter?)
        -> AVAudioPCMBuffer?
    {
        guard let description = CMSampleBufferGetFormatDescription(sample) else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        guard frames > 0,
            let captured = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else { return nil }
        captured.frameLength = frames
        guard
            CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sample, at: 0, frameCount: Int32(frames), into: captured.mutableAudioBufferList)
                == noErr
        else { return nil }

        if format.commonFormat == .pcmFormatFloat32 && !format.isInterleaved {
            return captured
        }

        guard
            let standard = AVAudioFormat(
                standardFormatWithSampleRate: format.sampleRate, channels: format.channelCount)
        else { return nil }
        if converter?.inputFormat != format || converter?.outputFormat != standard {
            converter = AVAudioConverter(from: format, to: standard)
        }
        guard let converter,
            let converted = AVAudioPCMBuffer(pcmFormat: standard, frameCapacity: frames)
        else { return nil }
        do {
            try converter.convert(to: converted, from: captured)
        } catch {
            return nil
        }
        return converted
    }

    /// A sample buffer holding a copy of `buffer`'s sound, stamped `time`.
    static func sampleBuffer(from buffer: AVAudioPCMBuffer, at time: CMTime) -> CMSampleBuffer? {
        var sample: CMSampleBuffer?
        guard
            CMAudioSampleBufferCreateWithPacketDescriptions(
                allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                makeDataReadyCallback: nil, refcon: nil,
                formatDescription: buffer.format.formatDescription,
                sampleCount: CMItemCount(buffer.frameLength), presentationTimeStamp: time,
                packetDescriptions: nil, sampleBufferOut: &sample) == noErr,
            let sample,
            CMSampleBufferSetDataBufferFromAudioBufferList(
                sample, blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0,
                bufferList: buffer.audioBufferList) == noErr
        else { return nil }
        return sample
    }
}

// MARK: - Monitor

/// Plays sound through the Mac's output as it arrives.
///
/// Built on AVAudioEngine rather than AVCaptureAudioPreviewOutput because the
/// sound has to be filtered before it is heard, and a preview output plays
/// what the device delivers and nothing else.
///
/// The capture device and the output run on clocks of their own, so the sound
/// arrives a little faster or slower than it is played. Running behind is
/// what matters: left alone, the delay would grow without end. So once more
/// than a short stretch is waiting, new sound is dropped until the queue has
/// caught up — a gap that, with the offset filtered out, is silence.
///
/// Running ahead matters too, in a smaller way: sound arrives in buffers of a
/// few milliseconds, not quite evenly, and a buffer that comes late finds the
/// player already finished with the one before. So playback starts only once
/// a short stretch has gathered, and gathers it again whenever it runs dry,
/// which keeps a little in hand for late buffers to be covered by.
/// Called on one queue only, the sound queue.
final class NCSoundMonitor {
    /// The most sound allowed to wait for playback before new sound is
    /// dropped: enough to ride out uneven delivery, little enough not to be
    /// noticed against the picture. Between this and the preroll is where the
    /// delay settles when the two clocks disagree, so it never drifts further.
    static let maximumDelay: Double = 0.08

    /// How much sound is gathered before playback starts, or starts again
    /// after running dry. It is also how much later than the picture the
    /// sound is heard.
    static let preroll: Double = 0.03

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var format: AVAudioFormat?

    /// Whether the player is playing, rather than gathering its preroll.
    /// Sound queue only.
    private var isPlaying = false

    /// How many frames are scheduled and not yet played, and whether that
    /// has fallen to none since the player started. Changed from the player's
    /// own completion thread, so guarded.
    private let lock = NSLock()
    private var queuedFrames: AVAudioFramePosition = 0
    private var hasRunDry = false

    private var configurationObserver: NSObjectProtocol?

    init() {
        engine.attach(player)
        // A change of output device stops the engine; the next sound sets it
        // up again on whatever the output now is.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            NSLog("NCSoundMonitor: the output changed; restarting with the next sound")
            self?.lock.lock()
            self?.format = nil
            self?.queuedFrames = 0
            self?.lock.unlock()
        }
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    func play(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let current = format
        let waiting = queuedFrames
        let ranDry = hasRunDry
        hasRunDry = false
        lock.unlock()

        if current != buffer.format || !engine.isRunning {
            guard start(with: buffer.format) else { return }
        } else if Double(waiting) / buffer.format.sampleRate > Self.maximumDelay {
            return
        } else if ranDry && isPlaying {
            // Out of sound: wait for a preroll's worth again rather than
            // playing each buffer the moment it comes.
            player.pause()
            isPlaying = false
        }

        let frames = AVAudioFramePosition(buffer.frameLength)
        lock.lock()
        queuedFrames += frames
        let queued = queuedFrames
        lock.unlock()
        player.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.queuedFrames = max(0, self.queuedFrames - frames)
            if self.queuedFrames == 0 {
                self.hasRunDry = true
            }
            self.lock.unlock()
        }

        if !isPlaying && Double(queued) / buffer.format.sampleRate >= Self.preroll {
            player.play()
            isPlaying = true
        }
    }

    func stop() {
        player.stop()
        engine.stop()
        isPlaying = false
        lock.lock()
        format = nil
        queuedFrames = 0
        hasRunDry = false
        lock.unlock()
    }

    private func start(with newFormat: AVAudioFormat) -> Bool {
        player.stop()
        engine.stop()
        engine.connect(player, to: engine.mainMixerNode, format: newFormat)
        do {
            try engine.start()
        } catch {
            NSLog("NCSoundMonitor: the output would not start: %@", error.localizedDescription)
            return false
        }
        // The player starts once the preroll has gathered; see play(_:).
        isPlaying = false
        lock.lock()
        format = newFormat
        queuedFrames = 0
        hasRunDry = false
        lock.unlock()
        NSLog(
            "NCSoundMonitor: playing %.0f Hz, %d channel(s)", newFormat.sampleRate,
            newFormat.channelCount)
        return true
    }
}
