import CoreVideo
import XCTest

// MARK: - The crop model

final class NCFrameCropTests: XCTestCase {
    /// A value read back from UserDefaults may be anything; negative margins
    /// become zero rather than growing the picture.
    func testNegativeMarginsNormaliseToZero() {
        XCTAssertEqual(NCFrameCrop(top: -1, left: -20, bottom: 3, right: -4),
                       NCFrameCrop(top: 0, left: 0, bottom: 3, right: 0))
    }

    /// Core Image's y runs upwards, so the kept rectangle starts at the bottom
    /// margin, not the top one.
    func testKeptRectIsInCoreImageSpace() {
        let crop = NCFrameCrop(top: 10, left: 16, bottom: 4, right: 2)
        XCTAssertEqual(
            crop.keptRect(width: 720, height: 576),
            CGRect(x: 16, y: 4, width: 702, height: 562))
    }

    func testKeptSizeFallsBackToTheWholePictureWhenNothingIsLeft() {
        let crop = NCFrameCrop(top: 0, left: 400, bottom: 0, right: 320)
        XCTAssertNil(crop.keptRect(width: 720, height: 576))
        XCTAssertTrue(crop.keptSize(width: 720, height: 576) == (720, 576))
        XCTAssertTrue(NCFrameCrop.none.keptSize(width: 720, height: 576) == (720, 576))
    }
}

// MARK: - The orientation mapping

/// The settings-to-geometry mapping, asserted against a table written out by
/// hand from the cycle AVFoundation documents rather than derived from
/// `NCFrameOrientation`, so the two can disagree.
final class NCFrameOrientationTests: XCTestCase {
    /// The settings walk the cycle
    /// `[portrait, landscapeLeft, portraitUpsideDown, landscapeRight]`, which
    /// is `[0, 90, 180, 270]` degrees clockwise, and `isUpsideDown` selects the
    /// entry two places along. All sixteen combinations of the three settings
    /// are covered: four positions, mirrored or not, upside-down or not.
    private static let expectedTurns: [(position: Int, upsideDown: Bool, turns: Int)] = [
        (0, false, 0), (1, false, 1), (2, false, 2), (3, false, 3),
        (0, true, 2), (1, true, 3), (2, true, 0), (3, true, 1),
    ]

    func testEverySettingsCombinationMapsToTheExpectedGeometry() {
        for expected in Self.expectedTurns {
            for isMirrored in [false, true] {
                let orientation = NCFrameOrientation(
                    position: expected.position,
                    isMirrored: isMirrored,
                    isUpsideDown: expected.upsideDown)

                XCTAssertEqual(
                    orientation.quarterTurnsClockwise, expected.turns,
                    "position \(expected.position), upsideDown \(expected.upsideDown)")
                XCTAssertEqual(
                    orientation.mirroredInSourceSpace, isMirrored,
                    "mirroring is carried through untouched by rotation")
            }
        }
    }

    /// `isUpsideDown` is a half-turn wearing a mirror's name, so the eight
    /// `(position, isUpsideDown)` pairs collapse onto four distinct
    /// orientations. Distinct settings do not imply distinct pixels.
    func testUpsideDownIsAHalfTurnSoTheStateSpaceIsDegenerate() {
        for position in 0...3 {
            let upright = NCFrameOrientation(
                position: position, isMirrored: false, isUpsideDown: false)
            let halfTurnedTwice = NCFrameOrientation(
                position: (position + 2) % 4, isMirrored: false, isUpsideDown: true)

            XCTAssertEqual(
                upright, halfTurnedTwice,
                "position \(position) upright must equal position \((position + 2) % 4) upside-down")
        }

        XCTAssertEqual(
            NCFrameOrientation(position: 0, isMirrored: false, isUpsideDown: true),
            NCFrameOrientation(position: 2, isMirrored: false, isUpsideDown: false),
            "the pair the specification calls out by name")
    }

