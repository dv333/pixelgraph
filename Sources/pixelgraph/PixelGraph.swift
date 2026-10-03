import AppKit
import ArgumentParser
import Foundation

@main
struct PixelGraph: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pixelgraph",
        abstract: "Find near-identical photos, keep the best, move the rest to Duplicates.",
        discussion: """
            Run `pixelgraph` on its own to choose what to scan. Works with Apple Photos \
            (including iCloud Photos), folders, external drives and iCloud Drive. \
            Nothing moves until you confirm, and every move can be undone.
            """,
        version: "0.2.0",
        subcommands: [Home.self, Scan.self, Review.self, ReportCommand.self, Undo.self, Albums.self, Eval.self,
                      MCPCommand.self, Auto.self, Schedule.self, Empty.self, SettingsCommand.self, DebugImages.self],
        defaultSubcommand: Home.self
    )
}

/// Shared tuning flags. Each defaults to its value in Settings
/// (`pixelgraph settings`); a flag given here wins for this run only.
struct ScanOptions: ParsableArguments {
    @Option(help: "Max fingerprint distance for shots taken close together (Settings: 0.5).")
    var momentThreshold: Float?

    @Option(help: "Seconds over which the moment threshold eases to the scene threshold (Settings: 600).")
    var momentWindow: Double?

    @Option(help: "Max fingerprint distance for shots any time apart: copies, same scene (Settings: 0.3).")
    var sceneThreshold: Float?

    @Flag(inversion: .prefixedNo, help: "Use Apple's on-device model for close calls, eyes and faces.")
    var model: Bool?

    @Flag(inversion: .prefixedNo, help: "Never download from iCloud; judge photos from the previews on this Mac.")
    var offline: Bool?

    @Flag(inversion: .prefixedNo, help: "Sort documents (receipts, forms, screenshots) for PGDocuments.")
    var documents: Bool?

    @Flag(inversion: .prefixedNo, help: "Tag scenes (beach, dog…) in the photos in groups.")
    var describe: Bool?

    @Flag(inversion: .prefixedNo, help: "Look for junk with no lookalike: accidental, blurry or crooked shots, old screenshots, forwards.")
    var junk: Bool?

    @Option(help: "Screenshots older than this many days count as junk (Settings: 30).")
    var screenshotDays: Int?

    /// Settings, with the flags given here on top.
    func scanner(_ settings: Settings = .load()) -> Scanner.Options {
        var options = settings.scanner
        if let momentThreshold { options.rules.momentThreshold = momentThreshold }
        if let momentWindow { options.rules.momentWindow = momentWindow }
        if let sceneThreshold { options.rules.sceneThreshold = sceneThreshold }
        if let model { options.useModel = model }
        if let offline { options.offline = offline }
        if let documents { options.documents = documents }
        if let describe { options.describe = describe }
        if let junk { options.junk = junk }
        if let screenshotDays { options.junkRules.screenshotDays = screenshotDays }
        return options
    }
}

// MARK: - home

struct Home: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "home", abstract: "Choose what to scan, then review it (the default).", shouldDisplay: false)

    @OptionGroup var options: ScanOptions

    @Flag(help: "Skip the opening title (also PIXELGRAPH_NO_INTRO=1, or turn it off in Settings).")
    var noIntro = false

    func run() async throws {
        guard isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0 else {
            throw ValidationError("Run pixelgraph in a terminal, or use `pixelgraph scan --album/--folder`.")
        }
        try await App(flags: options, intro: !noIntro && Settings.load().bool(.intro)).run()
    }
}

// MARK: - scan

