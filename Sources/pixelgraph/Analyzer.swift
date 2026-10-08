import CoreGraphics
import Vision

/// What Vision measures about one photo. Stored in the index so later runs
/// can regroup without looking at the pixels again.
struct Analysis: Sendable {
    /// Image fingerprint (Vision feature print). Similar photos have nearby vectors.
    var vector: [Float]
    /// Vision's overall aesthetics score, -1 (poor) … 1 (great).
    var aesthetic: Float
    /// Vision thinks this is a receipt, document, screenshot-like utility shot.
    var isUtility: Bool
    /// Laplacian variance; higher is sharper. Only comparable within a group.
    var sharpness: Float
    var faceCount: Int
    /// Lowest face capture quality in the shot (0 … 1), so one bad face
    /// (eyes closed, blurred, turned away) pulls the photo down. -1 when no faces.
    var faceQuality: Float
    /// How open the least-open eye in the shot is: eye height ÷ width, about
    /// 0.25–0.35 open and under 0.12 closed. -1 when not measured or no faces.
    var eyesOpen: Float = -1
    /// Long side of the image this was measured on. Small means Photos only
    /// had a local preview (original in iCloud), so sharpness is rougher.
    var previewSide: Int
    /// Each face in detail (grouped photos only); kept in the index's extras.
    var faces: [FaceDetail] = []
}

enum Analyzer {
    /// Bump when the analysis changes so cached rows get recomputed.
    static let version = 3

    /// `fingerprint: false` skips the feature print, for re-scoring a photo
    /// whose fingerprint is already known. `eyes` adds face landmarks to
    /// measure eye openness (only worth it for grouped photos).
    static func analyze(_ image: CGImage, fingerprint: Bool = true, eyes: Bool = false) async throws -> Analysis {
        let handler = ImageRequestHandler(image)
        let (aesthetics, faces) = try await handler.perform(
            CalculateImageAestheticsScoresRequest(),
            DetectFaceCaptureQualityRequest()
        )
        let vector = fingerprint ? floats(from: try await handler.perform(GenerateImageFeaturePrintRequest())) : []
        let qualities = faces.compactMap { $0.captureQuality?.score }
        let details = eyes && !faces.isEmpty ? try await faceDetails(image, handler: handler) : []
        let open = details.map(\.eyes).filter { $0 >= 0 }
        return Analysis(
            vector: vector,
            aesthetic: aesthetics.overallScore,
            isUtility: aesthetics.isUtility,
            sharpness: sharpness(of: image),
            faceCount: faces.count,
            faceQuality: qualities.min() ?? -1,
            eyesOpen: open.min() ?? -1,
            previewSide: max(image.width, image.height),
            faces: details
        )
    }

    /// Where each face is, how open its eyes are, which way it's turned and
    /// how sharp it is, so photos in a group can be compared face by face.
    private static func faceDetails(_ image: CGImage, handler: ImageRequestHandler) async throws -> [FaceDetail] {
        let size = CGSize(width: image.width, height: image.height)
        let gray = Gray(image, maxSide: CGFloat(max(image.width, image.height)))
        var details: [FaceDetail] = []
        for face in try await handler.perform(DetectFaceLandmarksRequest()) {
            var lowest: Float = -1
            if let landmarks = face.landmarks {
                for eye in [landmarks.leftEye, landmarks.rightEye] {
                    let points = eye.pointsInImageCoordinates(size)
                    guard points.count >= 4 else { continue }
                    let xs = points.map(\.x), ys = points.map(\.y)
                    let width = xs.max()! - xs.min()!
                    guard width > 0 else { continue }
                    let ratio = Float((ys.max()! - ys.min()!) / width)
                    lowest = lowest < 0 ? ratio : min(lowest, ratio)
                }
            }
            // Vision's box has a bottom-left origin; flip it to top-left.
            let box = face.boundingBox.cgRect
            let top = 1 - box.origin.y - box.height
            var sharp: Float = 0
            if let gray {
                sharp = gray.sharpness(in: (Int(box.origin.x * CGFloat(gray.width)), Int(top * CGFloat(gray.height)),
                                            Int(box.width * CGFloat(gray.width)), Int(box.height * CGFloat(gray.height))))
            }
            details.append(FaceDetail(
                x: Float(box.midX), y: Float(top + box.height / 2), width: Float(box.width), height: Float(box.height),
                eyes: lowest, yaw: Float(face.yaw.converted(to: .degrees).value),
                pitch: Float(face.pitch.converted(to: .degrees).value), sharpness: sharp))
        }
        return details
    }

