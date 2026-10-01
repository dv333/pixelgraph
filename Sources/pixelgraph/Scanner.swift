import CoreGraphics
import Foundation

/// The scan: read a source, fingerprint every photo, group lookalikes, score
/// and check the grouped ones, pick the best, and prepare previews.
struct Scanner {
    struct Options {
        var rules = GroupingRules(momentThreshold: 0.5, momentWindow: 600, sceneThreshold: 0.3)
        var useModel = true
        var offline = false
    }

    let source: Source
    let options: Options
    let board: ProgressBoard

    static let stages = ["Read photos", "Fingerprint", "Group lookalikes", "Score grouped photos",
                         "Check eyes and faces", "Pick the best shots", "Prepare previews"]

    init(source: Source, options: Options, fullScreen: Bool = false) {
        self.source = source
        self.options = options
        let where_ = source.isPhotos ? "on this Mac, nothing uploaded" : source.kind.lowercased()
        board = ProgressBoard(heading: "Scanning \(source)  ·  \(where_)", stages: Self.stages, fullScreen: fullScreen)
    }

    func run() async throws -> Run {
        board.begin()
        board.start(0, detail: source.isPhotos ? "reading library…" : "looking through folders…")
        let items = try Items.load(source)
        let lookup = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let cloudOnly = items.filter { $0.fileURL.map(Files.isCloudOnly) ?? false }.count
        board.finish(0, detail: "\(items.count.formatted()) photos" + (cloudOnly > 0 ? ", \(cloudOnly) in iCloud only" : ""))

        let photos = try await fingerprint(items)
        board.start(2)
        let indexGroups = Grouper.groups(photos, rules: options.rules)
        let groupedCount = indexGroups.reduce(0) { $0 + $1.count }
        board.finish(2, detail: "\(indexGroups.count) groups · \(groupedCount) photos")
        board.setSummary(summary(groups: indexGroups.count, moving: groupedCount - indexGroups.count, problems: 0))

        let grouped = indexGroups.flatMap { $0 }.map { photos[$0] }
        let rescored = try await score(grouped, lookup)
        let photosNow = photos.map { rescored[$0.id] ?? $0 }
        let useModel = options.useModel && Picker.modelAvailable
        let problems = try await inspect(indexGroups.flatMap { $0 }.map { photosNow[$0] }, lookup, useModel: useModel)
        board.setSummary(summary(groups: indexGroups.count, moving: groupedCount - indexGroups.count, problems: problems.count))

        board.start(5, total: indexGroups.count)
        var groups: [Run.Group] = []
        let fetch = fetchPolicy
        for (n, indices) in indexGroups.enumerated() {
            let members = indices.map { photosNow[$0] }
            groups.append(Run.Group(
                kind: Run.Group.Kind(members, rules: options.rules),
                photos: members.map(Run.Member.init),
                pick: await Picker.pick(members, useModel: useModel, problems: problems) { id in
                    await lookup[id]?.image(maxSide: 768, fetch: fetch)
                }
            ))
            board.advance(5, done: n + 1)
        }
        let closeCalls = groups.filter { $0.pick.decidedBy == "apple-model" }.count
        board.finish(5, detail: closeCalls > 0 ? "\(closeCalls) close call\(closeCalls == 1 ? "" : "s") settled by Apple Intelligence" : "clear winners")

        var run = Run(date: .now, scope: source.description, scanned: photos.count, rules: options.rules, groups: groups)
        run.source = source
        try run.save()

        board.start(6, total: groupedCount)
        try await Report.write(run, items: lookup, offline: options.offline) { done, _ in board.advance(6, done: done) }
        board.finish(6, detail: "ready to review")
        board.setSummary(summary(groups: groups.count, moving: run.toMove.count, problems: problems.count))
        board.end()
        Recents.record(run)
        return run
    }

    private var fetchPolicy: Library.Fetch { options.offline ? .localOnly : .download(timeout: 60) }

