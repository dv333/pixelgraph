import CryptoKit
import Foundation

/// Reviews in progress, one per place. The one being worked on lives where
/// it always has (last-run.json and report/), so `pixelgraph review`, the
/// report and assistants keep finding it. The others wait in reviews/, a
/// folder each, and swap back in when you go back to one. A new scan of
/// somewhere else sets the current review aside instead of replacing it;
/// a new scan of the same place starts that place's review over.
enum Reviews {
    /// A review set aside: enough to list it without reading the whole scan.
    struct Aside: Codable {
        var id: String
        var scope: String
        var source: Source
        /// When it was set aside, which is when it was last worked on.
        var date: Date
        var waiting: Int
        var reviewed: Int
        var groups: Int
    }

    static var folder: URL { Paths.root.appendingPathComponent("reviews", isDirectory: true) }

    /// One folder name per place.
    static func id(_ source: Source) -> String {
        SHA256.hash(data: Data(source.key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The reviews set aside, most recently worked on first.
    static func aside() -> [Aside] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return folders.compactMap { dir in
            (try? Data(contentsOf: dir.appendingPathComponent("summary.json"))).flatMap { try? decoder.decode(Aside.self, from: $0) }
        }.sorted { $0.date > $1.date }
    }

    /// Before a scan of `source` into the current review: the review of
    /// somewhere else is set aside, and one of this place waiting aside is
    /// dropped, since this scan starts it over.
    static func prepareScan(of source: Source) {
        if let current = try? Run.load(), current.source != source { try? setAsideCurrent() }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(id(source)))
    }

    /// Sets the current review aside when it still has something to do.
    /// A finished one isn't kept: the next scan simply takes its place.
    static func setAsideCurrent() throws {
        guard let run = try? Run.load(), let source = run.source, run.waiting > 0 else { return }
        let fm = FileManager.default
        let dir = folder.appendingPathComponent(id(source))
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try fm.moveItem(at: Paths.lastRun, to: dir.appendingPathComponent("last-run.json"))
        if fm.fileExists(atPath: Paths.report.path) { try fm.moveItem(at: Paths.report, to: dir.appendingPathComponent("report")) }
        try writeSummary(run, in: dir)
    }

    /// Brings a review set aside back to be worked on; the current one is
    /// set aside first.
    static func resume(_ id: String) throws {
        let fm = FileManager.default
        let dir = folder.appendingPathComponent(id)
        let file = dir.appendingPathComponent("last-run.json")
        guard fm.fileExists(atPath: file.path) else { throw PixelGraphError.noRun }
        try setAsideCurrent()
        try? fm.removeItem(at: Paths.lastRun)
        try? fm.removeItem(at: Paths.report)
        try fm.moveItem(at: file, to: Paths.lastRun)
        let report = dir.appendingPathComponent("report")
        if fm.fileExists(atPath: report.path) { try fm.moveItem(at: report, to: Paths.report) }
        try? fm.removeItem(at: dir)
    }

    /// Changes the review of `source` while it's set aside, e.g. after
    /// `pixelgraph undo` put its photos back. False when there's none.
    @discardableResult
    static func update(_ source: Source, _ change: (inout Run) -> Void) -> Bool {
        let dir = folder.appendingPathComponent(id(source))
        let file = dir.appendingPathComponent("last-run.json")
        guard var run = try? Run.load(from: file) else { return false }
        change(&run)
        do {
            try run.save(to: file)
            // It keeps its place in the list: when it was last worked on.
            try writeSummary(run, in: dir, date: aside().first { $0.id == id(source) }?.date ?? .now)
            return true
        } catch {
            return false
        }
    }

    private static func writeSummary(_ run: Run, in dir: URL, date: Date = .now) throws {
        guard let source = run.source else { return }
        let summary = Aside(id: id(source), scope: run.scope, source: source, date: date,
                            waiting: run.waiting, reviewed: run.reviewedGroups, groups: run.allGroups.count)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(summary).write(to: dir.appendingPathComponent("summary.json"), options: .atomic)
    }
}
