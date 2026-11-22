import XCTest
@testable import BoulderBook

/// Fixtures mirror core/test_pipeline.py (Python reference implementation):
/// wall colors and expected selection must match 1:1.
final class CoreParityTests: XCTestCase {

    // BGR colors from the Python fixture
    private let red = (r: 200, g: 40, b: 40)
    private let redDark = (r: 160, g: 30, b: 30)
    private let blue = (r: 50, g: 90, b: 220)
    private let bg = (r: 120, g: 120, b: 120)

    func testLABParityWithOpenCV() {
        // cv2.cvtColor on the fixture colors gives:
        // red LAB=(113,189,169), blue=(110,160,58), bg(120)=(144,128,128)
        let redLab = LAB.convert(Double(red.r) / 255, Double(red.g) / 255, Double(red.b) / 255)
        XCTAssertEqual(redLab.l, 113, accuracy: 2.0)
        XCTAssertEqual(redLab.a, 189, accuracy: 2.0)
        XCTAssertEqual(redLab.b, 169, accuracy: 2.0)

        let blueLab = LAB.convert(Double(blue.r) / 255, Double(blue.g) / 255, Double(blue.b) / 255)
        XCTAssertEqual(blueLab.l, 110, accuracy: 2.0)
        XCTAssertEqual(blueLab.a, 160, accuracy: 2.0)
        XCTAssertEqual(blueLab.b, 58, accuracy: 2.0)

        let bgLab = LAB.convert(Double(bg.r) / 255, Double(bg.g) / 255, Double(bg.b) / 255)
        // cv2 LAB for (120,120,120) gray: L=128.5 (the 144 value belongs to 135 gray)
        XCTAssertEqual(bgLab.l, 128.5, accuracy: 1.0)
        XCTAssertEqual(bgLab.a, 128, accuracy: 1.0)
        XCTAssertEqual(bgLab.b, 128, accuracy: 1.0)
    }

    func testDeltaEParity() {
        // Python: d(red, red_dark) = 26.3, d(red, blue) = 114.8
        let redLab = LAB.convert(Double(red.r) / 255, Double(red.g) / 255, Double(red.b) / 255)
        let darkLab = LAB.convert(Double(redDark.r) / 255, Double(redDark.g) / 255, Double(redDark.b) / 255)
        let blueLab = LAB.convert(Double(blue.r) / 255, Double(blue.g) / 255, Double(blue.b) / 255)
        let dDark = ((redLab.l - darkLab.l).pow2 + (redLab.a - darkLab.a).pow2 + (redLab.b - darkLab.b).pow2).squareRoot()
        let dBlue = ((redLab.l - blueLab.l).pow2 + (redLab.a - blueLab.a).pow2 + (redLab.b - blueLab.b).pow2).squareRoot()
        XCTAssertEqual(dDark, 26.3, accuracy: 1.0)
        XCTAssertEqual(dBlue, 114.8, accuracy: 1.5)
    }

    // MARK: - Synthetic wall session (mirrors Python build_session)

    private func makeSession() -> (RouteSession, UIColor, UIColor, UIColor) {
        let w = 640, h = 480
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        fill(&pixels, w: w, h: h, color: bg)

        func holdMask(cx: Int, cy: Int, r: Int) -> [UInt8] {
            var m = [UInt8](repeating: 0, count: w * h)
            for y in (cy - r)..<(cy + r) where y >= 0 && y < h {
                for x in (cx - r)..<(cx + r) where x >= 0 && x < w {
                    let dx = x - cx, dy = y - cy
                    if dx * dx + dy * dy <= r * r { m[y * w + x] = 1 }
                }
            }
            return m
        }
        func paint(_ mask: [UInt8], color: (r: Int, g: Int, b: Int)) {
            for i in 0..<(w * h) where mask[i] != 0 {
                pixels[i * 4] = UInt8(color.r)
                pixels[i * 4 + 1] = UInt8(color.g)
                pixels[i * 4 + 2] = UInt8(color.b)
                pixels[i * 4 + 3] = 255
            }
        }
        let masks = [
            holdMask(cx: 100, cy: 120, r: 40),
            holdMask(cx: 200, cy: 300, r: 35),
            holdMask(cx: 320, cy: 150, r: 38),
            holdMask(cx: 450, cy: 350, r: 42),
            holdMask(cx: 550, cy: 120, r: 30),
            holdMask(cx: 100, cy: 400, r: 25),
        ]
        let colors = [red, red, redDark, blue, blue, (r: 135, g: 135, b: 135)]
        for (m, c) in zip(masks, colors) { paint(m, color: c) }

        var holds: [DetectedHold] = []
        for (i, m) in masks.enumerated() {
            let lab = LAB.convert(Double(colors[i].r) / 255, Double(colors[i].g) / 255, Double(colors[i].b) / 255)
            holds.append(
                DetectedHold(
                    id: i, mask: m, bw: w, bh: h,
                    box: (0, 0, 0, 0),
                    lab: lab,
                    rgb: (Double(colors[i].r), Double(colors[i].g), Double(colors[i].b)),
                    conf: 1.0,
                    selected: false
                )
            )
        }
        let image = imageFrom(pixels: pixels, w: w, h: h)
        return (RouteSession(image: image, holds: holds, bitmapSize: (w, h)), UIColor.red, UIColor.red, UIColor.blue)
    }

