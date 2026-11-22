import Foundation
import Accelerate

/// sRGB -> CIELAB with OpenCV 8-bit scaling (L*255/100, a+128, b+128).
/// Keeps delta-E values on the same scale as the Python reference core
/// (DEFAULT_MAX_DE = 30), so fixtures transfer 1:1.
enum LAB {
    /// Lightness is discounted in route selection: it shifts with shading,
    /// while chroma identifies the route (mirrors core.pipeline.L_WEIGHT).
    static let lWeight = 0.5
    // sRGB -> XYZ (D65)
    // X = 0.4124 R + 0.3576 G + 0.1805 B
    // Y = 0.2126 R + 0.7152 G + 0.0722 B
    // Z = 0.0193 R + 0.1192 G + 0.9505 B
    private static let delta = 6.0 / 29.0
    private static let deltaSq = (6.0 / 29.0) * (6.0 / 29.0)

    static func convert(_ r: Double, _ g: Double, _ b: Double) -> (l: Double, a: Double, b: Double) {
        func linear(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let rl = linear(r), gl = linear(g), bl = linear(b)
        let x = 0.4124 * rl + 0.3576 * gl + 0.1805 * bl
        let y = 0.2126 * rl + 0.7152 * gl + 0.0722 * bl
        let z = 0.0193 * rl + 0.1192 * gl + 0.9505 * bl
        // normalize by D65 white
        let xn = x / 0.95047, yn = y / 1.00000, zn = z / 1.08883
        func f(_ t: Double) -> Double {
            t > delta * delta * delta ? cbrt(t) : t / (3 * deltaSq) + 4.0 / 29.0
        }
        let fx = f(xn), fy = f(yn), fz = f(zn)
        let L = 116 * fy - 16
        let A = 500 * (fx - fy)
        let B = 200 * (fy - fz)
        // OpenCV 8-bit scaling
        return (L * 255.0 / 100.0, A + 128.0, B + 128.0)
    }

    /// Median LAB (OpenCV-scaled) and median sRGB over masked pixels of an
    /// RGBA bitmap — mirrors core.pipeline.hold_from_polygon: median resists
    /// specular highlights and bolt holes far better than the mean.
    static func medianColors(bitmap: [UInt8], width: Int, height: Int, pixels: [UInt8])
        -> (lab: (l: Double, a: Double, b: Double), rgb: (r: Double, g: Double, b: Double)) {
        var ls = [Double](), as_ = [Double](), bs = [Double]()
        var rs = [Double](), gs = [Double](), bls = [Double]()
        ls.reserveCapacity(512); as_.reserveCapacity(512); bs.reserveCapacity(512)
        bitmap.withUnsafeBufferPointer { buf in
            pixels.withUnsafeBufferPointer { px in
                for i in 0..<(width * height) where buf[i] != 0 {
                    let o = i * 4
                    let r = Double(px[o]), g = Double(px[o + 1]), b = Double(px[o + 2])
                    rs.append(r); gs.append(g); bls.append(b)
                    let lab = convert(r / 255.0, g / 255.0, b / 255.0)
                    ls.append(lab.l); as_.append(lab.a); bs.append(lab.b)
                }
            }
        }
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return 0 }
            let mid = sorted.count / 2
            return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
        }
        return (
            (median(ls), median(as_), median(bs)),
            (median(rs), median(gs), median(bls))
        )
    }
}