    /// A vertical flip and a half-turn agree on the two positions where the
    /// picture is upright and disagree on the other two. Implementing
    /// *Mirror Vertically* as a flip is wrong in a way that still looks
    /// plausible, so the difference is pinned down here.
    func testAHalfTurnIsNotAVerticalFlip() {
        let flippedThenRotated = NCFrameOrientation(
            position: 1, isMirrored: false, isUpsideDown: true)
        XCTAssertEqual(flippedThenRotated.quarterTurnsClockwise, 3)
        XCTAssertFalse(
            flippedThenRotated.mirroredInSourceSpace,
            "upside-down must never set the mirror flag")
    }

    /// The app only ever stores 0...3, but a pure function has no previous
    /// orientation to fall back on, so out-of-range positions normalise.
    func testOutOfRangePositionsNormalise() {
        XCTAssertEqual(
            NCFrameOrientation(position: 4, isMirrored: false, isUpsideDown: false)
                .quarterTurnsClockwise, 0)
        XCTAssertEqual(
            NCFrameOrientation(position: -1, isMirrored: false, isUpsideDown: false)
                .quarterTurnsClockwise, 3)
    }
}

// MARK: - The pixel transform

/// Exercises the transform over synthesised pixel buffers, so nothing here
/// needs a camera, a capture session or a window.
final class NCFrameTransformTests: XCTestCase {
    private let sourceWidth = 4
    private let sourceHeight = 2

    // MARK: - The model under test, restated

    /// Where a source pixel is expected to land, stated in display space —
    /// column 0 on the left, row 0 at the top — and built from first
    /// principles rather than from the transform's own matrices.
    private func expectedDestination(
        ofColumn column: Int, row: Int, width: Int, height: Int,
        orientation: NCFrameOrientation
    ) -> (column: Int, row: Int) {
        var x = column
        var y = row
        var w = width
        var h = height

        // Mirror first, in the source's own space: left-to-right becomes
        // right-to-left before any rotation is considered.
        if orientation.mirroredInSourceSpace {
            x = w - 1 - x
        }

        // Then quarter turns clockwise. One turn takes a w x h picture to an
        // h x w picture, sending the top edge to the right edge.
        for _ in 0..<orientation.quarterTurnsClockwise {
            (x, y) = (h - 1 - y, x)
            swap(&w, &h)
        }

        return (x, y)
    }

    // MARK: - Tests

    /// The round trip through Core Image and back into a pixel buffer must be
    /// the identity when nothing is asked of it. If this fails, every other
    /// assertion here is measuring a coordinate-space accident rather than the
    /// transform.
    func testIdentityLeavesEveryPixelWhereItWas() throws {
        let source = try makePixelBuffer(width: sourceWidth, height: sourceHeight)
        let transform = NCFrameTransform()
        let orientation = NCFrameOrientation(
            position: 0, isMirrored: false, isUpsideDown: false)

        let result = try XCTUnwrap(transform.apply(orientation, to: source))

        XCTAssertEqual(CVPixelBufferGetWidth(result), sourceWidth)
        XCTAssertEqual(CVPixelBufferGetHeight(result), sourceHeight)
        for row in 0..<sourceHeight {
            for column in 0..<sourceWidth {
                XCTAssertEqual(
                    readPixel(result, column: column, row: row),
                    expectedPixel(column: column, row: row),
                    "pixel (\(column), \(row)) survived the round trip unchanged")
            }
        }
    }

