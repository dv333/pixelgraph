import CoreGraphics
import Foundation

/// The scan: read a source, fingerprint every photo, group lookalikes, score
/// and check the grouped ones, pick the best, and prepare previews.
struct Scanner {
    struct Options {
        var rules = GroupingRules(momentThreshold: 0.5, momentWindow: 600, sceneThreshold: 0.3)
        var useModel = true
        var offline = false
        /// Gather documents into their own tab, to file in PGDocuments.
        var documents = true
        /// Describe and tag the photos in groups.
        var describe = true
    }

    let source: Source
    let options: Options
    let board: ProgressBoard

    static let stages = ["Read photos", "Fingerprint", "Find documents", "Group lookalikes", "Score grouped photos",
                         "Check eyes and faces", "Describe photos", "Pick the best shots", "Prepare previews"]

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
        let useModel = options.useModel && Picker.modelAvailable

        // Documents are matched by what they say, not just how they look:
        // two forms from one template look identical but aren't duplicates.
        let documents = try await findDocuments(photos, lookup, useModel: useModel)
        let others = photos.filter { documents[$0.id] == nil }
        let docPhotos = photos.filter { documents[$0.id] != nil }

        board.start(3)
        let lookalikes = Grouper.groups(others, rules: options.rules).map { $0.map { others[$0] } }
        let copies = Self.documentGroups(docPhotos, documents)
        let groupedCount = lookalikes.reduce(0) { $0 + $1.count }
        board.finish(3, detail: "\(lookalikes.count) groups · \(groupedCount) photos"
            + (docPhotos.isEmpty ? "" : " · \(copies.filter { $0.count > 1 }.count) documents with copies"))
        board.setSummary(summary(groups: lookalikes.count, moving: groupedCount - lookalikes.count, problems: 0, documents: docPhotos.count))

        let toScore = lookalikes.flatMap { $0 } + copies.filter { $0.count > 1 }.flatMap { $0 }
        let rescored = try await score(toScore, lookup)
        let now: (Photo) -> Photo = { rescored[$0.id] ?? $0 }
        let groupedNow = lookalikes.map { $0.map(now) }
        let copiesNow = copies.map { $0.map(now) }

        let problems = try await inspect(groupedNow.flatMap { $0 }, lookup, useModel: useModel)
        let described = options.describe ? try await describe(groupedNow.flatMap { $0 }, lookup, useModel: useModel) : [:]
        if !options.describe { board.skip(6, detail: "off") }
        board.setSummary(summary(groups: lookalikes.count, moving: groupedCount - lookalikes.count,
                                 problems: problems.count, documents: docPhotos.count))

        board.start(7, total: groupedNow.count + copiesNow.count)
        var groups: [Run.Group] = []
        let fetch = fetchPolicy
        for (n, members) in groupedNow.enumerated() {
            var group = Run.Group(
                kind: Run.Group.Kind(members, rules: options.rules),
                photos: members.map(Run.Member.init),
                pick: await Picker.pick(members, useModel: useModel, problems: problems) { id in
                    await lookup[id]?.image(maxSide: 768, fetch: fetch)
                })
            for i in group.photos.indices {
                group.photos[i].summary = described[group.photos[i].id]?.summary
                group.photos[i].tags = described[group.photos[i].id]?.tags
            }
            groups.append(group)
            board.advance(7, done: n + 1)
        }
        var documentGroups: [Run.Group] = []
        for (n, members) in copiesNow.enumerated() {
            documentGroups.append(await documentGroup(members, documents))
            board.advance(7, done: groupedNow.count + n + 1)
        }
        let closeCalls = groups.filter { $0.pick.decidedBy == "apple-model" }.count
        board.finish(7, detail: closeCalls > 0 ? "\(closeCalls) close call\(closeCalls == 1 ? "" : "s") settled by Apple Intelligence" : "clear winners")

        var run = Run(date: .now, scope: source.description, scanned: photos.count, rules: options.rules, groups: groups)
        run.source = source
        if options.documents {
            run.documentGroups = documentGroups
        } else {
            // Not sorting documents: copies of the same document are still duplicates.
            run.groups += documentGroups.filter { $0.photos.count > 1 }
        }
        try run.save()