    private static func floats(from print: FeaturePrintObservation) -> [Float] {
        print.data.withUnsafeBytes { raw in
            switch print.elementType {
            case .double: return raw.bindMemory(to: Double.self).prefix(print.elementCount).map(Float.init)
            default: return Array(raw.bindMemory(to: Float.self).prefix(print.elementCount))
            }
        }
    }

    /// Variance of the Laplacian on a 512px grayscale copy, a standard blur measure.
    private static func sharpness(of image: CGImage) -> Float {
        let scale = min(1, 512 / CGFloat(max(image.width, image.height)))
        let w = max(3, Int(CGFloat(image.width) * scale))
        let h = max(3, Int(CGFloat(image.height) * scale))
        var pixels = [UInt8](repeating: 0, count: w * h)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return 0 }

        var sum: Float = 0, sumSquares: Float = 0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let center = Float(pixels[i]) * 4
                let around = Float(pixels[i - 1]) + Float(pixels[i + 1]) + Float(pixels[i - w]) + Float(pixels[i + w])
                let value = (around - center) / 255
                sum += value
                sumSquares += value * value
            }
        }
        let n = Float((w - 2) * (h - 2))
        let mean = sum / n
        return sumSquares / n - mean * mean
    }
}

/// Zooming in on a photo while looking closer or comparing.
enum Zoom {
    /// The steps + and − go through; 1 is the whole photo.
    static let steps: [Double] = [1, 1.5, 2, 3, 4, 6, 8]

    /// The part of a photo shown at `zoom` around `center` (both 0 … 1,
    /// top-left origin), for a photo `aspect` wide in a box `boxAspect` wide
    /// (width ÷ height in pixels). At 1 that's all of it; zoomed in, it
    /// fills the box once the photo is bigger than the box, and never goes
    /// past the photo's edges.
    static func crop(zoom: Double, center: CGPoint, aspect: Double, boxAspect: Double) -> CGRect {
        let w = min(1, max(1, boxAspect / aspect) / zoom), h = min(1, max(1, aspect / boxAspect) / zoom)
        return CGRect(x: min(max(0, center.x - w / 2), 1 - w), y: min(max(0, center.y - h / 2), 1 - h), width: w, height: h)
    }

    /// How much one tick of the wheel zooms: small, so a swipe is smooth.
    static let wheelStep = 1.08

    /// The next step in (1) or out (-1) from `zoom`, which may lie between steps.
    static func stepped(_ zoom: Double, _ direction: Int) -> Double {
        let here = direction > 0 ? steps.lastIndex { $0 <= zoom + 0.001 } ?? 0 : steps.firstIndex { $0 >= zoom - 0.001 } ?? 0
        return steps[min(max(0, here + direction), steps.count - 1)]
    }

    /// `zoom` after `ticks` of the wheel (up, negative, zooms in). Nearly
    /// all the way out is all the way out.
    static func wheeled(_ zoom: Double, ticks: Int) -> Double {
        let target = min(max(1, zoom * pow(wheelStep, Double(-ticks))), steps.last ?? 8)
        return target < 1.02 ? 1 : target
    }

    /// The centre after moving what's shown by a share of itself (0.25 = a
    /// quarter of what's on screen), stopping at the photo's edges.
    static func panned(_ center: CGPoint, dx: Double, dy: Double, zoom: Double, aspect: Double, boxAspect: Double) -> CGPoint {
        let shown = crop(zoom: zoom, center: center, aspect: aspect, boxAspect: boxAspect)
        let moved = crop(zoom: zoom, center: CGPoint(x: shown.midX + dx * shown.width, y: shown.midY + dy * shown.height),
                         aspect: aspect, boxAspect: boxAspect)
        return CGPoint(x: moved.midX, y: moved.midY)
    }

