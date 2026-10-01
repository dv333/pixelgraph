import CoreGraphics
import Vision

/// Second opinion on a close call: lines two pictures up with Vision's image
/// registration and measures how alike they are pixel for pixel. The same
/// view revisited lines up; two different photos that only feel alike (two
/// beaches, two birthday cakes) don't.
enum Verifier {
    /// Below this, two photos taken apart in time aren't grouped.
    static let minimumSimilarity: Float = 0.5

    /// Normalized cross-correlation, -1 … 1, of 64×64 grayscale copies after
    /// shifting one onto the other.
    static func alignedSimilarity(_ a: CGImage, _ b: CGImage) -> Float {
        let side = 64
        guard let ga = Gray(a, width: side, height: side), let gb = Gray(b, width: side, height: side) else { return 0 }
        var dx = 0, dy = 0
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: b, options: [:])
        if (try? VNImageRequestHandler(cgImage: a, options: [:]).perform([request])) != nil,
           let shift = request.results?.first?.alignmentTransform {
            dx = Int((shift.tx / CGFloat(max(1, a.width)) * CGFloat(side)).rounded())
            dy = Int((shift.ty / CGFloat(max(1, a.height)) * CGFloat(side)).rounded())
        }
        // Vision's y axis points up and which image moves depends on the
        // request, so try the shift each way round and keep the best fit.
        return [(dx, dy), (-dx, -dy), (dx, -dy), (-dx, dy)].map { correlation(ga, gb, $0.0, $0.1) }.max() ?? 0
    }

    /// Correlation of `a` with `b` shifted by (dx, dy), over where they
    /// overlap; 0 when they overlap by less than half.
    static func correlation(_ a: Gray, _ b: Gray, _ dx: Int, _ dy: Int) -> Float {
        let w = a.width, h = a.height
        let xs = max(0, dx)..<min(w, w + dx), ys = max(0, dy)..<min(h, h + dy)
        guard xs.count * ys.count * 2 >= w * h else { return 0 }
        var sa: Float = 0, sb: Float = 0, saa: Float = 0, sbb: Float = 0, sab: Float = 0
        for y in ys {
            for x in xs {
                let p = Float(a.pixels[y * w + x]), q = Float(b.pixels[(y - dy) * w + (x - dx)])
                sa += p; sb += q; saa += p * p; sbb += q * q; sab += p * q
            }
        }
        let n = Float(xs.count * ys.count)
        let cov = sab / n - (sa / n) * (sb / n)
        let va = saa / n - (sa / n) * (sa / n), vb = sbb / n - (sb / n) * (sb / n)
        guard va > 0, vb > 0 else { return 0 }
        return cov / (va * vb).squareRoot()
    }
}
