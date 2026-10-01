import Accelerate
import Foundation

struct Photo: Sendable {
    let id: String
    let date: Date
    let isScreenshot: Bool
    let width: Int
    let height: Int
    let analysis: Analysis
    /// Measures from the preview: focus, noise, exposure, copy hash. Nil when not measured.
    var quality: Quality? = nil
    /// Where it was taken, when known.
    var location: Location? = nil
    var pixels: Int { width * height }
    var aspect: Double { height > 0 ? Double(width) / Double(height) : 1 }
}

/// A place on Earth, from Photos or a file's GPS tags.
struct Location: Codable, Sendable, Equatable {
    var latitude: Double
    var longitude: Double

    /// Great-circle distance in metres.
    func distance(to other: Location) -> Double {
        let r = 6_371_000.0, rad = Double.pi / 180
        let dLat = (other.latitude - latitude) * rad, dLon = (other.longitude - longitude) * rad
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(latitude * rad) * cos(other.latitude * rad) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, a.squareRoot()))
    }
}

/// How close two fingerprints must be to count as the same shot.
/// Distances are Euclidean between Vision feature prints (Vision's own
/// `distance(to:)` is the square of this). On test images: resized copy 0.03,
/// crops/edits 0.08–0.21, black & white 0.58, unrelated photos 0.73+.
struct GroupingRules: Sendable, Codable {
    /// The distance allowed for shots taken at the same moment: retakes,
    /// bursts, portraits where only the expression changes.
    var momentThreshold: Float
    /// How fast that loosens toward `sceneThreshold`: by this many seconds
    /// apart, almost all the way.
    var momentWindow: TimeInterval
    /// The distance allowed for shots any time apart: copies, edits, the same
    /// scene revisited. Stricter, so a year of couch photos doesn't collapse
    /// into one group.
    var sceneThreshold: Float
    /// Photos taken this far apart (metres) aren't the same shot unless
    /// they're copies; 0 turns it off. Nil in scans saved before it could change.
    var farApartMetres: Double? = nil

    /// Copies and re-saves: this close a fingerprint, or this few hash bits
    /// apart at the same shape, count as the same picture wherever and whenever.
    static let copyDistance: Float = 0.1
    static let copyHashBits = 4
    static let defaultFarApart: Double = 2_000

    /// The allowed distance slides smoothly from the moment threshold to the
    /// scene threshold as photos get further apart in time, instead of
    /// jumping at a cutoff. -1 when the pair can never match.
    func threshold(_ a: Photo, _ b: Photo) -> Float {
        if a.isScreenshot != b.isScreenshot { return -1 }
        let seconds = abs(a.date.timeIntervalSince(b.date))
        let closeness = Float(exp(-seconds / max(1, momentWindow / 3)))
        var threshold = sceneThreshold + (momentThreshold - sceneThreshold) * closeness
        // A different number of people is usually a different shot.
        let faces = abs(a.analysis.faceCount - b.analysis.faceCount)
        if faces >= 2, a.analysis.faceCount > 0, b.analysis.faceCount > 0 { threshold -= 0.1 }
        return threshold
    }

    /// The same picture: a re-save, resize or light edit.
    static func isCopy(_ a: Photo, _ b: Photo, distance: Float) -> Bool {
        if distance <= copyDistance / 2 { return true }
        guard let ha = a.quality?.hash, let hb = b.quality?.hash, ha != 0, hb != 0 else { return false }
        return Quality.distance(ha, hb) <= copyHashBits && abs(a.aspect - b.aspect) < 0.02 && distance <= copyDistance
    }

    /// Taken in clearly different places.
    func farApart(_ a: Photo, _ b: Photo) -> Bool {
        let limit = farApartMetres ?? Self.defaultFarApart
        guard limit > 0, let la = a.location, let lb = b.location else { return false }
        return la.distance(to: lb) > limit
    }
}

enum Grouper {
    struct Edge: Sendable {
        let i: Int
        let j: Int
        let distance: Float
        /// A close call between photos taken apart in time: worth checking
        /// that the pictures really line up before grouping them.
        let needsCheck: Bool
    }

    /// Groups of near-identical photos (2+ members) as indices into `photos`,
    /// in date order. Close calls are trusted; the scan checks them first.
    static func groups(_ photos: [Photo], rules: GroupingRules) -> [[Int]] {
        cluster(photos, edges: edges(photos, rules: rules), rules: rules)
    }

