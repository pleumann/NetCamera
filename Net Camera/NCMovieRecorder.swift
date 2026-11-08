import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation

// MARK: - Geometry

/// Where the picture goes in a recording's frame.
enum NCRecordingGeometry {
    /// The size a recording is written at: the requested size, or the
    /// picture's own, made even in both directions — H.264's 4:2:0 chroma
    /// covers pixels in pairs, and a crop can leave an odd number of them.
    static func outputSize(for picture: CGSize, options: NCRecordingOptions) -> CGSize {
        let wanted =
            options.size.map { CGSize(width: $0.width, height: $0.height) } ?? picture
        return CGSize(width: even(wanted.width), height: even(wanted.height))
    }

    /// The rectangle a `picture` is drawn into within a frame of `output`
    /// size: all of it when stretching, or the largest rectangle of the
    /// picture's proportions, centred, when keeping them. Whole pixels, so the
    /// edges of the black bars are hard.
    static func placement(of picture: CGSize, in output: CGSize, keepingProportions: Bool)
        -> CGRect
    {
        guard keepingProportions, picture.width > 0, picture.height > 0 else {
            return CGRect(origin: .zero, size: output)
        }
        let scale = min(output.width / picture.width, output.height / picture.height)
        let width = (picture.width * scale).rounded()
        let height = (picture.height * scale).rounded()
        return CGRect(
            x: ((output.width - width) / 2).rounded(.down),
            y: ((output.height - height) / 2).rounded(.down),
            width: width, height: height)
    }

    private static func even(_ value: CGFloat) -> CGFloat {
        max(2, (value / 2).rounded(.down) * 2)
    }
}

// MARK: - Recorder

/// Writes the processed picture to a movie file, as one more consumer of it.
///
/// The recording is made from the same frames the window draws — cropped,
/// turned and mirrored — at the size the profile asks for, scaled on the way
/// in and nowhere else. It is written with the times the camera stamped the
/// frames with, so a sound track taken from the same capture session can be
/// laid alongside later on the same clock.
///
/// A recording has one size from its first frame to its last. A picture that
/// changes size underneath it — a rotation, a different crop, resolution or
/// profile — ends the recording there, keeping everything recorded until then,
/// rather than squeezing the new picture into the old frame.
final class NCMovieRecorder: NCFrameSink {
    // MARK: - Outcome

    enum Ending: Equatable {
        /// Stopped when asked to.
        case stopped
        /// Stopped because the picture changed size.
        case pictureChangedSize
        /// Stopped because the file could not be written, with a reason fit to
        /// show a user. Nothing usable is left behind.
        case failed(String)
    }

    struct Outcome {
        let url: URL
        let ending: Ending
        let framesWritten: Int
        /// Frames that arrived while the encoder was still busy with earlier
        /// ones. Live video is not held up for an encoder that falls behind.
        let framesDropped: Int
    }

    // MARK: - Properties

    let url: URL
    private let options: NCRecordingOptions
    private let distributor: NCFrameDistributor
    private let completion: (Outcome) -> Void

    /// Colour management off, as in the rest of the pipeline: the camera's
    /// values are moved and scaled, never reinterpreted.
    private let context = CIContext(options: [.workingColorSpace: NSNull()])

    /// Frames arrive on the capture queue and a stop comes from the main
    /// thread, so everything below is touched only under this lock.
    private let lock = NSLock()
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var pictureSize: CGSize = .zero
    private var outputSize: CGSize = .zero
    private var framesWritten = 0
    private var framesDropped = 0
    private var isFinished = false

    // MARK: - Lifecycle

    /// Starts recording into `url`, replacing any file there, from the next
    /// frame `distributor` delivers. `completion` runs once, on the main queue,
    /// when the file is complete or has been given up.
    static func start(
        recordingTo url: URL, options: NCRecordingOptions, from distributor: NCFrameDistributor,
        completion: @escaping (Outcome) -> Void
    ) -> NCMovieRecorder {
        let recorder = NCMovieRecorder(
            url: url, options: options, distributor: distributor, completion: completion)
        distributor.add(recorder)
        return recorder
    }

    private init(
        url: URL, options: NCRecordingOptions, distributor: NCFrameDistributor,
        completion: @escaping (Outcome) -> Void
    ) {
        self.url = url
        self.options = options
        self.distributor = distributor
        self.completion = completion
    }

    /// Ends the recording and completes the file.
    func stop() {
        lock.lock()
        defer { lock.unlock() }
        finish(.stopped)
    }

    // MARK: - NCFrameSink

    func receive(_ frame: CVPixelBuffer, at time: CMTime) {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return }