struct Scan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Scan an album, date range or folder, then review it.")

    @Option(help: "Apple Photos album to scan (see `pixelgraph albums`).")
    var album: String?

    @Option(help: "Folder to scan: on this Mac, an external drive or iCloud Drive.")
    var folder: String?

    @Option(help: "Photos library from this date: 2024, 2024-06 or 2024-06-15.")
    var from: String?

    @Option(help: "Photos library up to this date, inclusive.")
    var to: String?

    @Flag(help: "Just scan; don't open the review afterwards.")
    var noReview = false

    @OptionGroup var options: ScanOptions

    func validate() throws {
        let chosen = [album != nil, folder != nil, from != nil || to != nil].filter { $0 }.count
        if chosen == 0 { throw ValidationError("Choose --album, --folder or --from/--to. Or run `pixelgraph` to pick.") }
        if chosen > 1 { throw ValidationError("Choose one of --album, --folder or --from/--to.") }
        _ = try DateArgument.parse(from, end: false)
        _ = try DateArgument.parse(to, end: true)
    }

    func run() async throws {
        let source: Source
        if let folder {
            let path = (folder as NSString).expandingTildeInPath
            source = .folder(URL(fileURLWithPath: path))
        } else {
            try await Library.requestAccess()
            if let album {
                guard let found = Library.album(named: album) else { throw PixelGraphError.albumNotFound(album) }
                source = .album(id: found.localIdentifier, title: album)
            } else {
                source = .dates(from: try DateArgument.parse(from, end: false), to: try DateArgument.parse(to, end: true))
            }
        }

        let scanner = Scanner(source: source, options: options.scanner())
        let stop = StopHandler { scanner.board.abandon() }
        let run = try await scanner.run()
        stop.cancel()

        if !noReview, isatty(STDIN_FILENO) != 0, !run.allGroups.isEmpty {
            try await ReviewSession(run: run).show()
        } else {
            print("\nReview with `pixelgraph review`, or open the report with `pixelgraph report`.")
        }
    }
}

// MARK: - review, report, undo, albums

struct Review: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Review the last scan: keep the best, move the rest.")

    @Option(help: "auto, iterm (sharp photos in iTerm2, WezTerm), kitty (kitty, Ghostty) or blocks (coloured blocks, any true-colour terminal). Default: Settings.")
    var graphics: TerminalImage.Mode?

    @Option(help: .hidden)
    var folder: String?

    @Flag(help: "Review the close calls the nightly clean-up left.")
    var nightly = false

    @Option(help: "Open straight on this group, e.g. g3 (lookalikes) or j1 (junk).")
    var group: String?

    func run() async throws {
        guard isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0 else {
            throw ValidationError("pixelgraph review needs an interactive terminal.")
        }
        var reportFolder = folder.map { URL(fileURLWithPath: $0) } ?? Paths.report
        var runFile = folder == nil ? Paths.lastRun : reportFolder.appendingPathComponent("last-run.json")
        if nightly {
            reportFolder = Paths.nightlyReport
            runFile = Paths.nightlyRun
        }
        let run = try Run.load(from: runFile)
        guard !run.allGroups.isEmpty else {
            print("The last scan found nothing to review: no lookalikes, junk or documents.")
            return
        }
        if run.source?.isPhotos ?? true, folder == nil { try await Library.requestAccess() }
        try await ReviewSession(run: run, runFile: runFile, folder: reportFolder, graphics: graphics ?? Settings.load().graphics, start: group).show()
    }
}

struct ReportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "report", abstract: "Open the last scan as a web page.")

    func run() async throws {
        let run = try Run.load()
        try Report.render(run, images: try Report.manifest(in: Paths.report), in: Paths.report)
        NSWorkspace.shared.open(Report.page)
        print(Report.page.path)
    }
}

struct Undo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Put back the photos from the last move.")

    func run() async throws {
        guard let last = Mover.history().last else {
            print("Nothing to undo.")
            return
        }
        if last.source.isPhotos { try await Library.requestAccess() }
        guard let record = try await Mover.undoLast() else { return }
        if var run = try? Run.load(), run.source == record.source {
            run.unmark(record.ids)
            run.markCaptioned(record.captioned, false)
            try run.save()
        }
        if !record.ids.isEmpty { print("Put back \(record.ids.count) photos in \(record.source).") }
        if !record.captioned.isEmpty { print("Put back the old captions on \(record.captioned.count) kept photos.") }
        if !record.deleted.isEmpty {
            print("\(record.deleted.count) photos were deleted; recover them in Photos → Recently Deleted.")
        }
    }
}

struct Albums: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List your Photos albums.")

    func run() async throws {
        try await Library.requestAccess()
        for album in Library.albums() {
            print(String(format: "%8d  %@", album.count, album.title))
        }
    }
}