    /// Every source pixel lands where the model says, for all sixteen
    /// combinations of position, mirroring and upside-down.
    func testEveryCombinationMovesEveryPixelToTheModelledPlace() throws {
        let transform = NCFrameTransform()

        for position in 0...3 {
            for isMirrored in [false, true] {
                for isUpsideDown in [false, true] {
                    let orientation = NCFrameOrientation(
                        position: position,
                        isMirrored: isMirrored,
                        isUpsideDown: isUpsideDown)
                    let label =
                        "position \(position), mirrored \(isMirrored), upsideDown \(isUpsideDown)"

                    let source = try makePixelBuffer(
                        width: sourceWidth, height: sourceHeight)
                    let result = try XCTUnwrap(
                        transform.apply(orientation, to: source), label)

                    let turned = orientation.quarterTurnsClockwise % 2 == 1
                    let expectedWidth = turned ? sourceHeight : sourceWidth
                    let expectedHeight = turned ? sourceWidth : sourceHeight
                    XCTAssertEqual(
                        CVPixelBufferGetWidth(result), expectedWidth,
                        "width after \(label)")
                    XCTAssertEqual(
                        CVPixelBufferGetHeight(result), expectedHeight,
                        "height after \(label)")

                    for row in 0..<sourceHeight {
                        for column in 0..<sourceWidth {
                            let place = expectedDestination(
                                ofColumn: column, row: row,
                                width: sourceWidth, height: sourceHeight,
                                orientation: orientation)
                            XCTAssertEqual(
                                readPixel(result, column: place.column, row: place.row),
                                expectedPixel(column: column, row: row),
                                "source pixel (\(column), \(row)) under \(label)")
                        }
                    }
                }
            }
        }
    }

    /// The degeneracy again, this time in pixels rather than in the model:
    /// two different settings tuples must produce byte-identical pictures.
    func testDegenerateSettingsProduceIdenticalPictures() throws {
        let transform = NCFrameTransform()

        let viaUpsideDown = try XCTUnwrap(
            transform.apply(
                NCFrameOrientation(position: 0, isMirrored: false, isUpsideDown: true),
                to: try makePixelBuffer(width: sourceWidth, height: sourceHeight)))
        let viaPosition = try XCTUnwrap(
            transform.apply(
                NCFrameOrientation(position: 2, isMirrored: false, isUpsideDown: false),
                to: try makePixelBuffer(width: sourceWidth, height: sourceHeight)))

        for row in 0..<sourceHeight {
            for column in 0..<sourceWidth {
                XCTAssertEqual(
                    readPixel(viaUpsideDown, column: column, row: row),
                    readPixel(viaPosition, column: column, row: row),
                    "(0, upsideDown) and (2, upright) at (\(column), \(row))")
            }
        }
    }

    /// The consequence of mirroring in the source's pre-rotation space: the
    /// same mirror flag reads left-right at the upright positions and
    /// top-bottom at the quarter-turned ones. This is the part of the
    /// specification no line of the app computes, and the part a check limited
    /// to 0 and 180 degrees would miss.
    func testMirroringReadsLeftRightUprightAndTopBottomQuarterTurned() throws {
        let transform = NCFrameTransform()

        for position in [0, 2] {
            let orientation = NCFrameOrientation(
                position: position, isMirrored: true, isUpsideDown: false)
            let plain = NCFrameOrientation(
                position: position, isMirrored: false, isUpsideDown: false)
            let mirrored = try XCTUnwrap(
                transform.apply(
                    orientation, to: try makePixelBuffer(width: sourceWidth, height: sourceHeight)))
            let unmirrored = try XCTUnwrap(
                transform.apply(
                    plain, to: try makePixelBuffer(width: sourceWidth, height: sourceHeight)))

            for row in 0..<sourceHeight {
                for column in 0..<sourceWidth {
                    XCTAssertEqual(
                        readPixel(mirrored, column: column, row: row),
                        readPixel(unmirrored, column: sourceWidth - 1 - column, row: row),
                        "position \(position) mirrors across the vertical axis")
                }
            }
        }

        for position in [1, 3] {
            let orientation = NCFrameOrientation(
                position: position, isMirrored: true, isUpsideDown: false)
            let plain = NCFrameOrientation(
                position: position, isMirrored: false, isUpsideDown: false)
            let mirrored = try XCTUnwrap(
                transform.apply(
                    orientation, to: try makePixelBuffer(width: sourceWidth, height: sourceHeight)))
            let unmirrored = try XCTUnwrap(
                transform.apply(
                    plain, to: try makePixelBuffer(width: sourceWidth, height: sourceHeight)))

            // A quarter turn swaps the picture's dimensions.
            for row in 0..<sourceWidth {
                for column in 0..<sourceHeight {
                    XCTAssertEqual(
                        readPixel(mirrored, column: column, row: row),
                        readPixel(unmirrored, column: column, row: sourceWidth - 1 - row),
                        "position \(position) mirrors across the horizontal axis")
                }
            }
        }
    }