        let size = CGSize(width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame))
        if writer == nil {
            do {
                try begin(with: size, at: time)
            } catch {
                finish(.failed("The recording could not be started: \(error.localizedDescription)"))
                return
            }
        } else if size != pictureSize {
            NSLog(
                "NCMovieRecorder: the picture went from %@ to %@, ending the recording",
                NSStringFromSize(pictureSize), NSStringFromSize(size))
            finish(.pictureChangedSize)
            return
        }

        guard let writer, let input, let adaptor else { return }
        guard input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else {
            framesDropped += 1
            return
        }

        var vended: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &vended)
        guard let destination = vended else {
            framesDropped += 1
            return
        }

        context.render(scaled(frame), to: destination)
        if adaptor.append(destination, withPresentationTime: time) {
            framesWritten += 1
        } else {
            finish(
                .failed(
                    "The recording could not be written: "
                        + (writer.error?.localizedDescription ?? "no reason given")))
        }
    }

    // MARK: - Writing

    private func begin(with size: CGSize, at time: CMTime) throws {
        pictureSize = size
        outputSize = NCRecordingGeometry.outputSize(for: size, options: options)

        // The save panel has already asked whether to replace the file.
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        let width = Int(outputSize.width)
        let height = Int(outputSize.height)
        // A generous rate, because the pictures this records are hard edges
        // and flat colour, which H.264 smears first when it is short of bits:
        // about 23 Mbit/s at 2048x1536 and 60 fps.
        let bitRate = min(max(Double(width * height) * 60 * 0.125, 2_000_000), 80_000_000)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(bitRate),
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
                AVVideoAllowFrameReorderingKey: true,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw NSError(
                domain: "NCMovieRecorder", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "the video track was refused"])
        }
        writer.add(input)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
            ])

        guard writer.startWriting() else {
            throw writer.error
                ?? NSError(
                    domain: "NCMovieRecorder", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "the file could not be opened"])
        }
        writer.startSession(atSourceTime: time)

        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        NSLog(
            "NCMovieRecorder: recording %@ as %dx%d to %@", NSStringFromSize(size), width, height,
            url.path)
    }

    /// The picture scaled into the output frame, over black.
    private func scaled(_ frame: CVPixelBuffer) -> CIImage {
        let frameRect = CGRect(origin: .zero, size: outputSize)
        let target = NCRecordingGeometry.placement(
            of: pictureSize, in: outputSize, keepingProportions: options.keepsProportions)
        let scaleX = target.width / pictureSize.width
        let scaleY = target.height / pictureSize.height

        // Clamped first, so the scaler sees picture rather than transparency
        // beyond the edges and does not darken them.
        var picture = CIImage(cvPixelBuffer: frame).clampedToExtent()
        if scaleX != 1 || scaleY != 1 {
            if options.isSharp {
                picture = picture.samplingNearest()
                    .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            } else {
                picture = picture.applyingFilter(
                    "CILanczosScaleTransform",
                    parameters: [
                        kCIInputScaleKey: scaleY,
                        kCIInputAspectRatioKey: scaleX / scaleY,
                    ])
            }
        }
        picture = picture
            .transformed(by: CGAffineTransform(translationX: target.minX, y: target.minY))
            .cropped(to: target)

        return picture.composited(over: CIImage(color: .black).cropped(to: frameRect))
    }

    /// Ends the recording once. Called with the lock held.
    private func finish(_ ending: Ending) {
        guard !isFinished else { return }
        isFinished = true
        distributor.remove(self)

        let url = self.url
        let written = framesWritten
        let dropped = framesDropped
        let completion = self.completion
        let report: (Ending) -> Void = { ending in
            NSLog(
                "NCMovieRecorder: %@, %d frames written, %d dropped",
                String(describing: ending), written, dropped)
            DispatchQueue.main.async {
                completion(
                    Outcome(url: url, ending: ending, framesWritten: written, framesDropped: dropped))
            }
        }

        guard let writer, let input, writer.status == .writing, written > 0 else {
            // Nothing worth keeping: no frame arrived, or the writer failed.
            self.writer?.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            if case .failed = ending {
                report(ending)
            } else {
                report(.failed("No picture arrived from the camera, so nothing was recorded."))
            }
            return
        }

        input.markAsFinished()
        writer.finishWriting {
            if writer.status == .completed {
                report(ending)
            } else {
                try? FileManager.default.removeItem(at: url)
                report(
                    .failed(
                        "The recording could not be completed: "
                            + (writer.error?.localizedDescription ?? "no reason given")))
            }
        }
    }
}
