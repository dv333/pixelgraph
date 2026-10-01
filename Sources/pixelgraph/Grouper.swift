import Accelerate
import Foundation

struct Photo: Sendable {
    let id: String
    let date: Date
    let isScreenshot: Bool
    let width: Int
    let height: Int
    let analysis: Analysis
    var pixels: Int { width * height }
}

/// How close two fingerprints must be to count as the same shot.
/// Distances are Euclidean between Vision feature prints (Vision's own
/// `distance(to:)` is the square of this). On test images: resized copy 0.03,
/// crops/edits 0.08–0.21, black & white 0.58, unrelated photos 0.73+.
struct GroupingRules: Sendable, Codable {
    /// Photos taken within `momentWindow` seconds of each other: retakes,
    /// bursts, portraits where only the expression changes.
    var momentThreshold: Float
    var momentWindow: TimeInterval
    /// Photos taken any time apart must be this close: copies, edits,
    /// the same scene revisited. Stricter, so a year of couch photos
    /// doesn't collapse into one group.
    var sceneThreshold: Float

    func threshold(_ a: Photo, _ b: Photo) -> Float {
        if a.isScreenshot != b.isScreenshot { return -1 }
        return abs(a.date.timeIntervalSince(b.date)) <= momentWindow ? momentThreshold : sceneThreshold
    }
}

enum Grouper {
    /// Groups of near-identical photos (2+ members) as indices into `photos`,
    /// in date order.
    ///
    /// Complete linkage: every pair inside a group must pass its threshold,
    /// so a chain of slightly-different shots can't drift into one huge group.
    static func groups(_ photos: [Photo], rules: GroupingRules) -> [[Int]] {
        let n = photos.count
        guard n > 1, let d = photos.first?.analysis.vector.count, d > 0 else { return [] }

        // Row-major n×d matrix and squared norms; distance² = |a|² + |b|² − 2a·b.
        var matrix = [Float](repeating: 0, count: n * d)
        var norms = [Float](repeating: 0, count: n)
        for (i, photo) in photos.enumerated() {
            matrix.replaceSubrange(i * d ..< (i + 1) * d, with: photo.analysis.vector)
            vDSP_svesq(photo.analysis.vector, 1, &norms[i], vDSP_Length(d))
        }
        func distance(_ i: Int, _ j: Int, dot: Float) -> Float { (max(0, norms[i] + norms[j] - 2 * dot)).squareRoot() }

        // Candidate pairs, found block by block with a matrix multiply so
        // 20k photos stay at seconds, not minutes.
        let loosest = max(rules.momentThreshold, rules.sceneThreshold)
        var transposed = [Float](repeating: 0, count: d * n)
        vDSP_mtrans(matrix, 1, &transposed, 1, vDSP_Length(d), vDSP_Length(n))
        var edges: [(i: Int, j: Int, distance: Float)] = []
        let block = 256
        var dots = [Float](repeating: 0, count: block * n)
        for start in stride(from: 0, to: n, by: block) {
            let rows = min(block, n - start)
            matrix.withUnsafeBufferPointer { a in
                vDSP_mmul(a.baseAddress! + start * d, 1, transposed, 1, &dots, 1,
                          vDSP_Length(rows), vDSP_Length(n), vDSP_Length(d))
            }
            for r in 0..<rows {
                let i = start + r
                for j in (i + 1)..<n {
                    let dist = distance(i, j, dot: dots[r * n + j])
                    guard dist <= loosest else { continue }
                    if dist <= rules.threshold(photos[i], photos[j]) { edges.append((i, j, dist)) }
                }
            }
        }

        // Merge closest pairs first.
        edges.sort { $0.distance < $1.distance }
        var groupOf = Array(0..<n)
        var members = (0..<n).map { [$0] }
        func close(_ i: Int, _ j: Int) -> Bool {
            var dot: Float = 0
            matrix.withUnsafeBufferPointer { m in
                vDSP_dotpr(m.baseAddress! + i * d, 1, m.baseAddress! + j * d, 1, &dot, vDSP_Length(d))
            }
            return distance(i, j, dot: dot) <= rules.threshold(photos[i], photos[j])
        }
        for edge in edges {
            let a = groupOf[edge.i], b = groupOf[edge.j]
            guard a != b else { continue }
            let fits = members[a].allSatisfy { i in members[b].allSatisfy { j in close(i, j) } }
            guard fits else { continue }
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

    /// Distance between two photos' fingerprints, for the report.
    static func distance(_ a: Photo, _ b: Photo) -> Float {
        var sum: Float = 0
        vDSP_distancesq(a.analysis.vector, 1, b.analysis.vector, 1, &sum, vDSP_Length(a.analysis.vector.count))
        return sum.squareRoot()
    }
}
