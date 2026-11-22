import CoreML
import Vision
import UIKit
import os.log

private let log = Logger(subsystem: "ru.boulderbook.app", category: "detector")

struct DetectedHold {
    let id: Int
    let mask: [UInt8]      // working-scale bitmap, bw*bh bytes 0/1
    let bw: Int            // working bitmap width
    let bh: Int            // working bitmap height
    let box: (x0: Int, y0: Int, x1: Int, y1: Int)  // original-photo pixels
    let lab: (l: Double, a: Double, b: Double)
    let rgb: (r: Double, g: Double, b: Double)
    let conf: Double
    var selected: Bool
}

/// Full on-device decode of a YOLO11n-seg CoreML export.
/// Layout assumptions verified against the Python export (see training/):
///   input:  image 640x640, letterboxed, RGB, /255
///   output0: [1, 4+1+32, N] boxes(xywh, pixels of 640 canvas) + cls score(sigmoid applied) + mask coeffs
///   output1: [1, 32, 160, 160] mask prototypes
final class HoldDetector {
    /// Last detection's vital numbers, shown in-app when something goes wrong.
    static var lastDebugInfo = ""
    /// Model version from the CoreML package metadata (set at export time).
    static private(set) var modelVersion = "unknown"

    private let model: MLModel
    private let inputSize = 640
    private let protoSize = 160
    private let confThreshold: Double = 0.25
    private let iouThreshold: Double = 0.6
    /// Max side of the stored working bitmap (masks + color sampling).
    private let workSide = 512

    private init(model: MLModel) {
        self.model = model
    }

    static func load(bundleName: String = "best") -> HoldDetector? {
        guard let url = Bundle.main.url(forResource: bundleName, withExtension: "mlmodelc") else {
            log.error("model \(bundleName).mlmodelc not found in bundle")
            return nil
        }
        // ANE excluded: on-device Neural Engine mishandles this graph
        // (zero detections + staging latency); CPU+GPU is reliable.
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndGPU
        guard let model = try? MLModel(contentsOf: url, configuration: config) else {
            log.error("model failed to load from \(url.path)")
            return nil
        }
        let meta = model.modelDescription.metadata
        // user-defined metadata lives under the machineLearningUserDefined key
        let key = MLModelMetadataKey(rawValue: "com.apple.coreml.machineLearningUserDefined")
        let userDefined = meta[key] as? [String: String]
        modelVersion = userDefined?["version"] ?? "untagged"
        log.info("model loaded: \(url.lastPathComponent) version=\(modelVersion)")
        return HoldDetector(model: model)
    }

    // MARK: - Public

    func detect(image: UIImage, completion: @escaping ([DetectedHold]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let holds = self.detectSync(image: image)
            DispatchQueue.main.async { completion(holds) }
        }
    }

    func detectSync(image: UIImage) -> [DetectedHold] {
        Self.lastDebugInfo = "img=\(image.size.width.rounded())x\(image.size.height.rounded()) orient=\(image.imageOrientation.rawValue)"
        guard let cg = image.normalizedCGImage() else {
            log.error("normalizedCGImage failed")
            Self.lastDebugInfo += " normalize=FAIL"
            return []
        }
        let originalSize = (w: cg.width, h: cg.height)
        log.info("detect: image \(originalSize.w)x\(originalSize.h), orientation \(image.imageOrientation.rawValue)")
        // working-scale RGBA pixels: color source + mask storage
        let (work, workW, workH) = rgbaPixels(cg, maxSide: workSide)
        // letterboxed 640 input + the exact transform used when drawing
        guard let (pb, lbScale, lbPadX, lbPadY) = letterboxedPixelBuffer(cg) else {
            log.error("letterbox pixel buffer failed")
            Self.lastDebugInfo += " letterbox=FAIL"
            return []
        }

        guard let input = makeInput(pb),
              let out = try? model.prediction(from: input) else {
            log.error("model prediction failed")
            Self.lastDebugInfo += " predict=FAIL"
            return []
        }
        let arrays = out.featureNames.compactMap { out.featureValue(for: $0)?.multiArrayValue }
        guard arrays.count >= 2 else {
            log.error("expected 2 multiarray outputs, got \(arrays.count)")
            Self.lastDebugInfo += " outputs=\(arrays.count)"
            return []
        }
        // protos = the rank-4 output, predictions = the rank-3 output
        guard let pred = arrays.first(where: { $0.shape.count == 3 }),
              let protos = arrays.first(where: { $0.shape.count == 4 }) else {
            Self.lastDebugInfo += " shapes=MISMATCH"
            return []
        }

        let candidates = decodePredictions(pred)
        let kept = nms(candidates)
        log.info("image \(originalSize.w)x\(originalSize.h): candidates=\(candidates.count) afterNMS=\(kept.count)")
        Self.lastDebugInfo += " cand=\(candidates.count) nms=\(kept.count)"
        let masks = decodeMasks(
            kept, protos: protos, original: originalSize, work: (workW, workH),
            letterbox: (scale: lbScale, padX: lbPadX, padY: lbPadY)
        )

        var holds: [DetectedHold] = []
        for (i, cand) in kept.enumerated() {
            guard i < masks.count else { break }
            let (mask, box) = masks[i]
            let area = mask.reduce(0) { $0 + Int($1) }
            guard area >= 30 else { continue }
            let colors = LAB.medianColors(bitmap: mask, width: workW, height: workH, pixels: work)
            let scaleDown = Double(workW) / Double(originalSize.w)
            holds.append(
                DetectedHold(
                    id: holds.count,
                    mask: mask,
                    bw: workW,
                    bh: workH,
                    box: (
                        Int(Double(box.x0) / scaleDown),
                        Int(Double(box.y0) / scaleDown),
                        Int(Double(box.x1) / scaleDown),
                        Int(Double(box.y1) / scaleDown)
                    ),
                    lab: colors.lab,
                    rgb: colors.rgb,
                    conf: cand.score,
                    selected: false
                )
            )
        }
        log.info("detect done: \(holds.count) holds")
        Self.lastDebugInfo += " holds=\(holds.count)"
        return holds
    }

