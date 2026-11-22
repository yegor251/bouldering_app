import XCTest
@testable import BoulderBook

/// Regression for the "no holds detected" bug on device: photos from the
/// iPhone camera store pixels rotated with an EXIF orientation tag; the
/// pipeline must normalize them back to upright before inference.
/// wallR.jpg mimics a camera photo exactly (rotated pixels + EXIF 6).
final class DetectorTests: XCTestCase {

    func testDetectOnUprightPhoto() throws {
        let detector = try loadedDetector()
        let url = try XCTUnwrap(Bundle.main.url(forResource: "wall1", withExtension: "jpg"))
        let image = try XCTUnwrap(UIImage(data: try Data(contentsOf: url)))
        XCTAssertEqual(image.imageOrientation, .up)
        let holds = detector.detectSync(image: image)
        XCTAssertGreaterThan(holds.count, 20, "upright photo must detect holds")
    }

    func testDetectOnCameraRotatedPhoto() throws {
        let detector = try loadedDetector()
        let url = try XCTUnwrap(Bundle.main.url(forResource: "wallR", withExtension: "jpg"))
        let image = try XCTUnwrap(UIImage(data: try Data(contentsOf: url)))
        XCTAssertEqual(image.imageOrientation, .right, "EXIF tag must be picked up as .right")
        let cg = try XCTUnwrap(image.normalizedCGImage())
        XCTAssertEqual(cg.width, 1200, "normalization must restore upright dimensions")
        XCTAssertEqual(cg.height, 1600)
        let holds = detector.detectSync(image: image)
        XCTAssertGreaterThan(
            holds.count, 20,
            "camera-style rotated photo must detect as many holds as the upright one"
        )
    }

    func testMaskAlignmentSpansWholeFrame() throws {
        // Regression: decodeMasks used a width-only letterbox scale, so for
        // portrait photos mask coordinates drifted (top of the frame never
        // received any mask pixels). Ground truth for wall1: 2 holds touch
        // the top quarter, 27 the bottom quarter.
        let detector = try loadedDetector()
        let url = try XCTUnwrap(Bundle.main.url(forResource: "wall1", withExtension: "jpg"))
        let image = try XCTUnwrap(UIImage(data: try Data(contentsOf: url)))
        let holds = detector.detectSync(image: image)
        XCTAssertGreaterThan(holds.count, 20)
        let w = holds[0].bw, hgt = holds[0].bh
        var top = 0, bottom = 0
        for hold in holds {
            for (i, v) in hold.mask.enumerated() where v != 0 {
                let y = i / w
                if y < hgt / 4 { top += 1 }
                if y > hgt * 3 / 4 { bottom += 1 }
            }
        }
        XCTAssertGreaterThan(top, 100, "masks must reach the top quarter of a portrait frame")
        XCTAssertGreaterThan(bottom, 1000, "masks must reach the bottom quarter of a portrait frame")
    }

    private func loadedDetector() throws -> HoldDetector {
        guard let detector = HoldDetector.load() else {
            throw XCTSkip("model not in bundle")
        }
        return detector
    }
}
