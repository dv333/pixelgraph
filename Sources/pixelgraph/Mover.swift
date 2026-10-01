import Foundation

/// Moves photos to Duplicates or PGDocuments, and back.
///
/// Apple Photos: into the "PixelGraph Duplicates" album and out of the album
/// that was scanned. Duplicates from a library scan (no album to take them
/// out of) are also deleted, to Recently Deleted. Folders and drives: into a
/// "PixelGraph Duplicates" folder inside the scanned folder, keeping the
/// layout, with RAW twins and sidecars alongside. Every move is logged so the
/// last one can be undone.
enum Mover {
    enum Destination: String, Codable {
        case duplicates, documents

        var album: String { self == .duplicates ? Library.duplicatesAlbum : Library.documentsAlbum }
        var folder: String { self == .duplicates ? Files.duplicatesFolder : Files.documentsFolder }
    }

    struct Record: Codable {
        var date: Date
        var source: Source
        /// Nil in records from before PGDocuments existed: Duplicates.
        var destination: Destination?
        /// Moves made together (documents and their copies) share a batch and undo together.
        var batch: UUID?
        /// Photo ids as they were before the move.
        var ids: [String]
        /// For folders: where each file went.
        var files: [FileMove]
        /// Deleted from the library (to Recently Deleted), so undo can't put them back.
        var deleted: Bool?
        /// Still in the scanned album, because it can't be changed.
        var leftInSource: Bool?
        /// Captions written to the photos kept, with what they had before.
        var captions: [Captions.Change]?
    }

    struct FileMove: Codable {
        var from: String
        var to: String
    }

    static var log: URL { Paths.root.appendingPathComponent("moves.json") }

    static func move(_ ids: [String], from source: Source, to target: Destination = .duplicates,
                     batch: UUID = UUID()) async throws -> Record {
        var record = Record(date: .now, source: source, destination: target, batch: batch, ids: ids, files: [])
        switch source {
        case .album(let id, _):
            let removed = try await Library.move(ids, to: target.album, from: id)
            if !removed { record.leftInSource = true }
        case .dates:
            // Documents are the copies being kept, so only duplicates are deleted.
            let delete = target == .duplicates
            try await Library.move(ids, to: target.album, from: nil, delete: delete)
            if delete { record.deleted = true }
        case .folder(let path):
            // Resolve symlinks (/var → /private/var) so paths line up.
            let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            let destination = root.appendingPathComponent(target.folder, isDirectory: true)
            for id in ids where id.hasPrefix("file:") {
                let file = URL(fileURLWithPath: String(id.dropFirst(5))).resolvingSymlinksInPath()
                for url in [file] + Files.companions(of: file).map({ $0.resolvingSymlinksInPath() }) {
                    let relative = url.path.hasPrefix(root.path + "/") ? String(url.path.dropFirst(root.path.count + 1)) : url.lastPathComponent
                    let target = uniqueURL(destination.appendingPathComponent(relative))
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: url, to: target)
                    record.files.append(FileMove(from: url.path, to: target.path))
                }
            }
        }
        var records = history()
        records.append(record)
        try save(records)
        return record
    }

    /// Logs captions written alongside a move, so undoing it puts the old ones back.
    static func logCaptions(_ changes: [Captions.Change], source: Source, batch: UUID) throws {
        guard !changes.isEmpty else { return }
        var records = history()
        records.append(Record(date: .now, source: source, destination: nil, batch: batch, ids: [], files: [], captions: changes))
        try save(records)
    }

    /// Undoes the most recent move (all of it, if it went to two places),
    /// and the captions written with it. Returns the photo ids put back,
    /// those that were deleted, which only Photos can recover, and those
    /// whose captions were restored; nil when there's nothing to undo.
    @discardableResult
    static func undoLast() async throws -> (source: Source, ids: [String], deleted: [String], captioned: [String])? {
        var records = history()
        guard let last = records.last else { return nil }
        var undone: [String] = []
        var deleted: [String] = []
        var captioned: [String] = []
        while let record = records.last, record.batch == last.batch, record.batch != nil || record.date == last.date {
            records.removeLast()
            if let captions = record.captions {
                try await Captions.restore(captions)
                captioned += captions.map(\.id)
                try save(records)
                continue
            }
            if record.deleted == true {
                deleted += record.ids
                try save(records)
                continue
            }
            let destination = record.destination ?? .duplicates
            switch record.source {
            case .album(let id, _): try await Library.restore(record.ids, from: destination.album, to: id)
            case .dates: try await Library.restore(record.ids, from: destination.album, to: nil)
            case .folder:
                for move in record.files.reversed() {
                    let back = URL(fileURLWithPath: move.from)
                    try FileManager.default.createDirectory(at: back.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: URL(fileURLWithPath: move.to), to: back)
                    removeEmptyFolders(from: URL(fileURLWithPath: move.to).deletingLastPathComponent())
                }
            }
            undone += record.ids
            try save(records)
        }
        return (last.source, undone, deleted, captioned)
    }

    static func history() -> [Record] {
        guard let data = try? Data(contentsOf: log) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Record].self, from: data)) ?? []
    }

    private static func save(_ records: [Record]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        try encoder.encode(records.suffix(50)).write(to: log, options: .atomic)
    }

    /// `url`, or `url` with " 2", " 3"… added when something is already there.
    private static func uniqueURL(_ url: URL) -> URL {
        var candidate = url
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = url.deletingPathExtension().lastPathComponent + " \(n)"
            candidate = url.deletingLastPathComponent().appendingPathComponent(name).appendingPathExtension(url.pathExtension)
            n += 1
        }
        return candidate
    }

    /// Tidies up folders left empty under "PixelGraph Duplicates" after an undo.
    private static func removeEmptyFolders(from folder: URL) {
        var current = folder
        while current.path.contains("/\(Files.duplicatesFolder)") || current.path.contains("/\(Files.documentsFolder)"),
              let contents = try? FileManager.default.contentsOfDirectory(atPath: current.path),
              contents.filter({ $0 != ".DS_Store" }).isEmpty {
            try? FileManager.default.removeItem(at: current)
            current = current.deletingLastPathComponent()
        }
    }
}
