import AVFoundation
import XCTest

final class NCSoundTests: XCTestCase {
    private func makeBuffer(
        sampleRate: Double = 96_000, channels: AVAudioChannelCount = 1, frames: Int,
        value: (_ channel: Int, _ index: Int) -> Float
    ) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0..<Int(channels) {
            for index in 0..<frames {
                data[channel][index] = value(channel, index)
            }
        }
        return buffer
    }

    // MARK: - DC blocker

    /// The dongle's silence, a constant fifth of full scale, settles to zero —
    /// and does not start with a step either, which would be a click of its own.
    func testAConstantOffsetSettlesToZeroWithoutAStepAtTheStart() throws {
        var blocker = NCDCBlocker()
        // One second of offset, in buffers of 10 ms as capture delivers them.
        var first: Float = .nan
        var last: Float = .nan
        for _ in 0..<100 {
            let buffer = try makeBuffer(frames: 960) { _, _ in 0.2 }
            blocker.process(buffer)
            let samples = try XCTUnwrap(buffer.floatChannelData)[0]
            if first.isNaN { first = samples[0] }
            last = samples[959]
        }
        XCTAssertEqual(first, 0, accuracy: 1e-6, "the filter starts where the sound is")
        XCTAssertEqual(last, 0, accuracy: 1e-4, "the offset is gone")
    }

    /// A tone well inside hearing passes at its own level: the filter takes the
    /// offset and nothing else.
    func testAnAudibleToneKeepsItsLevelWhileItsOffsetGoes() throws {
        var blocker = NCDCBlocker()
        let rate = 48_000.0
        let frequency = 440.0
        var peak: Float = 0
        var mean: Double = 0
        var counted = 0
        for block in 0..<100 {
            let buffer = try makeBuffer(sampleRate: rate, frames: 480) { _, index in
                let t = Double(block * 480 + index) / rate
                return 0.2 + 0.5 * Float(sin(2 * .pi * frequency * t))
            }
            blocker.process(buffer)
            // Judged after half a second, once the filter has settled.
            guard block >= 50 else { continue }
            let samples = try XCTUnwrap(buffer.floatChannelData)[0]
            for index in 0..<480 {
                peak = max(peak, abs(samples[index]))
                mean += Double(samples[index])
                counted += 1
            }
        }
        XCTAssertEqual(peak, 0.5, accuracy: 0.01, "the tone keeps its amplitude")
        XCTAssertEqual(mean / Double(counted), 0, accuracy: 0.005, "and loses its offset")
    }

    /// Each channel is filtered on its own.
    func testChannelsAreFilteredSeparately() throws {
        var blocker = NCDCBlocker()
        var last: [Float] = [0, 0]
        for _ in 0..<100 {
            let buffer = try makeBuffer(channels: 2, frames: 960) { channel, _ in
                channel == 0 ? 0.3 : -0.1
            }
            blocker.process(buffer)
            let data = try XCTUnwrap(buffer.floatChannelData)
            last = [data[0][959], data[1][959]]
        }
        XCTAssertEqual(last[0], 0, accuracy: 1e-4)
        XCTAssertEqual(last[1], 0, accuracy: 1e-4)
    }

    // MARK: - Buffers

    /// Sound survives the trip into a sample buffer and back unchanged, at the
    /// time it was given.
    func testSoundSurvivesTheTripThroughASampleBuffer() throws {
        let original = try makeBuffer(channels: 2, frames: 256) { channel, index in
            Float(index) / 256 * (channel == 0 ? 1 : -1)
        }
        let time = CMTime(value: 12_345, timescale: 96_000)

        let sample = try XCTUnwrap(NCSoundBuffers.sampleBuffer(from: original, at: time))
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(sample), time)
        XCTAssertEqual(CMSampleBufferGetNumSamples(sample), 256)

        var converter: AVAudioConverter?
        let back = try XCTUnwrap(NCSoundBuffers.pcmBuffer(from: sample, converter: &converter))
        XCTAssertNil(converter, "float non-interleaved sound needs no converting")
        let a = try XCTUnwrap(original.floatChannelData)
        let b = try XCTUnwrap(back.floatChannelData)
        for channel in 0..<2 {
            for index in 0..<256 {
                XCTAssertEqual(a[channel][index], b[channel][index])
            }
        }
    }

    /// Sound that arrives as 16-bit integers, as the dongle describes its own,
    /// is converted to float at the same rate and channel count.
    func testIntegerSoundIsConvertedToFloat() throws {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: 96_000, channels: 1, interleaved: true))
        let integers = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64))
        integers.frameLength = 64
        let data = try XCTUnwrap(integers.int16ChannelData)
        for index in 0..<64 { data[0][index] = 6_656 }  // about 0.2 of full scale
        let sample = try XCTUnwrap(
            NCSoundBuffers.sampleBuffer(from: integers, at: .zero))

        var converter: AVAudioConverter?
        let converted = try XCTUnwrap(NCSoundBuffers.pcmBuffer(from: sample, converter: &converter))
        XCTAssertEqual(converted.format.commonFormat, .pcmFormatFloat32)
        XCTAssertFalse(converted.format.isInterleaved)
        XCTAssertEqual(converted.format.sampleRate, 96_000)
        XCTAssertEqual(converted.frameLength, 64)
        XCTAssertEqual(try XCTUnwrap(converted.floatChannelData)[0][10], 0.2031, accuracy: 0.001)
    }
}
