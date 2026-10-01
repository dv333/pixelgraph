import Foundation
import SQLite3

extension Paths {
    /// What PixelGraph remembers for you: settings, recent scans, pinned
    /// folders, where you were, and how far each place has got. Apart from
    /// index.sqlite, which is only a cache and safe to delete.
    static var database: URL { root.appendingPathComponent("pixelgraph.db") }
}

/// How far a folder, album or month has got, and when.
struct PlaceStatus: Sendable {
    enum Step: String, Sendable { case scanned, opened, reviewed, moved }
    var step: Step
    var date: Date
    /// Photos moved (or deleted) from it, all told.
    var moved: Int

    /// "reviewed · 12 Sep", "moved 34 · 12 Sep".
    var text: String {
        let what = step == .moved ? "moved \(moved)" : step.rawValue
        let sameYear = Calendar.current.isDate(date, equalTo: .now, toGranularity: .year)
        let when = sameYear ? date.formatted(.dateTime.day().month(.abbreviated))
            : date.formatted(.dateTime.day().month(.abbreviated).year())
        return "\(what) · \(when)"
    }
}

/// pixelgraph.db. Opened for each use: it's small and each read is quick.
final class Database {
    private var db: OpaquePointer?

    /// Nil when the file can't be opened; callers carry on with defaults.
    static func open() -> Database? { try? Database() }

