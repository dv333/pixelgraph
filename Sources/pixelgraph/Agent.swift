import CoreGraphics
import Foundation
import ImageIO

/// What assistants and the nightly run can do without the review screen:
/// scan, read the groups, look at photos, change a pick, move, undo.
enum Agent {
    /// The scan to work on: the one you review in the terminal, or the
    /// nightly one, kept apart so it never overwrites a review in progress.
    enum Workspace: String {
        case main, nightly

        var runFile: URL { self == .main ? Paths.lastRun : Paths.nightlyRun }
        var reportFolder: URL { self == .main ? Paths.report : Paths.nightlyReport }

        init(_ value: Any?) throws {
            guard let text = value as? String else { self = .main; return }
            guard let workspace = Workspace(rawValue: text) else { throw Failure("Workspace is “main” or “nightly”, not “\(text)”.") }
            self = workspace
        }
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    // MARK: - Scanning

    /// A source from an assistant's words: an album name, a list of months
    /// ("2024-01"), a from/to range, or a folder path.
    static func source(album: String?, months: [String]?, from: String?, to: String?, folder: String?) throws -> Source {
        if let folder {
            let path = (folder as NSString).expandingTildeInPath
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue
            else { throw Failure("No folder at \(path).") }
            return .folder(URL(fileURLWithPath: path))
        }
        if let album {
            guard let found = Library.album(named: album) else { throw PixelGraphError.albumNotFound(album) }
            return .album(id: found.localIdentifier, title: album)
        }
        if let months, !months.isEmpty {
            let starts = try months.map { text -> Date in
                guard let date = try DateArgument.parse(text, end: false) else { throw Failure("Can't read month “\(text)”.") }
                return date
            }
            return Source.selection(of: starts)
        }
        return .dates(from: try DateArgument.parse(from, end: false), to: try DateArgument.parse(to, end: true))
    }

