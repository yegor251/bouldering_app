import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Swift port of core/pipeline.py (the reference implementation).
/// Same semantics: reference hold under the tap (smallest area on overlap),
/// delta-E color selection in OpenCV-scaled LAB, manual toggle.
final class RouteSession {
    let image: UIImage
    let bitmapWidth: Int
    let bitmapHeight: Int
    private(set) var holds: [DetectedHold]
    private(set) var referenceId: Int?
    var maxDE: Double = 30.0

    init(image: UIImage, holds: [DetectedHold], bitmapSize: (Int, Int)) {
        self.image = image
        self.holds = holds
        self.bitmapWidth = bitmapSize.0
        self.bitmapHeight = bitmapSize.1
    }

    // MARK: - Selection

    func hold(atX x: Int, y: Int) -> Int? {
        // forgiving radius so near-miss taps still land on a hold
        let radius = max(2, bitmapWidth / 110)
        var best: (id: Int, area: Int)?
        for dy in -radius...radius {
            let py = y + dy
            guard py >= 0, py < bitmapHeight else { continue }
            for dx in -radius...radius {
                let px = x + dx
                guard px >= 0, px < bitmapWidth else { continue }
                let idx = py * bitmapWidth + px
                for h in holds where h.mask.indices.contains(idx) && h.mask[idx] != 0 {
                    let area = h.mask.reduce(0) { $0 + Int($1) }
                    if best == nil || area < best!.area { best = (h.id, area) }
                }
            }
        }
        return best?.id
    }

    @discardableResult
    func selectRoute(x: Int, y: Int) -> Bool {
        guard let id = hold(atX: x, y: y) else { return false }
        referenceId = id
        autoSelect()
        return true
    }

    func autoSelect() {
        guard let ref = holds.first(where: { $0.id == referenceId }) else {
            holds = holds.map { var h = $0; h.selected = false; return h }
            return
        }
        holds = holds.map { hold in
            var h = hold
            let d = distance(h.lab, ref.lab)
            h.selected = d <= maxDE
            return h
        }
    }

    @discardableResult
    func toggle(_ id: Int) -> Bool {
        guard let i = holds.firstIndex(where: { $0.id == id }) else { return false }
        holds[i].selected.toggle()
        return true
    }

    func clearSelection() {
        for i in holds.indices { holds[i].selected = false }
        referenceId = nil
    }

    /// Delta-E with lightness discounted (mirrors core.pipeline.weighted_de):
    /// shadows must not split a route, chroma decides.
    private func distance(_ a: (l: Double, a: Double, b: Double), _ b: (l: Double, a: Double, b: Double)) -> Double {
        let dl = (a.l - b.l) * LAB.lWeight
        let da = a.a - b.a
        let db = a.b - b.b
        return (dl * dl + da * da + db * db).squareRoot()
    }

    // MARK: - Render

    /// Editor look: photo untouched, selected route holds traced with an
    /// opaque vivid-green line sitting just OUTSIDE the hold boundary
    /// (dilated mask minus mask via difference blend, which keeps alpha
    /// intact — plain subtract blends zero out premultiplied alpha).
    func renderHighlight() -> UIImage {
        guard let cg = image.cgImage ?? image.normalizedCGImage() else { return image }
        return Self.composeHighlight(
            baseImage: cg, selectedBytes: selectionMaskBytes(),
            bitmapWidth: bitmapWidth, bitmapHeight: bitmapHeight
        )
    }

    /// Async variant: snapshots the mask on the calling (main) thread, then
    /// composites off-main — keeps the editor responsive on every tap.
    func renderHighlightAsync(completion: @escaping (UIImage) -> Void) {
        guard let cg = image.cgImage ?? image.normalizedCGImage() else {
            completion(image)
            return
        }
        let bytes = selectionMaskBytes()
        let w = bitmapWidth, h = bitmapHeight
        DispatchQueue.global(qos: .userInitiated).async {
            let img = Self.composeHighlight(
                baseImage: cg, selectedBytes: bytes, bitmapWidth: w, bitmapHeight: h
            )
            DispatchQueue.main.async { completion(img) }
        }
    }

    /// Snapshot of the selected-hold union at bitmap scale. Cheap enough for
    /// the main thread; all CI work runs off it on a background queue.
    func selectionMaskBytes() -> [UInt8] {
        var union = [UInt8](repeating: 0, count: bitmapWidth * bitmapHeight)
        for h in holds where h.selected {
            for (i, v) in h.mask.enumerated() where v != 0 && i < union.count {
                union[i] = 255
            }
        }
        return union
    }

    /// Pure and thread-safe: no shared mutable state, all inputs passed in.
    static func composeHighlight(
        baseImage: CGImage, selectedBytes: [UInt8], bitmapWidth: Int, bitmapHeight: Int
    ) -> UIImage {
        let base = CIImage(cgImage: baseImage)
        let mask = grayCIImage(from: selectedBytes, width: bitmapWidth, height: bitmapHeight)
        // the mask lives at the working bitmap scale; CoreImage composites in
        // one shared coordinate space — scale it to the photo extent, or the
        // outline lands in the bottom-left corner shrunk by the scale factor
        let scaledMask = mask.transformed(by: CGAffineTransform(
            scaleX: base.extent.width / CGFloat(bitmapWidth),
            y: base.extent.height / CGFloat(bitmapHeight)
        ))
        let radius = max(1.5, Double(base.extent.width) / 200.0)
        let dilated = scaledMask
            .applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": radius])
        let band = dilated
            .applyingFilter("CIDifferenceBlendMode", parameters: ["inputBackgroundImage": scaledMask])
        let line = CIImage(color: CIColor(color: UIColor(Theme.outline)))
            .cropped(to: base.extent)
            .applyingFilter("CIBlendWithMask", parameters: [
                "inputMaskImage": band, "inputBackgroundImage": CIImage.empty(),
            ])
        let composed = line.composited(over: base)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let rendered = context.createCGImage(composed, from: base.extent) else {
            return UIImage(cgImage: baseImage)
        }
        return UIImage(cgImage: rendered, scale: 1, orientation: .up)
    }

    private static func grayCIImage(from bytes: [UInt8], width: Int, height: Int) -> CIImage {
        var pixels = bytes
        let ctx = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )
        guard let cg = ctx?.makeImage() else { return CIImage.empty() }
        return CIImage(cgImage: cg)
    }

    // MARK: - Persistence

    func storedHolds() -> [StoredHold] {
        holds.map { h in
            StoredHold(
                id: h.id,
                box: [h.box.x0, h.box.y0, h.box.x1, h.box.y1],
                lab: [h.lab.l, h.lab.a, h.lab.b],
                bgr: [h.rgb.b, h.rgb.g, h.rgb.r],
                conf: h.conf,
                selected: h.selected
            )
        }
    }

    var selectionCount: Int { holds.filter(\.selected).count }
}