    func testAutoSelectSameColor() {
        let (session, _, _, _) = makeSession()
        XCTAssertTrue(session.selectRoute(x: 100, y: 120))
        let selected = Set(session.holds.filter(\.selected).map(\.id))
        XCTAssertEqual(selected, [0, 1, 2], "both reds + darker red at default ΔE=30")
    }

    func testStrictThresholdDropsDarkRed() {
        let (session, _, _, _) = makeSession()
        session.maxDE = 8
        XCTAssertTrue(session.selectRoute(x: 100, y: 120))
        let selected = Set(session.holds.filter(\.selected).map(\.id))
        XCTAssertEqual(selected, [0, 1])
    }

    func testToggleAndEmptyTap() {
        let (session, _, _, _) = makeSession()
        _ = session.selectRoute(x: 100, y: 120)
        session.toggle(3)
        XCTAssertEqual(Set(session.holds.filter(\.selected).map(\.id)), [0, 1, 2, 3])
        session.toggle(3)
        XCTAssertEqual(Set(session.holds.filter(\.selected).map(\.id)), [0, 1, 2])
        XCTAssertFalse(session.selectRoute(x: 300, y: 460), "no hold on bare wall")
    }

    func testSmallestHoldWinsOverlap() {
        let (session, _, _, _) = makeSession()
        // point inside hold 5 only
        XCTAssertTrue(session.selectRoute(x: 100, y: 400))
        XCTAssertEqual(session.holds.first { $0.id == 5 }?.selected, true)
        XCTAssertEqual(session.holds.first { $0.id == 0 }?.selected, false)
    }

    func testMaskCodecRoundtrip() {
        var second = [UInt8](repeating: 0, count: 32 * 16)
        for i in stride(from: 0, to: 32 * 16, by: 2) { second[i] = 1 }
        let masks = [[UInt8](repeating: 1, count: 32 * 16), second]
        let data = MaskCodec.encode(masks, width: 32, height: 16)
        let decoded = MaskCodec.decode(data)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.width, 32)
        XCTAssertEqual(decoded?.height, 16)
        XCTAssertEqual(decoded?.masks.count, 2)
        XCTAssertEqual(decoded?.masks[0].filter { $0 == 1 }.count, 32 * 16)
        XCTAssertEqual(decoded?.masks[1].filter { $0 == 1 }.count, 16 * 16)
    }

    // MARK: - Helpers

    private func fill(_ pixels: inout [UInt8], w: Int, h: Int, color: (r: Int, g: Int, b: Int)) {
        for i in 0..<(w * h) {
            pixels[i * 4] = UInt8(color.r)
            pixels[i * 4 + 1] = UInt8(color.g)
            pixels[i * 4 + 2] = UInt8(color.b)
            pixels[i * 4 + 3] = 255
        }
    }

    private func imageFrom(pixels: [UInt8], w: Int, h: Int) -> UIImage {
        var data = pixels
        let ctx = CGContext(
            data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let cg = ctx.makeImage()!
        return UIImage(cgImage: cg)
    }
}

private extension Double {
    var pow2: Double { self * self }
}
