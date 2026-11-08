import AppKit
import CoreMedia
import CoreVideo
import XCTest

// MARK: - Still capture

/// One frame out of the pipeline, once. Nothing here needs a camera, a window
/// or a save panel: a still request is a sink that registers, takes the first
/// frame it is given and leaves, and all of that is decidable over synthesised
/// buffers.
final class NCStillCaptureTests: XCTestCase {
    // MARK: - One frame in, one picture out

    func testOneFrameProducesOnePictureAtTheSourceResolution() throws {
        let distributor = NCFrameDistributor()
        let delivered = expectation(description: "the request answered")
        var captured: CGImage?

        NCStillCapture.requestStill(from: distributor, timeout: 5.0) { result in
            captured = try? result.get()
            delivered.fulfill()
        }
        distributor.deliver(try makePixelBuffer(width: 6, height: 4), at: .zero)
        wait(for: [delivered], timeout: 5.0)

        let image = try XCTUnwrap(captured, "a frame arrived, so a picture must have come back")
        // The frame's own size, not a window's: the whole point of taking the
        // picture from the pipeline rather than from the screen.
        XCTAssertEqual(image.width, 6)
        XCTAssertEqual(image.height, 4)
    }

    // MARK: - Pasteboard

    /// The copied picture comes back off the pasteboard as both PNG and TIFF,
    /// each at the still's own size. A private pasteboard, so the test leaves
    /// the user's clipboard alone.
    func testACopiedStillIsOnThePasteboardAsPNGAndTIFFAtItsOwnSize() throws {
        let distributor = NCFrameDistributor()
        let delivered = expectation(description: "the request answered")
        var captured: CGImage?
        NCStillCapture.requestStill(from: distributor, timeout: 5.0) { result in
            captured = try? result.get()
            delivered.fulfill()
        }
        distributor.deliver(try makePixelBuffer(width: 6, height: 4), at: .zero)
        wait(for: [delivered], timeout: 5.0)
        let image = try XCTUnwrap(captured)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("NCStillCaptureTests.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("something else", forType: .string)

        XCTAssertTrue(NCStillCapture.copy(image, to: pasteboard))

        XCTAssertNil(pasteboard.string(forType: .string), "the copy replaces what was there")
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            let data = try XCTUnwrap(pasteboard.data(forType: type), "\(type.rawValue)")
            let read = try XCTUnwrap(NSBitmapImageRep(data: data), "\(type.rawValue)")
            XCTAssertEqual(read.pixelsWide, 6, "\(type.rawValue)")
            XCTAssertEqual(read.pixelsHigh, 4, "\(type.rawValue)")
        }
    }

    // MARK: - Exactly once

    /// Frames arrive on the capture queue and the timeout is counted elsewhere,
    /// so a second frame can reach a request that has already answered. It must
    /// produce nothing at all — a save panel opening twice, or a completion
    /// running twice over one request, is a defect the user sees.
    func testASecondFrameProducesNoSecondAnswer() throws {
        let distributor = NCFrameDistributor()
        let delivered = expectation(description: "the request answered")
        var answers = 0

        let request = NCStillCapture.requestStill(from: distributor, timeout: 5.0) { _ in
            answers += 1
            // Fulfilling twice is itself a test failure, which is the assertion
            // this line is here to make.
            delivered.fulfill()
        }

        let buffer = try makePixelBuffer(width: 4, height: 4)
        request.receive(buffer, at: .zero)
        request.receive(buffer, at: CMTime(value: 1, timescale: 600))
        wait(for: [delivered], timeout: 5.0)

        drainTheMainQueue()
        XCTAssertEqual(answers, 1, "one request, one answer, however many frames arrive")
    }

    func testAFrameArrivingAfterTheTimeoutProducesNoSecondAnswer() throws {
        let distributor = NCFrameDistributor()
        let failed = expectation(description: "the request timed out")
        var answers = 0

        let request = NCStillCapture.requestStill(from: distributor, timeout: 0.2) { _ in
            answers += 1
            failed.fulfill()
        }
        wait(for: [failed], timeout: 5.0)

        request.receive(try makePixelBuffer(width: 4, height: 4), at: .zero)
        drainTheMainQueue()
        XCTAssertEqual(answers, 1, "a late frame answers nothing; the request is already over")
    }

    // MARK: - Leaving the pipeline

    func testTheRequestUnregistersItselfOnceItHasItsFrame() throws {
        let distributor = NCFrameDistributor()
        let delivered = expectation(description: "the request answered")

        NCStillCapture.requestStill(from: distributor, timeout: 5.0) { _ in delivered.fulfill() }
        XCTAssertEqual(distributor.sinkCount, 1, "the request is registered while it waits")

        distributor.deliver(try makePixelBuffer(width: 4, height: 4), at: .zero)

        // Removal happens inside the delivery, before the answer is reported,
        // so a request cannot still be taking frames after it has answered.
        XCTAssertEqual(distributor.sinkCount, 0)
        wait(for: [delivered], timeout: 5.0)
        XCTAssertEqual(distributor.sinkCount, 0)
    }

    // MARK: - Nothing arrives

    /// No session running, or the camera unplugged mid-request. The request
    /// must report rather than wait for ever: saving that hangs silently is
    /// worse than saving that fails.
    func testARequestThatIsNeverGivenAFrameFailsWithAReason() throws {
        let distributor = NCFrameDistributor()
        let failed = expectation(description: "the request reported a failure")
        var failure: NCStillCapture.Failure?

        NCStillCapture.requestStill(from: distributor, timeout: 0.2) { result in
            if case .failure(let reason) = result { failure = reason }
            failed.fulfill()
        }
        wait(for: [failed], timeout: 5.0)

        let reason = try XCTUnwrap(failure, "a request given no frame must report one")
        guard case .noFrameArrived(let seconds) = reason else {
            return XCTFail("a request given no frame fails because no frame arrived")
        }
        XCTAssertEqual(seconds, 0.2, accuracy: 0.001)
        XCTAssertFalse(
            reason.message.isEmpty,
            "the failure carries wording that can be put in front of a user")
        XCTAssertEqual(distributor.sinkCount, 0, "a failed request leaves the pipeline too")
    }

    // MARK: - Helpers

    /// Waits until everything already queued on the main queue has run, so an
    /// answer that was going to arrive has arrived before it is counted.
    private func drainTheMainQueue() {
        let drained = expectation(description: "the main queue has run its backlog")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 5.0)
    }

    /// A buffer of the shape and pixel format the capture path produces.
    /// IOSurface-backed because that is what the transform's pool vends and
    /// what Core Image renders from.
    private func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &buffer)
        return try XCTUnwrap(buffer, "CVPixelBufferCreate returned \(status)")
    }
}
