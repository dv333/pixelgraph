import CoreGraphics
import Foundation
import Vision

/// What a photo looks like as a picture, measured on the small preview every
/// photo has: how sharp its sharpest part is, how noisy, whether the blur runs
/// one way (motion), how it's exposed, and a tiny hash for exact copies.
/// Cached per photo, so a library is only measured once.
struct Quality: Codable, Sendable, Equatable {
    /// Bump when any measure changes so cached values are redone.
    static let version = 1

    /// 64-bit difference hash: copies and re-saves are a few bits apart.
    var hash: UInt64
    /// Laplacian variance of the sharpest tenth of the frame (8×8 tiles), so a
    /// sharp subject against a soft background still counts as sharp.
    var focus: Float
    /// Estimated sensor noise (standard deviation, 0 … 1). Noise looks like
    /// detail to the Laplacian, so focus is judged net of it.
    var noise: Float
    /// How much the edges run in one direction, 0 … 1. High with low focus
    /// reads as motion blur rather than missed focus.
    var motion: Float
    /// Mean brightness and the share of crushed shadows and blown highlights.
    var luma: Float
    var dark: Float
    var bright: Float
    /// Vision's lens smudge confidence, 0 … 1; -1 when not measured.
    var smudge: Float

    /// Focus with the noise's share taken out: the Laplacian of pure noise
    /// has a variance of about 20σ².
    var netFocus: Float { max(0, focus - 20 * noise * noise) }

    /// 0 … 1: 1 when nothing is crushed or blown.
    var exposure: Float { max(0, 1 - 2 * max(0, dark - 0.25) - 3 * max(0, bright - 0.08)) }

    static func distance(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }

    static func measure(_ image: CGImage) async -> Quality {
        let gray = Gray(image, maxSide: 512)
        var quality = Quality(hash: hash(image), focus: 0, noise: 0, motion: 0, luma: 0, dark: 0, bright: 0, smudge: -1)
        if let gray {
            quality.focus = gray.peakFocus()
            quality.noise = gray.noise()
            quality.motion = gray.directionality()
            let exposure = gray.exposure()
            quality.luma = exposure.luma
            quality.dark = exposure.dark
            quality.bright = exposure.bright
        }
        if let smudge = try? await DetectLensSmudgeRequest().perform(on: image) {
            quality.smudge = smudge.confidence
        }
        return quality
    }

    /// dHash: each bit says whether a pixel is brighter than its right-hand
    /// neighbour, on a 9×8 copy.
    static func hash(_ image: CGImage) -> UInt64 {
        guard let small = Gray(image, width: 9, height: 8) else { return 0 }
        var bits: UInt64 = 0
        for y in 0..<8 {
            for x in 0..<8 where small.pixels[y * 9 + x] > small.pixels[y * 9 + x + 1] {
                bits |= 1 << UInt64(y * 8 + x)
            }
        }
        return bits
    }
}

/// One face in a grouped photo, measured at full detail. Positions are the
/// face's centre and size as fractions of the frame, top-left origin.
struct FaceDetail: Codable, Sendable, Equatable {
    var x: Float
    var y: Float
    var width: Float
    var height: Float
    /// Least-open eye: height ÷ width, about 0.25–0.35 open, under 0.12 closed. -1 unknown.
    var eyes: Float
    /// Head turn left/right and up/down, in degrees.
    var yaw: Float
    var pitch: Float
    /// Laplacian variance inside the face.
    var sharpness: Float
}

/// An 8-bit grayscale copy of an image, top row first.
struct Gray {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    init?(_ image: CGImage, maxSide: CGFloat) {
        let scale = min(1, maxSide / CGFloat(max(image.width, image.height)))
        self.init(image, width: max(3, Int(CGFloat(image.width) * scale)), height: max(3, Int(CGFloat(image.height) * scale)))
    }

    init?(_ image: CGImage, width: Int, height: Int) {
        self.width = width
        self.height = height
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.pixels = pixels
    }

    private func at(_ x: Int, _ y: Int) -> Float { Float(pixels[y * width + x]) / 255 }

    private func laplacian(_ x: Int, _ y: Int) -> Float {
        at(x - 1, y) + at(x + 1, y) + at(x, y - 1) + at(x, y + 1) - 4 * at(x, y)
    }

    /// Variance of the Laplacian over a region (whole frame by default).
    func sharpness(in rect: (x: Int, y: Int, width: Int, height: Int)? = nil) -> Float {
        let r = rect ?? (0, 0, width, height)
        let x0 = max(1, r.x), y0 = max(1, r.y)
        let x1 = min(width - 1, r.x + r.width), y1 = min(height - 1, r.y + r.height)
        guard x1 > x0, y1 > y0 else { return 0 }
        var sum: Float = 0, squares: Float = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let v = laplacian(x, y)
                sum += v
                squares += v * v
            }
        }
        let n = Float((x1 - x0) * (y1 - y0))
        let mean = sum / n
        return squares / n - mean * mean
    }

    /// Sharpness of the sharpest tenth of an 8×8 grid of tiles.
    func peakFocus() -> Float {
        let tw = max(3, width / 8), th = max(3, height / 8)
        var tiles: [Float] = []
        for ty in stride(from: 0, to: height - th / 2, by: th) {
            for tx in stride(from: 0, to: width - tw / 2, by: tw) {
                tiles.append(sharpness(in: (tx, ty, tw, th)))
            }
        }
        guard !tiles.isEmpty else { return 0 }
        tiles.sort()
        return tiles[Int(Float(tiles.count - 1) * 0.9)]
    }

    /// Immerkær's fast noise estimate: the mean absolute response to a mask
    /// that cancels edges and smooth gradients but not noise.
    func noise() -> Float {
        guard width > 2, height > 2 else { return 0 }
        var total: Float = 0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let corners = at(x - 1, y - 1) + at(x + 1, y - 1) + at(x - 1, y + 1) + at(x + 1, y + 1)
                let sides = at(x, y - 1) + at(x - 1, y) + at(x + 1, y) + at(x, y + 1)
                total += abs(corners - 2 * sides + 4 * at(x, y))
            }
        }
        return total * (Float.pi / 2).squareRoot() / Float(6 * (width - 2) * (height - 2))
    }

    /// Coherence of the gradient structure tensor: 0 when edges run every
    /// way, 1 when they all run one way, as when the camera moved.
    func directionality() -> Float {
        guard width > 2, height > 2 else { return 0 }
        var xx: Float = 0, yy: Float = 0, xy: Float = 0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let gx = at(x + 1, y) - at(x - 1, y)
                let gy = at(x, y + 1) - at(x, y - 1)
                xx += gx * gx
                yy += gy * gy
                xy += gx * gy
            }
        }
        let trace = xx + yy
        guard trace > 0 else { return 0 }
        return ((xx - yy) * (xx - yy) + 4 * xy * xy).squareRoot() / trace
    }

    /// Mean brightness, and the shares of pixels near black and near white.
    func exposure() -> (luma: Float, dark: Float, bright: Float) {
        var sum = 0, dark = 0, bright = 0
        for p in pixels {
            sum += Int(p)
            if p <= 12 { dark += 1 }
            if p >= 250 { bright += 1 }
        }
        let n = Float(pixels.count)
        return (Float(sum) / n / 255, Float(dark) / n, Float(bright) / n)
    }
}