    /// Every pair close enough to be the same shot, closest first.
    static func edges(_ photos: [Photo], rules: GroupingRules) -> [Edge] {
        let n = photos.count
        guard n > 1, let d = photos.first?.analysis.vector.count, d > 0 else { return [] }
        let m = Matrix(photos)

        // Candidate pairs, found block by block with a matrix multiply so
        // 20k photos stay at seconds, not minutes.
        let loosest = max(rules.momentThreshold, rules.sceneThreshold)
        var transposed = [Float](repeating: 0, count: d * n)
        vDSP_mtrans(m.rows, 1, &transposed, 1, vDSP_Length(d), vDSP_Length(n))
        var edges: [Edge] = []
        let block = 256
        var dots = [Float](repeating: 0, count: block * n)
        for start in stride(from: 0, to: n, by: block) {
            let rows = min(block, n - start)
            m.rows.withUnsafeBufferPointer { a in
                vDSP_mmul(a.baseAddress! + start * d, 1, transposed, 1, &dots, 1,
                          vDSP_Length(rows), vDSP_Length(n), vDSP_Length(d))
            }
            for r in 0..<rows {
                let i = start + r
                for j in (i + 1)..<n {
                    let dist = m.distance(i, j, dot: dots[r * n + j])
                    guard dist <= loosest else { continue }
                    let (a, b) = (photos[i], photos[j])
                    let copy = GroupingRules.isCopy(a, b, distance: dist)
                    if copy, a.isScreenshot == b.isScreenshot {
                        edges.append(Edge(i: i, j: j, distance: dist, needsCheck: false))
                        continue
                    }
                    guard dist <= rules.threshold(a, b), !rules.farApart(a, b) else { continue }
                    let apart = abs(a.date.timeIntervalSince(b.date)) > rules.momentWindow
                    edges.append(Edge(i: i, j: j, distance: dist, needsCheck: apart))
                }
            }
        }
        return edges.sorted { $0.distance < $1.distance }
    }

    /// Average linkage: two groups join when their photos are, on average,
    /// within their thresholds and no pair is far beyond, so a burst that pans
    /// stays together but a chain of slightly different shots can't drift
    /// into one huge group. `rejected` pairs never share a group.
    static func cluster(_ photos: [Photo], edges: [Edge], rules: GroupingRules,
                        rejected: Set<Pair> = []) -> [[Int]] {
        let m = Matrix(photos)
        let linked = Set(edges.map { Pair($0.i, $0.j) })
        /// Distance as a share of what's allowed; infinite when never allowed.
        func ratio(_ i: Int, _ j: Int) -> Float {
            let pair = Pair(i, j)
            if rejected.contains(pair) { return .infinity }
            let dist = m.distance(i, j)
            if linked.contains(pair), GroupingRules.isCopy(photos[i], photos[j], distance: dist) { return 0 }
            let threshold = rules.threshold(photos[i], photos[j])
            guard threshold > 0, !rules.farApart(photos[i], photos[j]) else { return .infinity }
            return dist / threshold
        }
        var groupOf = Array(0..<photos.count)
        var members = photos.indices.map { [$0] }
        for edge in edges {
            let a = groupOf[edge.i], b = groupOf[edge.j]
            guard a != b, !rejected.contains(Pair(edge.i, edge.j)) else { continue }
            var total: Float = 0, worst: Float = 0
            for i in members[a] {
                for j in members[b] {
                    let r = ratio(i, j)
                    total += r
                    worst = max(worst, r)
                }
            }
            let mean = total / Float(members[a].count * members[b].count)
            guard mean <= 1, worst <= 1.15 else { continue }
            let (keep, drop) = members[a].count >= members[b].count ? (a, b) : (b, a)
            for i in members[drop] { groupOf[i] = keep }
            members[keep] += members[drop]
            members[drop] = []
        }

        return members
            .filter { $0.count > 1 }
            .map { $0.sorted { photos[$0].date < photos[$1].date } }
            .sorted { photos[$0[0]].date < photos[$1[0]].date }
    }

    /// An unordered pair of photo indices.
    struct Pair: Hashable, Sendable {
        let low: Int
        let high: Int
        init(_ a: Int, _ b: Int) { (low, high) = a < b ? (a, b) : (b, a) }
    }

    /// Distance between two photos' fingerprints, for the report.
    static func distance(_ a: Photo, _ b: Photo) -> Float {
        var sum: Float = 0
        vDSP_distancesq(a.analysis.vector, 1, b.analysis.vector, 1, &sum, vDSP_Length(a.analysis.vector.count))
        return sum.squareRoot()
    }

    /// Fingerprints as a row-major n×d matrix with squared norms, so
    /// distance² = |a|² + |b|² − 2a·b.
    private struct Matrix {
        let rows: [Float]
        let norms: [Float]
        let d: Int

        init(_ photos: [Photo]) {
            d = photos.first?.analysis.vector.count ?? 0
            var rows = [Float](repeating: 0, count: photos.count * d)
            var norms = [Float](repeating: 0, count: photos.count)
            for (i, photo) in photos.enumerated() where photo.analysis.vector.count == d && d > 0 {
                rows.replaceSubrange(i * d ..< (i + 1) * d, with: photo.analysis.vector)
                vDSP_svesq(photo.analysis.vector, 1, &norms[i], vDSP_Length(d))
            }
            self.rows = rows
            self.norms = norms
        }

        func distance(_ i: Int, _ j: Int, dot: Float) -> Float { max(0, norms[i] + norms[j] - 2 * dot).squareRoot() }

        func distance(_ i: Int, _ j: Int) -> Float {
            var dot: Float = 0
            rows.withUnsafeBufferPointer { m in
                vDSP_dotpr(m.baseAddress! + i * d, 1, m.baseAddress! + j * d, 1, &dot, vDSP_Length(d))
            }
            return distance(i, j, dot: dot)
        }
    }
}