// MARK: - helpers

extension Run {
    /// Marks photos as moved after a move to Duplicates.
    mutating func markMoved(_ ids: [String]) {
        let set = Set(ids)
        func mark(_ list: inout [Group]) {
            for g in list.indices {
                let newlyMoved = list[g].photos.map(\.id).filter { set.contains($0) && !list[g].pick.moved.contains($0) }
                list[g].pick.moved += newlyMoved
            }
        }
        mark(&groups)
        if documentGroups != nil { mark(&documentGroups!) }
        if junkGroups != nil { mark(&junkGroups!) }
    }

    /// Marks kept photos as having had a caption written, or not.
    mutating func markCaptioned(_ ids: [String], _ captioned: Bool = true) {
        let set = Set(ids)
        func mark(_ list: inout [Group]) {
            for g in list.indices {
                for p in list[g].photos.indices where set.contains(list[g].photos[p].id) {
                    list[g].photos[p].captioned = captioned ? true : nil
                }
            }
        }
        mark(&groups)
        if documentGroups != nil { mark(&documentGroups!) }
        if junkGroups != nil { mark(&junkGroups!) }
    }

    /// Reverses `markMoved` after an undo.
    mutating func unmark(_ ids: [String]) {
        let set = Set(ids)
        for g in groups.indices { groups[g].pick.moved.removeAll { set.contains($0) } }
        for g in (documentGroups ?? []).indices { documentGroups![g].pick.moved.removeAll { set.contains($0) } }
        for g in (junkGroups ?? []).indices { junkGroups![g].pick.moved.removeAll { set.contains($0) } }
    }

}

/// Restores the terminal if the user presses ctrl-c mid-scan.
final class StopHandler: @unchecked Sendable {
    private let source: DispatchSourceSignal

    init(_ cleanup: @escaping @Sendable () -> Void) {
        signal(SIGINT, SIG_IGN)
        source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        source.setEventHandler {
            cleanup()
            print("Stopped. Everything analysed so far is saved; run the same scan again to carry on.")
            exit(130)
        }
        source.resume()
    }

    func cancel() {
        source.cancel()
        signal(SIGINT, SIG_DFL)
    }
}

extension Photo {
    /// Scores came from a small local preview, not a proper 1024px render.
    func isPreviewOnly(_ scores: Analysis) -> Bool {
        Double(scores.previewSide) < 0.9 * Double(min(1024, max(width, height)))
    }

    /// The same photo with new scores but its original fingerprint.
    func with(_ scores: Analysis) -> Photo {
        var analysis = scores
        analysis.vector = self.analysis.vector
        return Photo(id: id, date: date, isScreenshot: isScreenshot, width: width, height: height, analysis: analysis,
                     quality: quality, location: location, timed: timed)
    }
}

extension Run.Member {
    init(_ photo: Photo) {
        self.init(id: photo.id, date: photo.date,
                  width: photo.width, height: photo.height,
                  aesthetic: photo.analysis.aesthetic, sharpness: photo.analysis.sharpness,
                  faceCount: photo.analysis.faceCount, faceQuality: photo.analysis.faceQuality,
                  previewSide: photo.analysis.previewSide)
    }
}

enum DateArgument {
    /// Parses 2024 / 2024-06 / 2024-06-15. For `end`, returns the start of the
    /// next period so the given year, month or day is included.
    static func parse(_ text: String?, end: Bool) throws -> Date? {
        guard let text else { return nil }
        let calendar = Calendar.current
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard (1...3).contains(parts.count), parts.count == text.split(separator: "-").count,
              let start = calendar.date(from: DateComponents(year: parts[0], month: parts.count > 1 ? parts[1] : 1,
                                                             day: parts.count > 2 ? parts[2] : 1))
        else { throw ValidationError("Can't read date “\(text)”. Use 2024, 2024-06 or 2024-06-15.") }
        guard end else { return start }
        let unit: Calendar.Component = [.year, .month, .day][parts.count - 1]
        return calendar.date(byAdding: unit, value: 1, to: start)
    }
}