    init(url: URL = Paths.database) throws {
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw StoreError(db) }
        sqlite3_busy_timeout(db, 2_000)
        try exec("PRAGMA journal_mode = WAL")
        try exec("CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        try exec("""
            CREATE TABLE IF NOT EXISTS recents (
                place TEXT PRIMARY KEY, source TEXT NOT NULL, date REAL NOT NULL,
                photos INTEGER NOT NULL, groups INTEGER NOT NULL)
            """)
        try exec("""
            CREATE TABLE IF NOT EXISTS progress (
                place TEXT PRIMARY KEY, step TEXT NOT NULL, date REAL NOT NULL, moved INTEGER NOT NULL DEFAULT 0)
            """)
        try exec("CREATE TABLE IF NOT EXISTS pins (path TEXT PRIMARY KEY, date REAL NOT NULL)")
        try exec("CREATE TABLE IF NOT EXISTS state (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        if state("migrated") == nil { migrate() }
    }

    deinit { sqlite3_close(db) }

    // MARK: Settings

    func settings() -> [String: String] {
        Dictionary(query("SELECT key, value FROM settings") { ($0.text(0), $0.text(1)) }, uniquingKeysWith: { _, last in last })
    }

    /// nil puts the default back.
    func setSetting(_ key: String, _ value: String?) {
        if let value {
            run("INSERT OR REPLACE INTO settings VALUES (?, ?)", key, value)
        } else {
            run("DELETE FROM settings WHERE key = ?", key)
        }
    }

    func resetSettings() { run("DELETE FROM settings") }

    // MARK: Recent scans

    func recents() -> [Recents.Entry] {
        let decoder = JSONDecoder()
        return query("SELECT source, date, photos, groups FROM recents ORDER BY date DESC") { row -> Recents.Entry? in
            guard let source = try? decoder.decode(Source.self, from: Data(row.text(0).utf8)) else { return nil }
            return Recents.Entry(source: source, date: Date(timeIntervalSince1970: row.double(1)), photos: row.int(2), groups: row.int(3))
        }.compactMap { $0 }
    }

    func addRecent(_ entry: Recents.Entry) {
        guard let data = try? JSONEncoder().encode(entry.source) else { return }
        run("INSERT OR REPLACE INTO recents VALUES (?, ?, ?, ?, ?)", entry.source.key, String(decoding: data, as: UTF8.self),
            entry.date.timeIntervalSince1970, entry.photos, entry.groups)
        // Twelve is plenty for the home screen.
        run("DELETE FROM recents WHERE place NOT IN (SELECT place FROM recents ORDER BY date DESC LIMIT 12)")
    }

    // MARK: Progress

    func statuses() -> [String: PlaceStatus] {
        let rows = query("SELECT place, step, date, moved FROM progress") { row -> (String, PlaceStatus)? in
            guard let step = PlaceStatus.Step(rawValue: row.text(1)) else { return nil }
            return (row.text(0), PlaceStatus(step: step, date: Date(timeIntervalSince1970: row.double(2)), moved: row.int(3)))
        }
        return Dictionary(rows.compactMap { $0 }, uniquingKeysWith: { _, last in last })
    }

    /// The latest step wins; moves add up.
    func note(_ step: PlaceStatus.Step, places: [String], moved: Int = 0, date: Date = .now) {
        for place in places {
            run("""
                INSERT INTO progress VALUES (?, ?, ?, ?)
                ON CONFLICT(place) DO UPDATE SET step = excluded.step, date = excluded.date, moved = moved + excluded.moved
                """, place, step.rawValue, date.timeIntervalSince1970, moved)
        }
    }

    // MARK: Pinned folders

    func pins() -> [String] { query("SELECT path FROM pins ORDER BY date") { $0.text(0) } }

    func setPinned(_ path: String, _ pinned: Bool) {
        if pinned {
            run("INSERT OR REPLACE INTO pins VALUES (?, ?)", path, Date.now.timeIntervalSince1970)
        } else {
            run("DELETE FROM pins WHERE path = ?", path)
        }
    }

    // MARK: Where you were

    func state(_ key: String) -> String? { query("SELECT value FROM state WHERE key = ?", key) { $0.text(0) }.first }

    func setState(_ key: String, _ value: String?) {
        if let value {
            run("INSERT OR REPLACE INTO state VALUES (?, ?)", key, value)
        } else {
            run("DELETE FROM state WHERE key = ?", key)
        }
    }

    // MARK: Moving in

    /// Once: the recent scans from recent.json, and what they and past moves
    /// say about each place's progress, so the lists show it straight away.
    private func migrate() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = Paths.root.appendingPathComponent("recent.json")
        if let data = try? Data(contentsOf: file), let entries = try? decoder.decode([Recents.Entry].self, from: data) {
            for entry in entries.reversed() {
                var entry = entry
                if case .folder(let path) = entry.source { entry.source = .folder(URL(fileURLWithPath: path)) }
                addRecent(entry)
                note(.scanned, places: entry.source.places, date: entry.date)
            }
        }
        for record in Mover.history().sorted(by: { $0.date < $1.date }) where !record.ids.isEmpty {
            note(.moved, places: record.source.places, moved: record.ids.count, date: record.date)
        }
        setState("migrated", "1")
    }

    // MARK: SQLite

    struct Row {
        let statement: OpaquePointer
        func text(_ i: Int32) -> String { sqlite3_column_text(statement, i).map { String(cString: $0) } ?? "" }
        func double(_ i: Int32) -> Double { sqlite3_column_double(statement, i) }
        func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(statement, i)) }
    }

    private func query<T>(_ sql: String, _ values: Any?..., row: (Row) -> T) -> [T] {
        guard let statement = prepare(sql, values) else { return [] }
        defer { sqlite3_finalize(statement) }
        var result: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW { result.append(row(Row(statement: statement))) }
        return result
    }

    private func run(_ sql: String, _ values: Any?...) {
        guard let statement = prepare(sql, values) else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_step(statement)
    }

    private func prepare(_ sql: String, _ values: [Any?]) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        for (i, value) in values.enumerated() {
            let n = Int32(i + 1)
            switch value {
            case let text as String: sqlite3_bind_text(statement, n, text, -1, SQLITE_TRANSIENT_DB)
            case let number as Int: sqlite3_bind_int64(statement, n, Int64(number))
            case let number as Double: sqlite3_bind_double(statement, n, number)
            default: sqlite3_bind_null(statement, n)
            }
        }
        return statement
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError(db) }
    }
}

private let SQLITE_TRANSIENT_DB = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Recently scanned sources, for the home screen.
enum Recents {
    struct Entry: Codable {
        var source: Source
        var date: Date
        var photos: Int
        var groups: Int
    }

    static func all() -> [Entry] { Database.open()?.recents() ?? [] }

    static func record(_ run: Run) {
        guard let source = run.source else { return }
        Database.open()?.addRecent(Entry(source: source, date: run.date, photos: run.scanned, groups: run.groups.count))
    }
}

/// Notes how far places have got, from wherever it happens.
enum Places {
    static func note(_ step: PlaceStatus.Step, _ source: Source?, moved: Int = 0) {
        guard let source, !source.places.isEmpty else { return }
        Database.open()?.note(step, places: source.places, moved: moved)
    }
}

extension Source {
    /// One spelling per source, for the recents list.
    var key: String {
        switch self {
        case .album(let id, _): return "album:" + id
        case .folder(let path): return "folder:" + path
        case .dates(let from, let to):
            return "dates:\(Int(from?.timeIntervalSince1970 ?? 0))-\(Int(to?.timeIntervalSince1970 ?? 0))"
        case .months(let starts): return "months:" + starts.map { String(Int($0.timeIntervalSince1970)) }.joined(separator: ",")
        }
    }

    /// The places whose progress this source counts for: the folder or
    /// album, or each whole month in it. Open-ended date ranges count for none.
    var places: [String] {
        switch self {
        case .album(let id, _): return ["album:" + id]
        case .folder(let path): return ["folder:" + path]
        case .months(let starts): return starts.map(Self.monthPlace)
        case .dates(let from?, let to?):
            var places: [String] = []
            var month = Calendar.current.dateInterval(of: .month, for: from)?.start ?? from
            while month < to, places.count < 1_200 {
                places.append(Self.monthPlace(month))
                guard let next = Calendar.current.date(byAdding: .month, value: 1, to: month) else { break }
                month = next
            }
            return places
        case .dates: return []
        }
    }

    static func monthPlace(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: date)
        return String(format: "month:%04d-%02d", c.year ?? 0, c.month ?? 0)
    }
}