    /// The pool is rebuilt whenever the output dimensions change, which every
    /// alternation between an upright and a quarter-turned position does.
    func testAlternatingBetweenUprightAndQuarterTurnedKeepsWorking() throws {
        let transform = NCFrameTransform()

        for position in [0, 1, 0, 3, 2, 1] {
            let source = try makePixelBuffer(width: sourceWidth, height: sourceHeight)
            let orientation = NCFrameOrientation(
                position: position, isMirrored: false, isUpsideDown: false)
            let result = try XCTUnwrap(transform.apply(orientation, to: source))

            let turned = orientation.quarterTurnsClockwise % 2 == 1
            XCTAssertEqual(
                CVPixelBufferGetWidth(result), turned ? sourceHeight : sourceWidth,
                "position \(position)")
        }
    }

    // MARK: - Cropping

    /// A crop with a different margin on every side, over a picture large
    /// enough that each margin leaves something, so a top mistaken for a
    /// bottom or a left for a right cannot pass. Four rows at most, because
    /// the synthesised colours run out of a byte beyond that.
    private let cropWidth = 7
    private let cropHeight = 4
    private let asymmetricCrop = NCFrameCrop(top: 1, left: 2, bottom: 0, right: 3)

    /// Without any orientation, cropping keeps exactly the pixels inside the
    /// margins, measured from the top-left as the picture is displayed.
    func testCropKeepsExactlyThePixelsInsideTheMargins() throws {
        let transform = NCFrameTransform()
        let source = try makePixelBuffer(width: cropWidth, height: cropHeight)
        let upright = NCFrameOrientation(position: 0, isMirrored: false, isUpsideDown: false)

        let result = try XCTUnwrap(transform.apply(upright, cropping: asymmetricCrop, to: source))

        let keptWidth = cropWidth - asymmetricCrop.left - asymmetricCrop.right
        let keptHeight = cropHeight - asymmetricCrop.top - asymmetricCrop.bottom
        XCTAssertEqual(CVPixelBufferGetWidth(result), keptWidth)
        XCTAssertEqual(CVPixelBufferGetHeight(result), keptHeight)
        for row in 0..<keptHeight {
            for column in 0..<keptWidth {
                XCTAssertEqual(
                    readPixel(result, column: column, row: row),
                    expectedPixel(
                        column: column + asymmetricCrop.left, row: row + asymmetricCrop.top),
                    "kept pixel (\(column), \(row))")
            }
        }
    }

    /// The crop is taken in the camera's own space, before mirroring and
    /// turning: for every orientation, the result is the cropped picture moved
    /// exactly as the uncropped one would have been.
    func testCropIsTakenBeforeEveryOrientation() throws {
        let transform = NCFrameTransform()
        let keptWidth = cropWidth - asymmetricCrop.left - asymmetricCrop.right
        let keptHeight = cropHeight - asymmetricCrop.top - asymmetricCrop.bottom

        for position in 0...3 {
            for isMirrored in [false, true] {
                let orientation = NCFrameOrientation(
                    position: position, isMirrored: isMirrored, isUpsideDown: false)
                let label = "position \(position), mirrored \(isMirrored)"
                let source = try makePixelBuffer(width: cropWidth, height: cropHeight)

                let result = try XCTUnwrap(
                    transform.apply(orientation, cropping: asymmetricCrop, to: source), label)

                let turned = orientation.quarterTurnsClockwise % 2 == 1
                XCTAssertEqual(
                    CVPixelBufferGetWidth(result), turned ? keptHeight : keptWidth, label)
                XCTAssertEqual(
                    CVPixelBufferGetHeight(result), turned ? keptWidth : keptHeight, label)

                for row in 0..<keptHeight {
                    for column in 0..<keptWidth {
                        let place = expectedDestination(
                            ofColumn: column, row: row,
                            width: keptWidth, height: keptHeight,
                            orientation: orientation)
                        XCTAssertEqual(
                            readPixel(result, column: place.column, row: place.row),
                            expectedPixel(
                                column: column + asymmetricCrop.left,
                                row: row + asymmetricCrop.top),
                            "kept pixel (\(column), \(row)) under \(label)")
                    }
                }
            }
        }
    }

