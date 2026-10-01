import Foundation
import SQLite3

/// Where PixelGraph keeps its index, last run and report.
enum Paths {
    static let root: URL = {
        // A separate data folder, for tests and trying things out.
        if let custom = ProcessInfo.processInfo.environment["PIXELGRAPH_HOME"] {
            let url = URL(fileURLWithPath: custom, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = support.appendingPathComponent("PixelGraph", isDirectory: true)
        // Carry over the index from when this tool was called cull.
        let old = support.appendingPathComponent("Cull", isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path), FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.moveItem(at: old, to: url)
        }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    static let index = root.appendingPathComponent("index.sqlite")
    static let lastRun = root.appendingPathComponent("last-run.json")
    static let report = root.appendingPathComponent("report", isDirectory: true)
    /// The nightly run's own scan and previews, apart from the one you review.
    static let nightly = root.appendingPathComponent("nightly", isDirectory: true)
    static var nightlyRun: URL { nightly.appendingPathComponent("last-run.json") }
    static var nightlyReport: URL { nightly.appendingPathComponent("report", isDirectory: true) }
}

/// SQLite cache of Vision results, keyed by Photos' local identifier.
/// A row is reused while the photo's modification date and the analyzer
/// version are unchanged, so a 100k library is only analysed once.
///
/// Two tables: `photos` holds the scan of every photo from local previews;
/// `detail` holds the sharper re-scoring of grouped photos at 1024px, which
/// may have needed an iCloud download.
final class Store {
    enum Table: String { case photos, detail }

    private var db: OpaquePointer?

    init(url: URL = Paths.index) throws {
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw StoreError(db) }
        try exec("PRAGMA journal_mode = WAL")
        for table in [Table.photos, .detail] {
            try exec("""
            CREATE TABLE IF NOT EXISTS \(table.rawValue) (
                id TEXT PRIMARY KEY,
                modified REAL NOT NULL,
                version INTEGER NOT NULL,
                vector BLOB NOT NULL,
                aesthetic REAL NOT NULL,
                utility INTEGER NOT NULL,
                sharpness REAL NOT NULL,
                faces INTEGER NOT NULL,
                face_quality REAL NOT NULL,
                preview_side INTEGER NOT NULL,
                eyes REAL NOT NULL DEFAULT -1
            )
            """)
            // Indexes made before eye measurements: add the column (old rows are
            // recomputed anyway because the analyzer version changed).
            try? exec("ALTER TABLE \(table.rawValue) ADD COLUMN eyes REAL NOT NULL DEFAULT -1")
        }
        try exec("""
            CREATE TABLE IF NOT EXISTS extras (
                id TEXT NOT NULL,
                field TEXT NOT NULL,
                modified REAL NOT NULL,
                version INTEGER NOT NULL,
                value TEXT NOT NULL,
                PRIMARY KEY (id, field)
            )
            """)
        try exec("""
            CREATE TABLE IF NOT EXISTS suggestions (
                id TEXT PRIMARY KEY,
                modified REAL NOT NULL,
                version INTEGER NOT NULL,
                reason TEXT NOT NULL
            )
            """)
    }

    deinit { sqlite3_close(db) }

    func analysis(id: String, modified: Date, in table: Table = .photos) -> Analysis? {
        let sql = "SELECT vector, aesthetic, utility, sharpness, faces, face_quality, preview_side, eyes FROM \(table.rawValue) WHERE id = ? AND modified = ? AND version = ?"
        guard let statement = prepare(sql) else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(statement, 2, modified.timeIntervalSince1970)
        sqlite3_bind_int(statement, 3, Int32(Analyzer.version))
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }

        let bytes = Int(sqlite3_column_bytes(statement, 0))
        var vector = [Float](repeating: 0, count: bytes / MemoryLayout<Float>.size)
        if let blob = sqlite3_column_blob(statement, 0) {
            vector.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(start: blob, count: bytes)) }
        }
        return Analysis(
            vector: vector,
            aesthetic: Float(sqlite3_column_double(statement, 1)),
            isUtility: sqlite3_column_int(statement, 2) != 0,
            sharpness: Float(sqlite3_column_double(statement, 3)),
            faceCount: Int(sqlite3_column_int(statement, 4)),
            faceQuality: Float(sqlite3_column_double(statement, 5)),
            eyesOpen: Float(sqlite3_column_double(statement, 7)),
            previewSide: Int(sqlite3_column_int(statement, 6))
        )
    }

    func save(_ analysis: Analysis, id: String, modified: Date, in table: Table = .photos) throws {
        let sql = "INSERT OR REPLACE INTO \(table.rawValue) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
        guard let statement = prepare(sql) else { throw StoreError(db) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(statement, 2, modified.timeIntervalSince1970)
        sqlite3_bind_int(statement, 3, Int32(Analyzer.version))
        analysis.vector.withUnsafeBytes {
            _ = sqlite3_bind_blob(statement, 4, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT)
        }
        sqlite3_bind_double(statement, 5, Double(analysis.aesthetic))
        sqlite3_bind_int(statement, 6, analysis.isUtility ? 1 : 0)
        sqlite3_bind_double(statement, 7, Double(analysis.sharpness))
        sqlite3_bind_int(statement, 8, Int32(analysis.faceCount))
        sqlite3_bind_double(statement, 9, Double(analysis.faceQuality))
        sqlite3_bind_int(statement, 10, Int32(analysis.previewSide))
        sqlite3_bind_double(statement, 11, Double(analysis.eyesOpen))
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError(db) }
    }

    /// A cached inspection: `.some(nil)` means the photo looked fine,
    /// `nil` means it hasn't been inspected (or has changed since).
    func suggestion(id: String, modified: Date) -> String?? {
        let sql = "SELECT reason FROM suggestions WHERE id = ? AND modified = ? AND version = ?"
        guard let statement = prepare(sql) else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(statement, 2, modified.timeIntervalSince1970)
        sqlite3_bind_int(statement, 3, Int32(Inspector.version))
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let reason = String(cString: sqlite3_column_text(statement, 0))
        return .some(reason.isEmpty ? nil : reason)
    }

    func saveSuggestion(_ reason: String?, id: String, modified: Date) throws {
        guard let statement = prepare("INSERT OR REPLACE INTO suggestions VALUES (?, ?, ?, ?)") else { throw StoreError(db) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(statement, 2, modified.timeIntervalSince1970)
        sqlite3_bind_int(statement, 3, Int32(Inspector.version))
        sqlite3_bind_text(statement, 4, reason ?? "", -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError(db) }
    }

    /// A cached JSON value for one photo (its document reading, description
    /// or tags). Nil when missing, or when the photo or the analysis changed.
    func extra<T: Decodable>(_ type: T.Type, id: String, field: String, modified: Date, version: Int = Insight.version) -> T? {
        guard let statement = prepare("SELECT value FROM extras WHERE id = ? AND field = ? AND modified = ? AND version = ?") else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, field, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(statement, 3, modified.timeIntervalSince1970)
        sqlite3_bind_int(statement, 4, Int32(version))
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let json = Data(String(cString: sqlite3_column_text(statement, 0)).utf8)
        return try? JSONDecoder().decode(T.self, from: json)
    }

    func saveExtra<T: Encodable>(_ value: T, id: String, field: String, modified: Date, version: Int = Insight.version) throws {
        guard let statement = prepare("INSERT OR REPLACE INTO extras VALUES (?, ?, ?, ?, ?)") else { throw StoreError(db) }
        defer { sqlite3_finalize(statement) }
        let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        sqlite3_bind_text(statement, 1, id, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, field, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(statement, 3, modified.timeIntervalSince1970)
        sqlite3_bind_int(statement, 4, Int32(version))
        sqlite3_bind_text(statement, 5, json, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError(db) }
    }

    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN")
        do { try body(); try exec("COMMIT") } catch { try? exec("ROLLBACK"); throw error }
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError(db) }
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        var statement: OpaquePointer?
        return sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK ? statement : nil
    }
}

struct StoreError: LocalizedError {
    let message: String
    init(_ db: OpaquePointer?) { message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open index" }
    var errorDescription: String? { "Index error: \(message)" }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
