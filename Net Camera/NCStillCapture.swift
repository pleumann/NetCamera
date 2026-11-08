import AppKit
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation

// MARK: - Still capture

/// Takes one picture out of the pipeline.
///
/// A saved still is a consumer of the processed frame exactly as the window is:
/// this registers as a sink, keeps the first frame it is handed, and leaves.
/// Nothing here photographs anything — what it produces is the camera's own
/// picture at its source resolution, the way round the user asked for it, with
/// nothing the window or the compositor did to it in the way.
///
/// It knows about the distributor and Core Image, and about no part of the
/// application: no capture session, no window, no menu. That is what lets it be
/// exercised over synthesised buffers with no camera present.
final class NCStillCapture: NCFrameSink {
    // MARK: - Failure

    /// Why a request produced no picture. Both cases carry wording fit to put
    /// in front of a user, because a request that quietly produces nothing is
    /// a defect rather than an outcome.
    enum Failure: Error {
        /// Nothing arrived inside the request's window: no session running, or
        /// the camera went away while the request was waiting.
        case noFrameArrived(TimeInterval)

        /// A frame arrived and Core Image would not turn it into an image.
        case frameCouldNotBeConverted

        var message: String {
            switch self {
            case .noFrameArrived(let seconds):
                return String(
                    format:
                        "Unfortunately, no picture arrived from the camera within %.0f seconds. Check that a camera is selected and try again.",
                    seconds)
            case .frameCouldNotBeConverted:
                return
                    "Unfortunately, the picture from the camera could not be converted to an image."
            }
        }
    }

    // MARK: - Properties

    /// How long a request waits before failing. Long enough to cover a capture
    /// session that is still starting up, short enough that a user who asked
    /// for a picture is told what happened rather than left watching nothing.
    static let defaultTimeout: TimeInterval = 5.0

    /// Where the request registered itself, and where it takes itself out of
    /// again the moment it has an answer.
    private let distributor: NCFrameDistributor

    private let completion: (Result<CGImage, Failure>) -> Void

    /// Colour management is off here as it is in the transform: this stage
    /// carries the camera's values to the file rather than reinterpreting them
    /// on the way.
    private let context: CIContext = CIContext(options: [.workingColorSpace: NSNull()])

    /// Whether the one answer this request will ever give has been claimed.
    /// A frame and the timeout race by construction — the timeout is counted on
    /// its own queue while frames arrive on the capture queue — so the claim is
    /// what makes "exactly once" true rather than likely.
    private let lock: NSLock = NSLock()
    private var hasDelivered: Bool = false

    /// Timeouts are counted here rather than on the main queue, so a request
    /// still fails on time while the main thread is busy.
    private static let timeoutQueue: DispatchQueue = DispatchQueue(
        label: "com.xalior.NetCamera.still-capture")

    // MARK: - Requesting a still

    /// Asks the pipeline for the next frame, as an image.
    ///
    /// The request registers itself and the distributor holds it until it
    /// answers, so a caller that keeps no reference still gets its picture.
    /// `completion` runs on the main queue exactly once, whether a frame
    /// arrived, could not be converted, or never came at all.
    @discardableResult
    static func requestStill(
        from distributor: NCFrameDistributor,
        timeout: TimeInterval = NCStillCapture.defaultTimeout,
        completion: @escaping (Result<CGImage, Failure>) -> Void
    ) -> NCStillCapture {
        let request = NCStillCapture(distributor: distributor, completion: completion)
        distributor.add(request)
        // Weakly held: a request that has already answered has left the
        // distributor and may be gone by the time this runs, which is the
        // ordinary case rather than an error.
        timeoutQueue.asyncAfter(deadline: .now() + timeout) { [weak request] in
            request?.timedOut(after: timeout)
        }
        return request
    }

    private init(
        distributor: NCFrameDistributor,
        completion: @escaping (Result<CGImage, Failure>) -> Void
    ) {
        self.distributor = distributor
        self.completion = completion
    }

    // MARK: - Pasteboard

    /// Puts a still on a pasteboard, replacing what was there, as PNG and as
    /// TIFF: PNG for the applications that take it, TIFF because it is what
    /// AppKit applications read first. Both carry the image's own pixels at
    /// its own size. Returns whether the pasteboard took it.
    @discardableResult
    static func copy(_ image: CGImage, to pasteboard: NSPasteboard = .general) -> Bool {
        let representation = NSBitmapImageRep(cgImage: image)
        guard let png = representation.representation(using: .png, properties: [:]),
            let tiff = representation.tiffRepresentation
        else {
            NSLog("NCStillCapture: the still could not be encoded for the pasteboard")
            return false
        }

        pasteboard.clearContents()
        let tookPNG = pasteboard.setData(png, forType: .png)
        let tookTIFF = pasteboard.setData(tiff, forType: .tiff)
        return tookPNG && tookTIFF
    }

    // MARK: - NCFrameSink

    /// Converts the frame and answers the request. Runs on the capture queue.
    ///
    /// The buffer is rendered here and never kept: it comes from the pool the
    /// transform shares with every other sink, so holding one past this call
    /// takes it out of circulation for as long as the request lives, and the
    /// protocol forbids writing to it in any case.
    func receive(_ frame: CVPixelBuffer, at time: CMTime) {
        guard claim() else { return }

        let picture: CIImage = CIImage(cvPixelBuffer: frame)
        // sRGB is a tag rather than a conversion: with colour management off
        // the camera's values reach the file untouched, and the file then says
        // what those values are meant to mean.
        let image: CGImage? = context.createCGImage(
            picture, from: picture.extent, format: .BGRA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB))

        guard let image else {
            NSLog("NCStillCapture: Core Image would not render the frame")
            finish(.failure(.frameCouldNotBeConverted))
            return
        }

        NSLog("NCStillCapture: still taken, %dx%d", image.width, image.height)
        finish(.success(image))
    }

    // MARK: - Answering exactly once

    /// Fails the request because no frame arrived. Runs on the timeout queue.
    private func timedOut(after timeout: TimeInterval) {
        guard claim() else { return }
        NSLog("NCStillCapture: no frame arrived within %.1fs", timeout)
        finish(.failure(.noFrameArrived(timeout)))
    }

    /// Claims the single answer this request will give. The first caller wins;
    /// every later one is told to do nothing whatsoever.
    private func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !hasDelivered else { return false }
        hasDelivered = true
        return true
    }

    /// Leaves the pipeline, then reports — in that order, because a request
    /// that has answered must not still be taking frames. Removal is safe from
    /// inside `receive`: the distributor releases its lock before it delivers.
    ///
    /// The report reaches the main queue because that is where the caller's
    /// user interface lives, and it is dispatched rather than called even when
    /// the answer was produced on the main queue, so a caller never finds its
    /// completion running inside its own request.
    private func finish(_ result: Result<CGImage, Failure>) {
        distributor.remove(self)
        DispatchQueue.main.async { [completion] in
            completion(result)
        }
    }
}