    /// Margins that would leave nothing are not applied: the picture stays
    /// whole rather than disappearing.
    func testACropThatLeavesNothingIsNotApplied() throws {
        let transform = NCFrameTransform()
        let upright = NCFrameOrientation(position: 0, isMirrored: false, isUpsideDown: false)

        for crop in [
            NCFrameCrop(top: 0, left: 4, bottom: 0, right: 3),
            NCFrameCrop(top: 4, left: 0, bottom: 0, right: 0),
        ] {
            let source = try makePixelBuffer(width: cropWidth, height: cropHeight)
            let result = try XCTUnwrap(transform.apply(upright, cropping: crop, to: source))
            XCTAssertEqual(CVPixelBufferGetWidth(result), cropWidth, "\(crop)")
            XCTAssertEqual(CVPixelBufferGetHeight(result), cropHeight, "\(crop)")
            XCTAssertEqual(
                readPixel(result, column: 0, row: 0), expectedPixel(column: 0, row: 0),
                "\(crop)")
        }
    }

    /// Changing the crop changes the output's size, which rebuilds the pool;
    /// going back and forth must keep producing frames of the right size.
    func testChangingTheCropKeepsWorking() throws {
        let transform = NCFrameTransform()
        let upright = NCFrameOrientation(position: 0, isMirrored: false, isUpsideDown: false)

        for crop in [asymmetricCrop, .none, NCFrameCrop(top: 1, left: 0, bottom: 1, right: 0),
                     asymmetricCrop]
        {
            let source = try makePixelBuffer(width: cropWidth, height: cropHeight)
            let result = try XCTUnwrap(transform.apply(upright, cropping: crop, to: source))
            let kept = crop.keptSize(width: cropWidth, height: cropHeight)
            XCTAssertEqual(CVPixelBufferGetWidth(result), kept.width, "\(crop)")
            XCTAssertEqual(CVPixelBufferGetHeight(result), kept.height, "\(crop)")
        }
    }

    // MARK: - Synthesised pixel buffers

    /// A distinct colour per pixel, so a transposition cannot pass for a
    /// rotation and a mirror cannot pass for the identity.
    private func expectedPixel(column: Int, row: Int) -> Pixel {
        Pixel(
            blue: UInt8(17 + column * 23),
            green: UInt8(41 + row * 61),
            red: UInt8(97 + column * 7 + row * 3))
    }

    private struct Pixel: Equatable, CustomStringConvertible {
        let blue: UInt8
        let green: UInt8
        let red: UInt8

        var description: String { "b\(blue) g\(green) r\(red)" }
    }

    private func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary] as CFDictionary,
            &buffer)
        let created = try XCTUnwrap(buffer, "CVPixelBufferCreate returned \(status)")

        CVPixelBufferLockBaseAddress(created, [])
        defer { CVPixelBufferUnlockBaseAddress(created, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(created))
            .assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(created)

        for row in 0..<height {
            for column in 0..<width {
                let pixel = expectedPixel(column: column, row: row)
                let offset = row * bytesPerRow + column * 4
                base[offset] = pixel.blue
                base[offset + 1] = pixel.green
                base[offset + 2] = pixel.red
                base[offset + 3] = 255
            }
        }
        return created
    }

    private func readPixel(_ buffer: CVPixelBuffer, column: Int, row: Int) -> Pixel {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?
            .assumingMemoryBound(to: UInt8.self)
        else {
            return Pixel(blue: 0, green: 0, red: 0)
        }
        let offset = row * CVPixelBufferGetBytesPerRow(buffer) + column * 4
        return Pixel(blue: base[offset], green: base[offset + 1], red: base[offset + 2])
    }
}
