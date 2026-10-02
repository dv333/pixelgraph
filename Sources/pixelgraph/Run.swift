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
    /// Documents found in the scan (Sort documents), each in a group of
    /// copies with the same text; nil when documents weren't sorted.
    var documentGroups: [Group]?
    /// Photos with no lookalike that look like rejects on their own (blurry,
    /// nearly black, blown out, smudged), all selected to move; nil when not looked for.
    var junkGroups: [Group]?

    /// Every group on every tab.
    var allGroups: [Group] { groups + (documentGroups ?? []) + (junkGroups ?? []) }

    struct Group: Codable {
        enum Kind: String, Codable {
            case copies, moment, scene, screenshots, documents, junk

            var title: String {
                switch self {
                case .copies: "Copies & edits"
                case .moment: "Same moment"
                case .scene: "Same scene"
                case .screenshots: "Screenshots"
                case .documents: "Documents"
                case .junk: "Junk"
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
        /// A one-line description and scene tags, when made.
        var summary: String?
        var tags: [String]?
        /// For documents: what it is ("Receipt · Pier 39 Café"), its first
        /// words, and how alike its text is to the copy being filed.
        var document: String?
        var excerpt: String?
        var sameText: Double?
        /// A caption, title and keywords were written to it when kept.
        var captioned: Bool?
        /// The sharpness and exposure (0 … 1) the pick compared, for learning
        /// from your choices. Nil in older scans.
        var focus: Float?
        var exposure: Float?
        /// Bytes on disk, everything included. Nil until known.
        var bytes: Int?
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

    /// The size of these photos together; nil when none of them is known.
    func bytes(_ ids: [String]) -> Int? {
        let wanted = Set(ids)
        let sizes = allGroups.flatMap(\.photos).filter { wanted.contains($0.id) }.compactMap(\.bytes)
        return sizes.isEmpty ? nil : sizes.reduce(0, +)
    }

    /// Photos whose size isn't known yet (older scans).
    var unsized: [String] { allGroups.flatMap(\.photos).filter { $0.bytes == nil }.map(\.id) }

    /// Writes in each photo's size, from a scan or a lookup.
    mutating func fillSizes(_ sizes: [String: Int]) {
        func fill(_ list: inout [Group]) {
            for g in list.indices {
                for p in list[g].photos.indices where list[g].photos[p].bytes == nil {
                    list[g].photos[p].bytes = sizes[list[g].photos[p].id]
                }
            }
        }
        fill(&groups)
        if documentGroups != nil { fill(&documentGroups!) }
        if junkGroups != nil { fill(&junkGroups!) }
    }

    static func size(_ bytes: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }

    /// Photos selected to move, across all groups.
    var toMove: [String] {
        groups.flatMap { g in g.photos.map(\.id).filter { g.pick.willMove($0) } }
    }

    /// Photos still waiting for a decision to be carried out, on every tab.
    var waiting: Int {
        allGroups.reduce(0) { n, g in n + g.photos.filter { g.pick.willMove($0.id) }.count } + documentsToFile.count
    }

    /// Groups you've opened: work that a new scan would replace.
    var reviewedGroups: Int { allGroups.filter { $0.reviewed == true }.count }

    /// Documents to file in PGDocuments (the best copy in each group) and the
    /// extra copies that go to Duplicates.
    var documentsToFile: [String] {
        (documentGroups ?? []).flatMap { g in g.pick.keepers.filter { !g.pick.moved.contains($0) } }
    }

    var documentCopies: [String] {
        (documentGroups ?? []).flatMap { g in g.photos.map(\.id).filter { g.pick.willMove($0) } }
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
        else if photos.indices.allSatisfy({ i in photos.indices.allSatisfy { j in
            i == j || GroupingRules.isCopy(photos[i], photos[j], distance: Grouper.distance(photos[i], photos[j])) } }) { self = .copies }
        else if span <= rules.momentWindow { self = .moment }
        else { self = .scene }
    }
}