    // MARK: - Preprocess

    private func makeInput(_ pb: CVPixelBuffer) -> MLDictionaryFeatureProvider? {
        guard let name = model.modelDescription.inputDescriptionsByName.keys.first else { return nil }
        return try? MLDictionaryFeatureProvider(dictionary: [name: pb])
    }

    private func letterboxedPixelBuffer(_ cg: CGImage) -> (CVPixelBuffer, scale: Double, padX: Double, padY: Double)? {
        let s = inputSize
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, s, s, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary, &pb
        )
        guard let buffer = pb else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: s, height: s, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        let gray = 114.0 / 255.0
        context.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: s, height: s))
        let scale = Double(min(CGFloat(s) / CGFloat(cg.width), CGFloat(s) / CGFloat(cg.height)))
        let w = CGFloat(cg.width) * CGFloat(scale), h = CGFloat(cg.height) * CGFloat(scale)
        let rect = CGRect(x: (CGFloat(s) - w) / 2, y: (CGFloat(s) - h) / 2, width: w, height: h)
        context.draw(cg, in: rect)
        return (buffer, scale, Double((CGFloat(s) - w) / 2), Double((CGFloat(s) - h) / 2))
    }

    private func rgbaPixels(_ cg: CGImage, maxSide: Int) -> ([UInt8], Int, Int) {
        let scale = min(1.0, Double(maxSide) / Double(max(cg.width, cg.height)))
        let w = max(1, Int(Double(cg.width) * scale))
        let h = max(1, Int(Double(cg.height) * scale))
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(
            data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        ctx?.interpolationQuality = .medium
        ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (pixels, w, h)
    }

    // MARK: - Decode

    private struct Candidate {
        let cx: Double, cy: Double, w: Double, h: Double
        let score: Double
        let coeffs: [Double]
    }

    private func decodePredictions(_ pred: MLMultiArray) -> [Candidate] {
        // [1, C, N] -> stride access
        let cCount = pred.shape[1].intValue
        let n = pred.shape[2].intValue
        let ps = pred.strides[2].intValue
        let clsOffset = 4
        var result: [Candidate] = []
        result.reserveCapacity(256)
        for i in 0..<n {
            let base = i * ps
            let score = Double(pred[clsOffset * pred.strides[1].intValue + base])
            guard score > confThreshold else { continue }
            let cx = Double(pred[0 * pred.strides[1].intValue + base])
            let cy = Double(pred[1 * pred.strides[1].intValue + base])
            let w = Double(pred[2 * pred.strides[1].intValue + base])
            let h = Double(pred[3 * pred.strides[1].intValue + base])
            var coeffs = [Double](repeating: 0, count: max(0, cCount - 5))
            for c in 0..<coeffs.count {
                coeffs[c] = Double(pred[(5 + c) * pred.strides[1].intValue + base])
            }
            result.append(Candidate(cx: cx, cy: cy, w: w, h: h, score: score, coeffs: coeffs))
        }
        return result
    }

    private func nms(_ candidates: [Candidate]) -> [Candidate] {
        let sorted = candidates.sorted { $0.score > $1.score }
        var kept: [Candidate] = []
        for c in sorted {
            let ok = kept.allSatisfy { existing in iou(c, existing) < iouThreshold }
            if ok { kept.append(c) }
            if kept.count >= 300 { break }
        }
        return kept
    }

    private func iou(_ a: Candidate, _ b: Candidate) -> Double {
        let ax0 = a.cx - a.w / 2, ay0 = a.cy - a.h / 2, ax1 = a.cx + a.w / 2, ay1 = a.cy + a.h / 2
        let bx0 = b.cx - b.w / 2, by0 = b.cy - b.h / 2, bx1 = b.cx + b.w / 2, by1 = b.cy + b.h / 2
        let ix = min(ax1, bx1) - max(ax0, bx0), iy = min(ay1, by1) - max(ay0, by0)
        guard ix > 0, iy > 0 else { return 0 }
        let inter = ix * iy
        return inter / (a.w * a.h + b.w * b.h - inter)
    }

    private func decodeMasks(
        _ cands: [Candidate], protos: MLMultiArray, original: (w: Int, h: Int), work: (w: Int, h: Int),
        letterbox: (scale: Double, padX: Double, padY: Double)
    ) -> [([UInt8], (x0: Int, y0: Int, x1: Int, y1: Int))] {
        let p = protoSize
        let count = cands.count
        guard count > 0 else { return [] }
        let cCount = protos.shape[1].intValue
        // proto strides: [1, C, H, W]
        let sC = protos.strides[1].intValue, sH = protos.strides[2].intValue
        var masks32 = [Float](repeating: 0, count: count * p * p)
        for c in 0..<count {
            let coeffs = cands[c].coeffs
            for k in 0..<min(cCount, coeffs.count) {
                let weight = Float(coeffs[k])
                if abs(weight) < 1e-4 { continue }
                let protoBase = k * sC
                let maskBase = c * p * p
                for y in 0..<p {
                    let rowOff = protoBase + y * sH
                    for x in 0..<p {
                        masks32[maskBase + y * p + x] += weight * Float(protos[rowOff + x])
                    }
                }
            }
        }
        // sigmoid
        for i in 0..<(count * p * p) {
            masks32[i] = 1.0 / (1.0 + expf(-masks32[i]))
        }
        // map each 160-canvas mask back to the working bitmap using the exact
        // letterbox transform (min-scale) — must match letterboxedPixelBuffer
        let scale = letterbox.scale
        let padX = letterbox.padX
        let padY = letterbox.padY
        let toWorkX = Double(work.w) / Double(original.w)
        let toWorkY = Double(work.h) / Double(original.h)
        var result: [([UInt8], (Int, Int, Int, Int))] = []
        result.reserveCapacity(count)
        for c in 0..<count {
            let cand = cands[c]
            let bx0 = cand.cx - cand.w / 2, by0 = cand.cy - cand.h / 2
            let bx1 = cand.cx + cand.w / 2, by1 = cand.cy + cand.h / 2
            var bitmap = [UInt8](repeating: 0, count: work.w * work.h)
            var minX = Int.max, minY = Int.max, maxX = 0, maxY = 0
            for wy in 0..<work.h {
                // working y -> letterboxed canvas y -> fractional proto row
                let cyCanvas = Double(wy) / toWorkY * scale + padY
                let pyf = cyCanvas / Double(inputSize) * Double(p)
                guard pyf >= 0, pyf < Double(p) - 1 else { continue }
                let py0 = Int(pyf), fy = Float(pyf - Double(py0))
                let row0 = c * p * p + py0 * p
                let row1 = row0 + p
                for wx in 0..<work.w {
                    let cxCanvas = Double(wx) / toWorkX * scale + padX
                    let pxf = cxCanvas / Double(inputSize) * Double(p)
                    guard pxf >= 0, pxf < Double(p) - 1 else { continue }
                    let px0 = Int(pxf), fx = Float(pxf - Double(px0))
                    // bilinear sample of the proto grid: smooth mask edges
                    let v = masks32[row0 + px0] * (1 - fy) * (1 - fx)
                        + masks32[row0 + px0 + 1] * (1 - fy) * fx
                        + masks32[row1 + px0] * fy * (1 - fx)
                        + masks32[row1 + px0 + 1] * fy * fx
                    // crop by the candidate box on the canvas
                    let inBox = cxCanvas >= bx0 && cxCanvas <= bx1 && cyCanvas >= by0 && cyCanvas <= by1
                    if inBox && v > 0.5 {
                        bitmap[wy * work.w + wx] = 1
                        if wx < minX { minX = wx }
                        if wx > maxX { maxX = wx }
                        if wy < minY { minY = wy }
                        if wy > maxY { maxY = wy }
                    }
                }
            }
            if minX == Int.max { minX = 0; minY = 0; maxX = 0; maxY = 0 }
            // box in original-photo pixels
            let ox0 = (bx0 - padX) / scale, oy0 = (by0 - padY) / scale
            let ox1 = (bx1 - padX) / scale, oy1 = (by1 - padY) / scale
            result.append(
                (bitmap, (Int(ox0), Int(oy0), Int(ox1), Int(oy1)))
            )
        }
        return result
    }
}

extension UIImage {
    /// CGImage with EXIF orientation baked in (picker photos come rotated).
    /// CIImage.oriented applies the transform exactly as EXIF dictates.
    func normalizedCGImage() -> CGImage? {
        guard let cg = cgImage else { return nil }
        if imageOrientation == .up { return cg }
        let exif: Int32
        switch imageOrientation {
        case .up: return cg
        case .upMirrored: exif = 2
        case .down: exif = 3
        case .downMirrored: exif = 4
        case .leftMirrored: exif = 5
        case .right: exif = 6
        case .rightMirrored: exif = 7
        case .left: exif = 8
        @unknown default: return cg
        }
        let ci = CIImage(cgImage: cg).oriented(forExifOrientation: exif)
        let context = CIContext()
        return context.createCGImage(ci, from: ci.extent)
    }
}
