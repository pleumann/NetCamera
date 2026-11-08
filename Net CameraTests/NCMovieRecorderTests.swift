import AVFoundation
import CoreVideo
import XCTest

// MARK: - Geometry

final class NCRecordingGeometryTests: XCTestCase {
    /// A picture's own size, rounded down to even sizes for the encoder, when
    /// no size is asked for; the size asked for otherwise.
    func testTheOutputSizeIsTheRequestedOneOrThePicturesOwnMadeEven() {
        XCTAssertEqual(
            NCRecordingGeometry.outputSize(
                for: CGSize(width: 703, height: 575), options: NCRecordingOptions()),
            CGSize(width: 702, height: 574))
        XCTAssertEqual(
            NCRecordingGeometry.outputSize(
                for: CGSize(width: 704, height: 576),
                options: NCRecordingOptions(size: NCResolution(width: 2048, height: 1536))),
            CGSize(width: 2048, height: 1536))
    }

    /// Stretching fills the frame; keeping proportions centres the largest
    /// rectangle of the picture's shape, leaving bars on two sides only.
    func testPlacementStretchesOrCentresWithBars() {
        let output = CGSize(width: 2048, height: 1536)
        let pal = CGSize(width: 720, height: 576)

        XCTAssertEqual(
            NCRecordingGeometry.placement(of: pal, in: output, keepingProportions: false),
            CGRect(x: 0, y: 0, width: 2048, height: 1536))
        XCTAssertEqual(
            NCRecordingGeometry.placement(of: pal, in: output, keepingProportions: true),
            CGRect(x: 64, y: 0, width: 1920, height: 1536))
        XCTAssertEqual(
            NCRecordingGeometry.placement(
                of: CGSize(width: 1920, height: 1080), in: output, keepingProportions: true),
            CGRect(x: 0, y: 192, width: 2048, height: 1152))
    }
}

// MARK: - Recorder

