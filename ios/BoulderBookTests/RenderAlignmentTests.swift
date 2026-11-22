import XCTest
@testable import BoulderBook

/// Regression: the highlight mask is stored at the detector's working scale
/// (512 max side) but CoreImage composites in one shared coordinate space —
/// without scaling the mask up to the photo extent, the highlight rendered
/// shrunk into the bottom-left corner. Uses a portrait photo to mirror the
/// real-world failure case.
final class RenderAlignmentTests: XCTestCase {

    func testOutlineCoversSelectedHoldAtFullPhotoExtent() throws {
        let W = 415, H = 739          // portrait, like a real photo
        let bw = 287, bh = 512        // working bitmap (512 max side)
        let red = (r: 200, g: 40, b: 40)
        let blue = (r: 50, g: 90, b: 220)
        let bg = (r: 120, g: 120, b: 120)

        // photo pixels at bitmap scale
        var pixels = [UInt8](repeating: 0, count: bw * bh * 4)
        func paint(circleAt cx: Int, cy: Int, r: Int, color: (r: Int, g: Int, b: Int)) {
            for y in (cy - r)...(cy + r) where y >= 0 && y < bh {
                for x in (cx - r)...(cx + r) where x >= 0 && x < bw {
                    if (x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r {
                        pixels[(y * bw + x) * 4] = UInt8(color.r)
                        pixels[(y * bw + x) * 4 + 1] = UInt8(color.g)
                        pixels[(y * bw + x) * 4 + 2] = UInt8(color.b)
                        pixels[(y * bw + x) * 4 + 3] = 255
                    }
                }
            }
        }
        for i in 0..<(bw * bh) {
            pixels[i * 4] = UInt8(bg.r)
            pixels[i * 4 + 1] = UInt8(bg.g)
            pixels[i * 4 + 2] = UInt8(bg.b)
            pixels[i * 4 + 3] = 255
        }
        // red hold in the lower-right quadrant, blue hold top-left (unselected)
        let redAt = (cx: 208, cy: 416, r: 40)     // ~ (300, 600) in photo coords
        paint(circleAt: redAt.cx, cy: redAt.cy, r: redAt.r, color: red)
        paint(circleAt: 68, cy: 104, r: 30, color: blue)

        let image = imageFrom(pixels: pixels, w: bw, h: bh)
            .resized(toWidth: CGFloat(W), height: CGFloat(H))  // mimic original photo

        func hold(cx: Int, cy: Int, r: Int, id: Int, color: (r: Int, g: Int, b: Int)) -> DetectedHold {
            var mask = [UInt8](repeating: 0, count: bw * bh)
            for y in (cy - r)...(cy + r) where y >= 0 && y < bh {
                for x in (cx - r)...(cx + r) where x >= 0 && x < bw {
                    if (x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r {
                        mask[y * bw + x] = 1
                    }
                }
            }
            let lab = LAB.convert(Double(color.r) / 255, Double(color.g) / 255, Double(color.b) / 255)
            return DetectedHold(
                id: id, mask: mask, bw: bw, bh: bh, box: (0, 0, 0, 0),
                lab: lab, rgb: (Double(color.r), Double(color.g), Double(color.b)),
                conf: 1, selected: false
            )
        }
        let session = RouteSession(
            image: image,
            holds: [
                hold(cx: redAt.cx, cy: redAt.cy, r: redAt.r, id: 0, color: red),
                hold(cx: 68, cy: 104, r: 30, id: 1, color: blue),
            ],
            bitmapSize: (bw, bh)
        )
        XCTAssertTrue(session.selectRoute(x: redAt.cx, y: redAt.cy), "tap must hit the red hold")

        let rendered = session.renderHighlight()
        XCTAssertEqual(rendered.size.width, CGFloat(W), accuracy: 2)
        XCTAssertEqual(rendered.size.height, CGFloat(H), accuracy: 2)
        let rgba = try XCTUnwrap(rendered.rgbaPixels)

        func sample(_ px: Int, _ py: Int) -> (r: Int, g: Int, b: Int) {
            let o = (py * W + px) * 4
            return (Int(rgba[o]), Int(rgba[o + 1]), Int(rgba[o + 2]))
        }

        // photo coords of the red hold center: bitmap (208, 416) -> (300, 600)
        let atHold = sample(300, 600)
        XCTAssertGreaterThan(
            atHold.r, 150,
            "selected hold area must keep its bright photo color at the true "
                + "position (got \(atHold) — if wrong, the outline is misplaced)"
        )
        // green line sits just OUTSIDE the hold boundary (photo radius ~58):
        // scan a few rows above the top edge, at least one must be green
        var edgeGreen = false
        for dy in 536...545 {
            let p = sample(300, dy)
            if p.g > 110 && p.g > p.r + 30 { edgeGreen = true }
        }
        XCTAssertTrue(edgeGreen, "opaque green outline must trace the hold boundary")

        let atBackground = sample(350, 100)
        // outline style leaves the photo untouched: gray bg must stay ~120
        XCTAssertGreaterThanOrEqual(atBackground.r, 100, "photo must not be dimmed (got \(atBackground))")
        XCTAssertLessThanOrEqual(atBackground.r, 135, "background must stay untouched (got \(atBackground))")
    }

    private func imageFrom(pixels: [UInt8], w: Int, h: Int) -> UIImage {
        var data = pixels
        let ctx = CGContext(
            data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return UIImage(cgImage: ctx.makeImage()!)
    }
}

extension UIImage {
    func resized(toWidth width: CGFloat, height: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
            .image { _ in draw(in: CGRect(x: 0, y: 0, width: width, height: height)) }
    }

    var rgbaPixels: [UInt8]? {
        guard let cg = cgImage else { return nil }
        var data = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let ok = data.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(
                data: ptr.baseAddress, width: cg.width, height: cg.height,
                bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            return true
        }
        return ok ? data : nil
    }
}