        let previewCount = run.groups.reduce(0) { $0 + $1.photos.count } + (run.documentGroups ?? []).reduce(0) { $0 + $1.photos.count }
        board.start(8, total: previewCount)
        try await Report.write(run, items: lookup, offline: options.offline) { done, _ in board.advance(8, done: done) }
        board.finish(8, detail: "ready to review")
        board.setSummary(summary(groups: groups.count, moving: run.toMove.count, problems: problems.count,
                                 documents: run.documentGroups.map { $0.reduce(0) { $0 + $1.photos.count } } ?? 0))
        board.end()
        Recents.record(run)
        return run
    }

    /// Copies of the same document: their text is at least 85% the same
    /// words, or, for screenshots with little text, the images are near-exact.
    static func documentGroups(_ photos: [Photo], _ documents: [String: Insight.Document]) -> [[Photo]] {
        var parent = Array(photos.indices)
        func root(_ i: Int) -> Int { parent[i] == i ? i : root(parent[i]) }
        for i in photos.indices {
            for j in photos.indices where j > i {
                let (a, b) = (documents[photos[i].id]?.text ?? "", documents[photos[j].id]?.text ?? "")
                let wordy = Insight.words(a).count >= 8 && Insight.words(b).count >= 8
                let same = wordy ? Insight.similarity(a, b) >= 0.85 : Grouper.distance(photos[i], photos[j]) < 0.06
                if same { parent[root(j)] = root(i) }
            }
        }
        return Dictionary(grouping: photos.indices, by: root).values
            .map { $0.map { photos[$0] }.sorted { $0.date < $1.date } }
            .sorted { $0[0].date < $1[0].date }
    }

    /// The sharpest copy is filed in PGDocuments; other copies go to Duplicates.
    private func documentGroup(_ members: [Photo], _ documents: [String: Insight.Document]) async -> Run.Group {
        var pick = members.count > 1
            ? await Picker.pick(members, useModel: false)
            : Pick(best: members[0].id, decidedBy: "vision", notes: [members[0].id: "only copy"])
        let bestText = documents[pick.best]?.text ?? ""
        var photos = members.map(Run.Member.init)
        for i in photos.indices {
            guard let doc = documents[photos[i].id] else { continue }
            photos[i].document = doc.label
            photos[i].excerpt = doc.text.split(separator: "\n").map(String.init).first { $0.count > 3 }.map { String($0.prefix(80)) }
            if photos[i].id != pick.best, members.count > 1 {
                photos[i].sameText = Insight.similarity(doc.text, bestText)
                pick.notes[photos[i].id] = "copy of the filed one"
            }
        }
        if members.count > 1 { pick.notes[pick.best] = "sharpest copy" }
        return Run.Group(kind: .documents, photos: photos, pick: pick)
    }

    private var fetchPolicy: Library.Fetch { options.offline ? .localOnly : .download(timeout: 60) }

    private func summary(groups: Int, moving: Int, problems: Int, documents: Int) -> String {
        var parts = ["\u{1B}[1m\(groups)\u{1B}[22m groups", "\u{1B}[1m\(moving)\u{1B}[22m photos you could move"]
        if documents > 0 { parts.append("\u{1B}[1m\(documents)\u{1B}[22m documents") }
        if problems > 0 { parts.append(Theme.fg(Theme.amber) + "\(problems)\u{1B}[39m look like rejects") }
        return parts.joined(separator: " · ")
    }

    /// Reads the text in utility shots and screenshots and keeps the ones
    /// that are documents. Cached per photo.
    private func findDocuments(_ photos: [Photo], _ lookup: [String: Item], useModel: Bool) async throws -> [String: Insight.Document] {
        struct Cached: Codable { var document: Insight.Document? }
        let store = try Store()
        let candidates = photos.filter { $0.analysis.isUtility || $0.isScreenshot }
        var found: [String: Insight.Document] = [:]
        var pending: [(Photo, Item)] = []
        for photo in candidates {
            guard let item = lookup[photo.id] else { continue }
            if let cached = store.extra(Cached.self, id: photo.id, field: "document", modified: item.modified) {
                if let doc = cached.document { found[photo.id] = doc }
            } else {
                pending.append((photo, item))
            }
        }
        guard !pending.isEmpty else {
            board.finish(2, detail: found.isEmpty ? "none" : "\(found.count) documents")
            return found
        }
        board.start(2, total: pending.count)
        let fetch = fetchPolicy
        for (n, (photo, item)) in pending.enumerated() {
            if let image = await item.image(maxSide: 1600, fetch: fetch) {
                let doc = await Insight.document(image, isScreenshot: photo.isScreenshot, useModel: useModel)
                if let doc { found[photo.id] = doc }
                // Without the model the reading is rougher; don't keep it as final.
                if useModel { try store.saveExtra(Cached(document: doc), id: photo.id, field: "document", modified: item.modified) }
            }
            board.advance(2, done: n + 1)
        }
        let kinds = Dictionary(grouping: found.values, by: \.kind).map { "\($0.value.count) \($0.key.lowercased())" }.sorted()
        board.finish(2, detail: found.isEmpty ? "none" : "\(found.count) documents (\(kinds.prefix(3).joined(separator: ", ")))")
        return found
    }

    struct Described: Codable {
        var summary: String?
        var tags: [String]
    }

    /// A one-line description (Apple's model) and scene tags (Vision) for
    /// each grouped photo. Cached per photo.
    private func describe(_ photos: [Photo], _ lookup: [String: Item], useModel: Bool) async throws -> [String: Described] {
        let store = try Store()
        var result: [String: Described] = [:]
        var pending: [(Photo, Item)] = []
        for photo in photos {
            guard let item = lookup[photo.id] else { continue }
            if let cached = store.extra(Described.self, id: photo.id, field: "described", modified: item.modified),
               cached.summary != nil || !useModel {
                result[photo.id] = cached
            } else {
                pending.append((photo, item))
            }
        }
        guard !pending.isEmpty else {
            board.finish(6, detail: photos.isEmpty ? "nothing to describe" : "\(photos.count) photos, already described")
            return result
        }
        board.start(6, total: pending.count)
        let fetch = fetchPolicy
        for (n, (photo, item)) in pending.enumerated() {
            if let image = await item.image(maxSide: 768, fetch: fetch) {
                let described = Described(summary: useModel ? await Insight.describe(image) : nil,
                                          tags: await Insight.sceneTags(image))
                result[photo.id] = described
                try store.saveExtra(described, id: photo.id, field: "described", modified: item.modified)
            }
            board.advance(6, done: n + 1)
        }
        board.finish(6, detail: useModel ? "\(pending.count) photos described" : "\(pending.count) photos tagged (no Apple Intelligence)")
        return result
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
            board.finish(4, detail: photos.isEmpty ? "nothing to score" : "\(photos.count) photos, already scored")
            return result
        }

        board.start(4, total: pending.count)
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
                board.advance(4, done: done)
                add()
            }
        }
        board.finish(4, detail: "\(pending.count) photos" + (small > 0 ? ", \(small) from small previews (iCloud)" : ""))
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
            board.finish(5, detail: problems.isEmpty ? "no problems spotted" : "\(problems.count) look like rejects")
            return problems
        }

        board.start(5, total: pending.count)
        let fetch = fetchPolicy
        for (n, (photo, item)) in pending.enumerated() {
            if let image = await item.image(maxSide: 768, fetch: fetch) {
                let reason = await Inspector.inspect(image, analysis: photo.analysis, useModel: useModel)
                if let reason { problems[photo.id] = reason }
                // Without the model the check is rougher; don't keep it as final.
                if useModel { try store.saveSuggestion(reason, id: photo.id, modified: item.modified) }
            }
            board.advance(5, done: n + 1)
        }
        let kinds = Set(problems.values).sorted().joined(separator: ", ")
        board.finish(5, detail: problems.isEmpty ? "no problems spotted" : "\(problems.count) look like rejects (\(kinds))")
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
        let entries = (try? decoder.decode([Entry].self, from: data)) ?? []
        // One entry per place, even for entries saved before folder paths
        // were spelled one way.
        var seen = Set<Source>()
        return entries.compactMap { entry in
            var entry = entry
            if case .folder(let path) = entry.source { entry.source = .folder(URL(fileURLWithPath: path)) }
            return seen.insert(entry.source).inserted ? entry : nil
        }
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