/// Real movie files, written to a temporary folder and read back.
final class NCMovieRecorderTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("NCMovieRecorderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Helpers

    /// A frame of one flat colour, distinct per frame, so a written file has
    /// something real in it.
    private func makeFrame(width: Int, height: Int, shade: UInt8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary] as CFDictionary,
            &buffer)
        let frame = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(frame, [])
        defer { CVPixelBufferUnlockBaseAddress(frame, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(frame))
        memset(base, Int32(shade), CVPixelBufferGetBytesPerRow(frame) * height)
        return frame
    }

    private func time(_ frame: Int) -> CMTime {
        CMTime(value: CMTimeValue(frame), timescale: 25)
    }

    /// Records the given frames, stopping afterwards unless the recorder has
    /// already stopped itself, and waits for the outcome.
    private func record(
        _ frames: [(width: Int, height: Int)], options: NCRecordingOptions = NCRecordingOptions(),
        withSound: Bool = false
    ) async throws -> (NCMovieRecorder.Outcome, NCFrameDistributor) {
        let distributor = NCFrameDistributor()
        let url = folder.appendingPathComponent("movie.mov")
        let ended = expectation(description: "the recording ended")
        var outcome: NCMovieRecorder.Outcome?
        let soundFormat = withSound ? try makeSoundFormat() : nil
        let recorder = NCMovieRecorder.start(
            recordingTo: url, options: options, soundFormat: soundFormat, from: distributor
        ) {
            outcome = $0
            ended.fulfill()
        }

        for (index, size) in frames.enumerated() {
            distributor.deliver(
                try makeFrame(width: size.width, height: size.height, shade: UInt8(index * 20)),
                at: time(index))
            // One frame's worth of sound, on the same clock: 1920 samples at
            // 48 kHz is the 40 ms between two frames at 25 fps.
            if let soundFormat {
                recorder.receiveSound(try makeSound(format: soundFormat, at: time(index)))
            }
            // An encoder given frames faster than real time may refuse some;
            // a little pacing keeps the counts meaningful without making the
            // test depend on them.
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        recorder.stop()
        await fulfillment(of: [ended], timeout: 10)
        return (try XCTUnwrap(outcome), distributor)
    }

    private func videoTrack(at url: URL) async throws -> (size: CGSize, samples: Int) {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var samples = 0
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) > 0 { samples += 1 }
        }
        return (size, samples)
    }

    // MARK: - Sound

    /// Stereo 32-bit float at 48 kHz, interleaved.
    private func makeSoundFormat() throws -> CMAudioFormatDescription {
        var description = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        return try XCTUnwrap(format)
    }

    /// 1920 frames of silence starting at `time`.
    private func makeSound(format: CMAudioFormatDescription, at time: CMTime) throws
        -> CMSampleBuffer
    {
        let frames = 1920
        let length = frames * 8
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        let data = try XCTUnwrap(block)
        CMBlockBufferFillDataBytes(with: 0, blockBuffer: data, offsetIntoDestination: 0, dataLength: length)

        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: data, formatDescription: format,
            sampleCount: frames, presentationTimeStamp: time, packetDescriptions: nil,
            sampleBufferOut: &sample)
        return try XCTUnwrap(sample)
    }

    private func soundTrackCount(at url: URL) async throws -> Int {
        try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).count
    }

    /// AAC goes no further than 48 kHz and the track no further than stereo;
    /// what comes in below that is kept.
    func testTheSoundTrackIsAACWithinWhatAACTakes() throws {
        var description = AudioStreamBasicDescription(
            mSampleRate: 96_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)

        let settings = NCMovieRecorder.soundSettings(for: try XCTUnwrap(format))
        XCTAssertEqual(settings[AVFormatIDKey] as? AudioFormatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(settings[AVSampleRateKey] as? Double, 48_000)
        XCTAssertEqual(settings[AVNumberOfChannelsKey] as? Int, 1)
    }

    func testARecordingWithSoundHasASoundTrack() async throws {
        let (outcome, _) = try await record(Array(repeating: (128, 96), count: 10), withSound: true)

        XCTAssertEqual(outcome.ending, .stopped)
        let soundTracks = try await soundTrackCount(at: outcome.url)
        XCTAssertEqual(soundTracks, 1)
        let track = try await videoTrack(at: outcome.url)
        XCTAssertEqual(track.samples, outcome.framesWritten, "the picture is unaffected")
    }

    func testARecordingWithoutSoundHasNoSoundTrack() async throws {
        let (outcome, _) = try await record(Array(repeating: (128, 96), count: 5))
        let soundTracks = try await soundTrackCount(at: outcome.url)
        XCTAssertEqual(soundTracks, 0)
    }

    // MARK: - Tests

    func testFramesAreWrittenAtThePicturesOwnSize() async throws {
        let (outcome, distributor) = try await record(Array(repeating: (128, 96), count: 10))

        XCTAssertEqual(outcome.ending, .stopped)
        XCTAssertEqual(outcome.framesWritten + outcome.framesDropped, 10)
        XCTAssertGreaterThan(outcome.framesWritten, 0)
        XCTAssertEqual(distributor.sinkCount, 0, "a finished recording takes no more frames")

        let track = try await videoTrack(at: outcome.url)
        XCTAssertEqual(track.size, CGSize(width: 128, height: 96))
        XCTAssertEqual(track.samples, outcome.framesWritten)
    }

    func testFramesAreScaledToTheRequestedSizeBothWays() async throws {
        for isSharp in [false, true] {
            let options = NCRecordingOptions(
                size: NCResolution(width: 256, height: 192), isSharp: isSharp,
                keepsProportions: true)
            let (outcome, _) = try await record(Array(repeating: (128, 80), count: 5), options: options)

            XCTAssertEqual(outcome.ending, .stopped, "sharp \(isSharp)")
            let track = try await videoTrack(at: outcome.url)
            XCTAssertEqual(track.size, CGSize(width: 256, height: 192), "sharp \(isSharp)")
        }
    }

    /// A picture that changes size ends the recording, keeping the frames
    /// recorded before the change in a file that plays.
    func testAPictureThatChangesSizeEndsTheRecordingAndKeepsWhatWasRecorded() async throws {
        let frames = Array(repeating: (128, 96), count: 5) + Array(repeating: (96, 128), count: 5)
        let (outcome, distributor) = try await record(frames)

        XCTAssertEqual(outcome.ending, .pictureChangedSize)
        XCTAssertLessThanOrEqual(outcome.framesWritten + outcome.framesDropped, 5)
        XCTAssertEqual(distributor.sinkCount, 0)

        let track = try await videoTrack(at: outcome.url)
        XCTAssertEqual(track.size, CGSize(width: 128, height: 96))
        XCTAssertEqual(track.samples, outcome.framesWritten)
    }

    /// Stopping before any frame arrived leaves no file and says why.
    func testARecordingWithNoFramesLeavesNoFile() async throws {
        let (outcome, _) = try await record([])

        guard case .failed = outcome.ending else {
            return XCTFail("expected a failure, got \(outcome.ending)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outcome.url.path))
    }
}
