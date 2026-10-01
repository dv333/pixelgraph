import Foundation

/// Moves photos to Duplicates or PGDocuments, and back.
///
/// Apple Photos: into the "PixelGraph Duplicates" album and out of the album
/// that was scanned; nothing leaves the library. Folders and drives: into a
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
            try await Library.move(ids, to: target.album, from: id)
        case .dates:
            try await Library.move(ids, to: target.album, from: nil)
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

    /// Undoes the most recent move (all of it, if it went to two places).
    /// Returns the photo ids put back, or nil when there's nothing to undo.
    @discardableResult
    static func undoLast() async throws -> (source: Source, ids: [String])? {
        var records = history()
        guard let last = records.last else { return nil }
        var undone: [String] = []
        while let record = records.last, record.batch == last.batch, record.batch != nil || record.date == last.date {
            records.removeLast()
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
        return (last.source, undone)
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