    static func scan(_ source: Source, into workspace: Workspace, quiet: Bool) async throws -> Run {
        var options = Scanner.Options()
        options.describe = false
        options.runFile = workspace.runFile
        options.reportFolder = workspace.reportFolder
        try FileManager.default.createDirectory(at: workspace.reportFolder.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try await Scanner(source: source, options: options, quiet: quiet).run()
    }

    static func summary(_ run: Run) -> [String: Any] {
        let pending = run.groups.indices.filter { i in run.groups[i].photos.contains { run.groups[i].pick.willMove($0.id) } }
        return [
            "scope": run.scope,
            "photos_scanned": run.scanned,
            "groups": run.groups.count,
            "groups_with_photos_to_move": pending.count,
            "photos_selected_to_move": run.toMove.count,
            "junk_groups": (run.junkGroups ?? []).count,
            "documents": (run.documentGroups ?? []).reduce(0) { $0 + $1.photos.count },
        ]
    }

    // MARK: - Groups

    /// Where a group id ("g3": lookalikes, "j1": junk) points.
    struct Place {
        let junk: Bool
        let index: Int
        var id: String { (junk ? "j" : "g") + String(index + 1) }
    }

    static func place(_ id: String, in run: Run) throws -> Place {
        guard let tab = id.lowercased().first, let n = Int(id.dropFirst()), n >= 1 else {
            throw Failure("No group “\(id)”. Group ids look like g3 or j1.")
        }
        if tab == "g", n <= run.groups.count { return Place(junk: false, index: n - 1) }
        if tab == "j", n <= (run.junkGroups ?? []).count { return Place(junk: true, index: n - 1) }
        throw Failure("No group “\(id)” in this scan.")
    }

    static func group(_ run: Run, _ place: Place) -> Run.Group {
        place.junk ? run.junkGroups![place.index] : run.groups[place.index]
    }

    static func update(_ run: inout Run, _ place: Place, _ group: Run.Group) {
        if place.junk { run.junkGroups![place.index] = group } else { run.groups[place.index] = group }
    }

    /// Photos in a group are lettered A, B, C… in the order the scan found them.
    static func letter(_ i: Int) -> String { i < 26 ? String(Character(UnicodeScalar(UInt8(65 + i)))) : "P\(i + 1)" }

    static func photoIndex(_ letter: String, in group: Run.Group) throws -> Int {
        let wanted = letter.uppercased()
        guard let i = group.photos.indices.first(where: { self.letter($0) == wanted }) else {
            throw Failure("No photo “\(letter)” in this group; it has \(self.letter(0))–\(self.letter(group.photos.count - 1)).")
        }
        return i
    }

    static func places(_ run: Run, pendingOnly: Bool) -> [Place] {
        let all = run.groups.indices.map { Place(junk: false, index: $0) }
            + (run.junkGroups ?? []).indices.map { Place(junk: true, index: $0) }
        guard pendingOnly else { return all }
        return all.filter { p in let g = group(run, p); return g.photos.contains { g.pick.willMove($0.id) } }
    }

    /// One group as an assistant reads it.
    static func describe(_ group: Run.Group, place: Place) -> [String: Any] {
        let scores = Picker.score(Picker.raws(group.photos), weights: .current())
        let photos: [[String: Any]] = group.photos.enumerated().map { i, member in
            let pick = group.pick
            let state = pick.moved.contains(member.id) ? "moved"
                : pick.keepers.contains(member.id) ? "best"
                : pick.kept.contains(member.id) ? "keep" : "move"
            var photo: [String: Any] = [
                "photo": letter(i),
                "taken": member.date.formatted(.iso8601),
                "state": state,
                "size": "\(member.width)×\(member.height)",
                "score": Int((scores[i].total * 100).rounded()),
            ]
            if let note = pick.notes[member.id] { photo["note"] = note }
            if let flag = pick.suggestions[member.id] { photo["flag"] = flag }
            if let reason = pick.reasons[member.id] { photo["your_reason"] = reason }
            if let tags = member.tags, !tags.isEmpty { photo["tags"] = tags }
            if let document = member.document { photo["document"] = document }
            return photo
        }
        return [
            "group": place.id,
            "kind": group.kind.title,
            "decided_by": group.pick.decidedBy,
            "clear_case": !clearMoves(group).isEmpty,
            "photos": photos,
        ]
    }

    /// Changes who's kept: `best` becomes the one ★, `keep` are kept too,
    /// `move` go. Assistants' choices aren't learned from; only yours are.
    static func setPick(_ run: inout Run, _ place: Place, best: String?, keep: [String], move: [String], reason: String?) throws {
        var g = group(run, place)
        if let best {
            let id = g.photos[try photoIndex(best, in: g)].id
            guard !g.pick.moved.contains(id) else { throw Failure("Photo \(best) has already been moved.") }
            g.pick.keepers = [id]
            g.pick.best = id
            g.pick.kept.removeAll { $0 == id }
            g.pick.reasons[id] = nil
            g.pick.decidedBy = "assistant"
        }
        for letter in keep {
            let id = g.photos[try photoIndex(letter, in: g)].id
            if !g.pick.isKept(id) { g.pick.kept.append(id) }
            g.pick.reasons[id] = nil
        }
        for letter in move {
            let id = g.photos[try photoIndex(letter, in: g)].id
            g.pick.keepers.removeAll { $0 == id }
            g.pick.kept.removeAll { $0 == id }
            if let reason { g.pick.reasons[id] = reason }
        }
        if let first = g.pick.keepers.first { g.pick.best = first }
        update(&run, place, g)
    }

    // MARK: - Moving

    /// The photos the nightly run may move on its own: every extra copy of a
    /// re-save or resize, and in a burst only the shots well behind the best
    /// (or flagged: eyes closed, blurry…) when the best itself is clean.
    /// Never the same scene revisited on another day, junk, or documents.
    static func clearMoves(_ group: Run.Group) -> [String] {
        let pick = group.pick
        let automatic: [Run.Group.Kind] = [.copies, .moment, .screenshots]
        guard automatic.contains(group.kind), pick.suggestions[pick.best] == nil,
              let best = group.photos.firstIndex(where: { $0.id == pick.best }) else { return [] }
        let waiting = group.photos.indices.filter { pick.willMove(group.photos[$0].id) }
        if group.kind == .copies { return waiting.map { group.photos[$0].id } }
        // A close call settled by Apple's model isn't clear.
        guard pick.decidedBy == "vision" else { return [] }
        let scores = Picker.score(Picker.raws(group.photos), weights: .current())
        return waiting.filter { i in
            scores[best].total - scores[i].total >= 0.12 || pick.suggestions[group.photos[i].id] != nil
        }.map { group.photos[$0].id }
    }

    struct Moved {
        var photos = 0
        var groups: [String] = []
        var preview: [[String: Any]] = []
    }

    /// Moves what's selected in the given groups (all with something
    /// selected when nil): to PGDuplicates, or with `trash` to Recently
    /// Deleted / the Trash. `only` narrows each group to the clear cases.
    static func move(_ workspace: Workspace, groups groupIDs: [String]?, to destination: Mover.Destination,
                     dryRun: Bool, clearOnly: Bool = false, limit: Int = .max) async throws -> Moved {
        var run = try Run.load(from: workspace.runFile)
        guard let source = run.source else { throw Failure("This scan is too old to move from; scan again.") }
        var chosen = places(run, pendingOnly: true)
        if let groupIDs { chosen = try groupIDs.map { id in try place(id, in: run) } }
        var result = Moved()
        var ids: [String] = []
        for p in chosen {
            let g = group(run, p)
            var moving = clearOnly ? clearMoves(g) : g.photos.map(\.id).filter { g.pick.willMove($0) }
            moving = Array(moving.prefix(max(0, limit - ids.count)))
            guard !moving.isEmpty else { continue }
            ids += moving
            result.groups.append(p.id)
            result.preview.append(["group": p.id, "photos": g.photos.indices.filter { moving.contains(g.photos[$0].id) }.map(letter)])
        }
        result.photos = ids.count
        guard !dryRun, !ids.isEmpty else { return result }
        if source.isPhotos { try await Library.requestAccess() }
        _ = try await Mover.move(ids, from: source, to: destination, batch: UUID())
        run.markMoved(ids)
        try run.save(to: workspace.runFile)
        return result
    }

    /// Undoes the last move, wherever it was made, and updates both scans.
    static func undo() async throws -> String {
        guard let last = Mover.history().last else { return "Nothing to undo." }
        if last.source.isPhotos { try await Library.requestAccess() }
        guard let undone = try await Mover.undoLast() else { return "Nothing to undo." }
        for workspace in [Workspace.main, .nightly] {
            if var run = try? Run.load(from: workspace.runFile), run.source == undone.source {
                run.unmark(undone.ids)
                run.markCaptioned(undone.captioned, false)
                try? run.save(to: workspace.runFile)
            }
        }
        var parts = ["Put back \(undone.ids.count) photos in \(undone.source)."]
        if !undone.deleted.isEmpty { parts.append("\(undone.deleted.count) were deleted; recover them in Photos → Recently Deleted.") }
        return parts.joined(separator: " ")
    }

    // MARK: - Photos for assistants

    /// Small JPEGs of a group's photos, lettered, for an assistant to look at.
    static func thumbnails(_ workspace: Workspace, _ place: Place, letters: [String]?, maxSide: Int = 512) throws -> [(String, Data)] {
        let run = try Run.load(from: workspace.runFile)
        let g = group(run, place)
        let images = try Report.manifest(in: workspace.reportFolder)
        var indices = Array(g.photos.indices.prefix(8))
        if let letters { indices = try letters.map { name in try photoIndex(name, in: g) } }
        return indices.compactMap { i in
            guard let file = images[g.photos[i].id]?.thumb,
                  let data = jpeg(workspace.reportFolder.appendingPathComponent(file), maxSide: maxSide) else { return nil }
            return (letter(i), data)
        }
    }

    private static func jpeg(_ url: URL, maxSide: Int) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxSide,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary)
        else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    // MARK: - Nightly log

    static var nightlyLog: URL { Paths.nightly.appendingPathComponent("log.json") }

    static func writeNightlyLog(_ entry: [String: Any]) {
        var entries = (try? Data(contentsOf: nightlyLog)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
        entries.append(entry)
        if let data = try? JSONSerialization.data(withJSONObject: Array(entries.suffix(60)), options: [.prettyPrinted]) {
            try? FileManager.default.createDirectory(at: Paths.nightly, withIntermediateDirectories: true)
            try? data.write(to: nightlyLog, options: .atomic)
        }
    }

    static func lastNightly() -> [String: Any]? {
        (try? Data(contentsOf: nightlyLog)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] }?.last
    }

    static func json(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        else { return "\(object)" }
        return String(decoding: data, as: UTF8.self)
    }
}
