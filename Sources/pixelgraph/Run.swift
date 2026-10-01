import Foundation

/// The result of one `pixelgraph scan`: what the report shows and `apply` will write.
struct Run: Codable {
    var date: Date
    /// Display name of what was scanned.
    var scope: String
    /// What was scanned; nil for scans from before sources existed.
    var source: Source?
    var scanned: Int
    var rules: GroupingRules
    var groups: [Group]

    struct Group: Codable {
        enum Kind: String, Codable {
            case copies, moment, scene, screenshots

            var title: String {
                switch self {
                case .copies: "Copies & edits"
                case .moment: "Same moment"
                case .scene: "Same scene"
                case .screenshots: "Screenshots"
                }
            }
        }

        var kind: Kind
        /// Oldest first.
        var photos: [Member]
        var pick: Pick
        /// Opened in `pixelgraph review`.
        var reviewed: Bool?
    }

    struct Member: Codable {
        var id: String
        var date: Date
        var width: Int
        var height: Int
        var aesthetic: Float
        var sharpness: Float
        var faceCount: Int
        var faceQuality: Float
        /// Long side of the image the scores came from; under 1024 means the
        /// original was in iCloud and couldn't be downloaded.
        var previewSide: Int
    }

    /// Best first, then kept photos, then the ones moving, moved last.
    static func displayOrder(_ group: Group) -> [Member] {
        let pick = group.pick
        func rank(_ m: Member) -> Int {
            pick.keepers.contains(m.id) ? 0 : pick.kept.contains(m.id) ? 1 : pick.moved.contains(m.id) ? 3 : 2
        }
        return group.photos.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    /// Photos selected to move, across all groups.
    var toMove: [String] {
        groups.flatMap { g in g.photos.map(\.id).filter { g.pick.willMove($0) } }
    }

    func save(to url: URL = Paths.lastRun) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    static func load(from url: URL = Paths.lastRun) throws -> Run {
        guard let data = try? Data(contentsOf: url) else { throw PixelGraphError.noRun }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Run.self, from: data)
    }
}

extension Run.Group.Kind {
    init(_ photos: [Photo], rules: GroupingRules) {
        let farthest = photos.indices.flatMap { i in photos.indices.filter { $0 > i }.map { (i, $0) } }
            .map { Grouper.distance(photos[$0.0], photos[$0.1]) }.max() ?? 0
        let span = (photos.map(\.date).max() ?? .now).timeIntervalSince(photos.map(\.date).min() ?? .now)
        // Calibrated on test images: resized copies ~0.03, crops and colour
        // edits 0.08–0.21. Re-imported copies keep the original capture time.
        if photos.allSatisfy(\.isScreenshot) { self = .screenshots }
        else if farthest < 0.06 || (farthest < 0.25 && span < 2) { self = .copies }
        else if span <= rules.momentWindow { self = .moment }
        else { self = .scene }
    }
}