    /// Where the part of the photo that's shown sits in its box (0 … 1
    /// across and down the box): all of the box once the photo fills it,
    /// less while there's still room beside or above it.
    static func placement(crop: CGRect, aspect: Double, boxAspect: Double) -> CGRect {
        let shown = aspect * crop.width / max(1e-9, crop.height)
        let w = min(1, shown / boxAspect), h = min(1, boxAspect / shown)
        return CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }

    /// The centre to show at `zoom` so that the spot of the photo now under
    /// `point` (0 … 1 across and down the box) stays under it: zooming
    /// about the pointer, as far as the photo's edges allow.
    static func center(zoomingTo zoom: Double, from old: Double, center: CGPoint, about point: CGPoint,
                       aspect: Double, boxAspect: Double) -> CGPoint {
        func share(_ p: CGPoint, of placed: CGRect) -> CGPoint {
            CGPoint(x: min(max(0, (p.x - placed.minX) / placed.width), 1), y: min(max(0, (p.y - placed.minY) / placed.height), 1))
        }
        let before = crop(zoom: old, center: center, aspect: aspect, boxAspect: boxAspect)
        let from = share(point, of: placement(crop: before, aspect: aspect, boxAspect: boxAspect))
        let spot = CGPoint(x: before.minX + from.x * before.width, y: before.minY + from.y * before.height)
        let after = crop(zoom: zoom, center: center, aspect: aspect, boxAspect: boxAspect)
        let to = share(point, of: placement(crop: after, aspect: aspect, boxAspect: boxAspect))
        let wanted = CGPoint(x: spot.x - to.x * after.width + after.width / 2, y: spot.y - to.y * after.height + after.height / 2)
        let moved = crop(zoom: zoom, center: wanted, aspect: aspect, boxAspect: boxAspect)
        return CGPoint(x: moved.midX, y: moved.midY)
    }

    /// The zoom at which `crop` (as from `Faces.crop`) fills the box.
    static func level(showing crop: CGRect, aspect: Double, boxAspect: Double) -> Double {
        max(1, max(1, boxAspect / aspect) / max(0.01, crop.width))
    }

    /// "2×", "1.5×".
    static func label(_ zoom: Double) -> String {
        zoom == zoom.rounded() ? "\(Int(zoom))×" : String(format: "%.1f×", zoom)
    }
}

/// Faces in the photo being looked at, for z (zoom in on the faces).
enum Faces {
    /// Where the faces are, 0 … 1 with a top-left origin.
    static func boxes(in image: CGImage) -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil else { return [] }
        return (request.results ?? []).map { face in
            let box = face.boundingBox
            return CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
        }
    }

    /// The part of a photo that shows all its faces with room around them,
    /// shaped like the box it's drawn in. `aspect` is the photo's width ÷
    /// height, `boxAspect` the box's, both in pixels. Nil without faces.
    static func crop(_ faces: [CGRect], aspect: Double, boxAspect: Double) -> CGRect? {
        guard var area = faces.first else { return nil }
        for face in faces.dropFirst() { area = area.union(face) }
        // Room around: half a face on every side, and never closer than an
        // eighth of the photo, so a small face isn't blown up into mush.
        let margin = max(area.width, area.height) * 0.5
        var w = max(area.width + margin * 2, 0.125), h = max(area.height + margin * 2, 0.125)
        // Shape it like the box (widths compared in pixels).
        if w * aspect / h < boxAspect { w = h * boxAspect / aspect } else { h = w * aspect / boxAspect }
        // Too big for the photo: shrink it, keeping its shape.
        let over = max(w, h, 1)
        w /= over
        h /= over
        let x = min(max(0, area.midX - w / 2), 1 - w), y = min(max(0, area.midY - h / 2), 1 - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