    private func summary(groups: Int, moving: Int, problems: Int) -> String {
        var parts = ["\u{1B}[1m\(groups)\u{1B}[22m groups", "\u{1B}[1m\(moving)\u{1B}[22m photos you could move"]
        if problems > 0 { parts.append("\u{1B}[38;2;255;179;64m\(problems)\u{1B}[39m look like rejects") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Stages

    /// Vision fingerprint and scores for every photo, from the index when cached.
    private func fingerprint(_ items: [Item]) async throws -> [Photo] {
        let store = try Store()
        var results: [String: Analysis] = [:]
        var pending: [Item] = []
        for item in items {
            if let cached = store.analysis(id: item.id, modified: item.modified) {
                results[item.id] = cached
            } else {
                pending.append(item)
            }
        }
        board.start(1, total: pending.count)
        var done = 0, failed = 0
        var unsaved: [(Item, Analysis)] = []
        func flush() throws {
            try store.transaction { for (item, a) in unsaved { try store.save(a, id: item.id, modified: item.modified) } }
            unsaved.removeAll()
        }
        try await withThrowingTaskGroup(of: (Item, Analysis?).self) { tasks in
            var next = 0
            func add() {
                guard next < pending.count else { return }
                let item = pending[next]
                next += 1
                tasks.addTask {
                    guard let image = await item.image(maxSide: 512, fetch: .localOnly) else { return (item, nil) }
                    return (item, try? await Analyzer.analyze(image))
                }
            }
            for _ in 0..<8 { add() }
            for try await (item, analysis) in tasks {
                done += 1
                if let analysis {
                    results[item.id] = analysis
                    unsaved.append((item, analysis))
                } else {
                    failed += 1
                }
                // Saved as we go, so a stopped scan picks up where it left off.
                if unsaved.count >= 50 { try flush() }
                board.advance(1, done: done)
                add()
            }
        }
        try flush()
        let cached = items.count - pending.count
        var detail = "\(items.count.formatted()) photos"
        if cached > 0 { detail += ", \(cached.formatted()) already known" }
        if failed > 0 { detail += ", \(failed) unreadable" }
        board.finish(1, detail: detail)

        return items.compactMap { item in
            results[item.id].map {
                // iCloud Drive files have no size until downloaded; use the thumbnail's shape.
                let (w, h) = item.width > 0 ? (item.width, item.height) : ($0.previewSide, $0.previewSide)
                return Photo(id: item.id, date: item.date, isScreenshot: item.isScreenshot, width: w, height: h, analysis: $0)
            }
        }
    }

    /// Grouped photos are re-scored from a 1024px image so sharpness, faces and
    /// eyes are judged on real detail. With iCloud this is the first step that
    /// downloads, and only for photos that ended up in a group.
    private func score(_ photos: [Photo], _ lookup: [String: Item]) async throws -> [String: Photo] {
        let store = try Store()
        var result: [String: Photo] = [:]
        var pending: [(Photo, Item)] = []
        for photo in photos {
            guard let item = lookup[photo.id] else { continue }
            if let cached = store.analysis(id: photo.id, modified: item.modified, in: .detail),
               !(photo.isPreviewOnly(cached) && !options.offline) {
                result[photo.id] = photo.with(cached)
            } else {
                pending.append((photo, item))
            }
        }
        guard !pending.isEmpty else {
            board.finish(3, detail: photos.isEmpty ? "nothing to score" : "\(photos.count) photos, already scored")
            return result
        }

        board.start(3, total: pending.count)
        let fetch = fetchPolicy
        var done = 0, small = 0
        try await withThrowingTaskGroup(of: (Photo, Item, Analysis?).self) { tasks in
            var next = 0
            func add() {
                guard next < pending.count else { return }
                let (photo, item) = pending[next]
                next += 1
                tasks.addTask {
                    guard let image = await item.image(maxSide: 1024, fetch: fetch) else { return (photo, item, nil) }
                    return (photo, item, try? await Analyzer.analyze(image, fingerprint: false, eyes: true))
                }
            }
            for _ in 0..<4 { add() }
            for try await (photo, item, analysis) in tasks {
                done += 1
                if let analysis {
                    result[photo.id] = photo.with(analysis)
                    try store.save(analysis, id: photo.id, modified: item.modified, in: .detail)
                    if photo.isPreviewOnly(analysis) { small += 1 }
                }
                board.advance(3, done: done)
                add()
            }
        }
        board.finish(3, detail: "\(pending.count) photos" + (small > 0 ? ", \(small) from small previews (iCloud)" : ""))
        return result
    }

    /// Suggested moves (closed eyes, blocked faces, cut-off heads) for grouped
    /// photos with people in them. Cached, so only new photos are looked at.
    private func inspect(_ photos: [Photo], _ lookup: [String: Item], useModel: Bool) async throws -> [String: String] {
        let store = try Store()
        var problems: [String: String] = [:]
        var pending: [(Photo, Item)] = []
        for photo in photos where photo.analysis.faceCount > 0 {
            guard let item = lookup[photo.id] else { continue }
            if let cached = store.suggestion(id: photo.id, modified: item.modified) {
                if let reason = cached { problems[photo.id] = reason }
            } else {
                pending.append((photo, item))
            }
        }
        guard !pending.isEmpty else {
            board.finish(4, detail: problems.isEmpty ? "no problems spotted" : "\(problems.count) look like rejects")
            return problems
        }

        board.start(4, total: pending.count)
        let fetch = fetchPolicy
        for (n, (photo, item)) in pending.enumerated() {
            if let image = await item.image(maxSide: 768, fetch: fetch) {
                let reason = await Inspector.inspect(image, analysis: photo.analysis, useModel: useModel)
                if let reason { problems[photo.id] = reason }
                // Without the model the check is rougher; don't keep it as final.
                if useModel { try store.saveSuggestion(reason, id: photo.id, modified: item.modified) }
            }
            board.advance(4, done: n + 1)
        }
        let kinds = Set(problems.values).sorted().joined(separator: ", ")
        board.finish(4, detail: problems.isEmpty ? "no problems spotted" : "\(problems.count) look like rejects (\(kinds))")
        return problems
    }
}

/// Recently scanned sources, for the home screen.
enum Recents {
    struct Entry: Codable {
        var source: Source
        var date: Date
        var photos: Int
        var groups: Int
    }

    static var file: URL { Paths.root.appendingPathComponent("recent.json") }

    static func all() -> [Entry] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Entry].self, from: data)) ?? []
    }

    static func record(_ run: Run) {
        guard let source = run.source else { return }
        var entries = all().filter { $0.source != source }
        entries.insert(Entry(source: source, date: run.date, photos: run.scanned, groups: run.groups.count), at: 0)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(Array(entries.prefix(12))).write(to: file, options: .atomic)
    }
}
