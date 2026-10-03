import Foundation

/// `pixelgraph` on its own: choose where your photos are, scan, review, and
/// come back here for the next one.
final class App {
    /// Flags given on the command line, which win over Settings for this run.
    private let flags: ScanOptions
    private var settings: Settings
    /// This scan's options: Settings, then the flags.
    private var options: Scanner.Options
    /// A scan that would start a review in progress over: asked in the bar first.
    private var rescanning: Source?
    private let ui: UI

    private enum Row {
        case heading(String)
        /// A review in progress: the current one (no id) or one set aside.
        case resume(id: String?, scope: String, waiting: Int, reviewed: Int, groups: Int)
        case source(Source, detail: String)
        case months(total: Int)
        /// A year on the months screen; ticking it ticks all its months.
        case year(Int, months: [Date], count: Int)
        case month(Source, count: Int)
        case browse(URL, title: String, detail: String)
        case choose
        case scanHere(URL, count: Int)
        case folder(URL)
        case settings(changed: Int)
        /// A quick part of the library: the last 7 or 30 days, or since your last scan.
        case range(Source, title: String, detail: String)
        /// Photos that have waited long enough in PGDuplicates and PGJunk to delete.
        case empty(count: Int, days: Int)
        /// Rows that open a screen of their own.
        case albums(count: Int)
        case folders
    }

    private enum Screen: Equatable {
        case home, months, albums, folders
        case browser(URL)
    }

    private var screen = Screen.home
    private var rows: [Row] = []
    private var selected = 0
    private var scroll = 0
    private var prompt: String?
    private var message: String?
    private var photosAllowed = false
    private let intro: Bool
    /// Months ticked on the months screen (their first moments; kept for
    /// next time), the last one ticked (where x ranges from), and each
    /// month's photo count.
    private var ticked: Set<Date> = []
    private var anchor: Date?
    private var monthCounts: [Date: Int] = [:]
    /// ? was pressed: this screen's keys are showing; any key closes them.
    private var showingKeys = false
    /// Empty… was chosen: what would be deleted, waiting for d.
    private var emptying: (photos: [String], files: [URL])?
    /// The review of this same place a new scan would start over, shown as a warning.
    private var replacing: (scope: String, waiting: Int)?
    /// How far each folder, album and month has got; pinned folder paths.
    private var statuses: [String: PlaceStatus] = [:]
    private var pins: [String] = []

    init(flags: ScanOptions, intro: Bool = true) {
        let settings = Settings.load()
        self.flags = flags
        self.settings = settings
        options = flags.scanner(settings)
        ui = UI(graphics: settings.graphics)
        self.intro = intro
    }

    func run() async throws {
        // Ask for Photos access before taking over the screen, so the system
        // prompt isn't hidden. Folders still work without it.
        photosAllowed = (try? await Library.requestAccess()) != nil
        ui.enter()
        defer {
            ui.leave()
            // Quitting doesn't ask, so say in a line what's waiting.
            let current = (try? Run.load()).flatMap { $0.source != nil && $0.waiting > 0 ? $0 : nil }
            let others = Reviews.aside().count
            if let current {
                print("Saved. \(current.scope): \(current.waiting) photos waiting"
                      + (others > 0 ? ", and \(others) more review\(others == 1 ? "" : "s") in progress" : "") + ". Run pixelgraph to carry on.")
            } else if others > 0 {
                print("Saved. \(others) review\(others == 1 ? "" : "s") in progress. Run pixelgraph to carry on.")
            }
        }
        if intro { await Intro.play(on: ui.term) }
        load()
        draw()
        while true {
            let key = ui.term.nextKey()
            if case .scroll(let ticks) = key {
                guard prompt == nil, ticks != 0 else { continue }
                move(ticks > 0 ? 1 : -1)
                draw()
                continue
            }
            if showingKeys {
                showingKeys = false
                draw()
                continue
            }
            if let due = emptying {
                switch key {
                case .char("d"), .click where ui.promptClick(key) == .button(danger: true):
                    emptying = nil
                    await empty(due)
                case .click where ui.promptClick(key) == .inside, .resize: break
                case .escape, .backspace, .char("n"), .char("q"), .quit, .click: emptying = nil
                default: break
                }
                draw()
                continue
            }
            if let source = rescanning {
                switch key {
                case .enter, .click where ui.promptClick(key) == .button(danger: false):
                    rescanning = nil
                    if try await scan(source) == .quit { return }
                case .click where ui.promptClick(key) == .inside, .resize: break
                case .quit, .char("q"): return
                case .escape, .backspace, .char("n"), .click: rescanning = nil
                default: break
                }
                draw()
                continue
            }
            if prompt != nil {
                _ = editPrompt(key)
            } else if let action = handle(key) {
                switch action {
                case .quit: return
                case .scan(let source):
                    if try await start(source) == .quit { return }
                case .resume(let id):
                    if try await resume(id) == .quit { return }
                case .settings:
                    openSettings()
                case .empty:
                    await prepareEmpty()
                }
            }
            draw()
        }
    }

    private enum Action { case quit, scan(Source), resume(String?), settings, empty }

    /// Enter on something to scan: scans it with your settings, straight
    /// away. Only a scan that would start a review in progress over asks
    /// first, in the bar; reviews of other places are kept.
    private func start(_ source: Source) async throws -> ReviewSession.Outcome {
        settings = Settings.load()
        options = flags.scanner(settings)
        if let current = try? Run.load(), current.source == source, current.waiting > 0 {
            replacing = (current.scope, current.waiting)
        } else if let aside = Reviews.aside().first(where: { $0.source == source }) {
            replacing = (aside.scope, aside.waiting)
        } else {
            replacing = nil
        }
        guard replacing == nil else {
            rescanning = source
            return .home
        }
        return try await scan(source)
    }

    /// The Settings screen, then back here with the new settings in use.
    private func openSettings() {
        let before = settings.graphics
        settings = SettingsScreen(ui: ui).show()
        if settings.graphics != before {
            ui.graphics = settings.graphics.resolved
            ui.forgetImages()
        }
        options = flags.scanner(settings)
        drawnFrame = nil
        reload()
    }

    // MARK: - Rows

    private func load() {
        rows = []
        if screen != .months { anchor = nil }
        let db = Database.open()
        statuses = db?.statuses() ?? [:]
        pins = db?.pins() ?? []
        switch screen {
        case .home: loadHome(db)
        case .months: loadMonths()
        case .albums: loadAlbums()
        case .folders: loadFolders(db)
        case .browser(let url): loadFolder(url)
        }
        selected = rows.firstIndex(where: isSelectable) ?? 0
        scroll = 0
    }

    /// Loads again, keeping the highlight where it was.
    private func reload() {
        let (keep, keepScroll) = (selected, scroll)
        load()
        if rows.indices.contains(keep), isSelectable(rows[keep]) { (selected, scroll) = (keep, keepScroll) }
    }

    /// The start screen, in the order you'd want it: the review you're in
    /// the middle of, something new to scan, pinned folders, recent scans.
    /// Albums, months and folders each have a screen of their own.
    private func loadHome(_ db: Database?) {
        // Every review in progress: the one worked on last, then those set aside.
        let current = (try? Run.load()).flatMap { $0.source != nil && $0.waiting > 0 ? $0 : nil }
        let aside = Reviews.aside()
        if current != nil || !aside.isEmpty {
            rows.append(.heading("CONTINUE REVIEWING"))
            if let current {
                rows.append(.resume(id: nil, scope: current.scope, waiting: current.waiting, reviewed: current.reviewedGroups,
                                    groups: current.allGroups.count))
            }
            for review in aside {
                rows.append(.resume(id: review.id, scope: review.scope, waiting: review.waiting, reviewed: review.reviewed, groups: review.groups))
            }
            rows.append(.heading(""))
        }
        let inProgress = Set([current?.source].compactMap { $0 } + aside.map(\.source))
        let recents = Recents.all()

        rows.append(.heading("NEW SCAN"))
        if photosAllowed {
            let day: TimeInterval = 86_400
            for days in [7, 30] {
                let from = Calendar.current.startOfDay(for: Date.now.addingTimeInterval(-Double(days - 1) * day))
                rows.append(.range(.dates(from: from, to: nil), title: "Last \(days) days", detail: Self.photos(Library.count(from: from))))
            }
            let libraryScans = recents.filter { entry in
                if case .album = entry.source { return false }
                return entry.source.isPhotos
            }
            if let since = libraryScans.map(\.date).max(), since < Date.now.addingTimeInterval(-day) {
                rows.append(.range(.dates(from: since, to: nil), title: "Since your last scan, \(since.formatted(.dateTime.month(.abbreviated).day()))",
                                   detail: Self.photos(Library.count(from: since))))
            }
            rows.append(.albums(count: Library.albums().count))
            rows.append(.months(total: Library.totalCount()))
        } else {
            rows.append(.heading("Photos access is off: System Settings → Privacy & Security → Photos"))
        }
        rows.append(.folders)

        let pinned = pins.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
        if !pinned.isEmpty {
            rows.append(.heading(""))
            rows.append(.heading("PINNED"))
            for url in pinned { rows.append(.browse(url, title: url.lastPathComponent, detail: "")) }
        }

        // Scans lately, newest first, each once: not reviews in progress, not pinned folders.
        let recent = recents.filter { entry in
            if inProgress.contains(entry.source) { return false }
            if case .folder(let path) = entry.source { return !pins.contains(URL(fileURLWithPath: path).resolvingSymlinksInPath().path) }
            return true
        }
        if !recent.isEmpty {
            rows.append(.heading(""))
            rows.append(.heading("RECENT"))
            for entry in recent.prefix(5) { rows.append(.source(entry.source, detail: Self.photos(entry.photos))) }
        }

        rows.append(.heading(""))
        let days = settings.int(.emptyDays)
        let waiting = Staged.older(than: days).count
        if waiting > 0 { rows.append(.empty(count: waiting, days: days)) }
        rows.append(.settings(changed: settings.changed))
    }

    /// Every album, to scan one.
    private func loadAlbums() {
        for album in Library.albums() {
            rows.append(.source(.album(id: album.id, title: album.title), detail: Self.photos(album.count)))
        }
        if rows.isEmpty { rows.append(.heading("No albums in your library")) }
    }

    /// Where folders of photos are: where you were, drives, this Mac.
    private func loadFolders(_ db: Database?) {
        let fm = FileManager.default
        if let path = db?.state("last-folder"), fm.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            rows.append(.browse(url, title: "Back to “\(url.lastPathComponent)”", detail: ""))
            rows.append(.heading(""))
        }
        let drives = externalVolumes()
        if !drives.isEmpty {
            rows.append(.heading("DRIVES"))
            for volume in drives { rows.append(.browse(volume, title: volume.lastPathComponent, detail: "")) }
            rows.append(.heading(""))
        }
        rows.append(.heading("ON THIS MAC"))
        let home = fm.homeDirectoryForCurrentUser
        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if fm.fileExists(atPath: iCloud.path) { rows.append(.browse(iCloud, title: "iCloud Drive", detail: "")) }
        rows.append(.browse(home.appendingPathComponent("Pictures"), title: "Pictures", detail: ""))
        rows.append(.choose)
    }

    /// "1 photo", "18,019 photos".
    static func photos(_ n: Int) -> String { "\(n.formatted()) photo\(n == 1 ? "" : "s")" }

    /// A folder's path with ~ for home.
    static func shortPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home) ? "~" + String(url.path.dropFirst(home.count)) : url.path
    }

    private func loadMonths() {
        monthCounts = [:]
        let months = Library.months()
        let years = Dictionary(grouping: months) { Calendar.current.component(.year, from: $0.start) }
        for year in years.keys.sorted(by: >) {
            let list = years[year] ?? []
            rows.append(.year(year, months: list.map(\.start), count: list.reduce(0) { $0 + $1.count }))
            for month in list {
                monthCounts[month.start] = month.count
                rows.append(.month(.dates(from: month.start, to: month.end), count: month.count))
            }
        }
        // Months ticked last time, as long as they're still there.
        let saved = Database.open()?.state("ticked-months")?.split(separator: ",").compactMap { Double($0) } ?? []
        ticked = Set(saved.map { Date(timeIntervalSince1970: $0) }).filter { monthCounts[$0] != nil }
    }

    private func saveTicks() {
        let value = ticked.sorted().map { String($0.timeIntervalSince1970) }.joined(separator: ",")
        Database.open()?.setState("ticked-months", value.isEmpty ? nil : value)
    }

    /// The first moment of a month row's month.
    private func monthStart(_ row: Row) -> Date? {
        if case .month(.dates(let from?, _), _) = row { return from }
        return nil
    }

    private static let monthName: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM"
        return f
    }()

    private func loadFolder(_ url: URL) {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles])) ?? []
        let images = contents.filter { Files.imageExtensions.contains($0.pathExtension.lowercased()) }.count
        rows.append(.scanHere(url, count: images))
        let folders = contents.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && !Files.ownFolders.contains($0.lastPathComponent)
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        if !folders.isEmpty { rows.append(.heading("FOLDERS")) }
        rows += folders.map(Row.folder)
    }

    private func externalVolumes() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsInternalKey, .volumeIsBrowsableKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return volumes.filter { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return url.path.hasPrefix("/Volumes/") && values?.volumeIsInternal == false && values?.volumeIsBrowsable != false
        }
    }

    private func isSelectable(_ row: Row) -> Bool {
        if case .heading = row { return false }
        return true
    }

    // MARK: - Input

    private func handle(_ key: Terminal.Key) -> Action? {
        message = nil
        if screen == .months {
            let (handled, action) = handleMonths(key)
            if handled { return action }
        }
        switch key {
        case .quit, .char("q"): return .quit
        case .up: move(-1)
        case .down: move(1)
        case .enter, .right, .char(" "): return activate(rows[selected], opening: key == .right)
        case .left, .escape, .backspace: back()
        case .click(let row, _):
            let index = row - listTop + scroll
            if rows.indices.contains(index), isSelectable(rows[index]) {
                selected = index
                return activate(rows[index], opening: false)
            }
        case .char("s"):
            if case .browser(let url) = screen { return .scan(.folder(url)) }
        case .char(","): return .settings
        case .char("p"): togglePin()
        case .char("?"): showingKeys = true
        case .home: selected = rows.firstIndex(where: isSelectable) ?? selected
        case .end: selected = rows.lastIndex(where: isSelectable) ?? selected
        default: break
        }
        return nil
    }

    /// The folder a row stands for, if any.
    private func folderURL(_ row: Row) -> URL? {
        switch row {
        case .source(.folder(let path), _): return URL(fileURLWithPath: path)
        case .browse(let url, _, _), .folder(let url), .scanHere(let url, _): return url
        default: return nil
        }
    }

    /// p: pins the highlighted folder to the home screen, or unpins it.
    private func togglePin() {
        guard rows.indices.contains(selected), let url = folderURL(rows[selected]) else {
            message = ui.dim("Only folders can be pinned.")
            return
        }
        let path = url.resolvingSymlinksInPath().path
        let pinning = !pins.contains(path)
        Database.open()?.setPinned(path, pinning)
        message = pinning ? ui.green("✓") + " Pinned “\(url.lastPathComponent)” to the home screen · p again to unpin"
            : ui.dim("Unpinned “\(url.lastPathComponent)”")
        reload()
    }

    /// Where "Back to …" on the home screen goes.
    private func remember(_ url: URL) {
        Database.open()?.setState("last-folder", url.resolvingSymlinksInPath().path)
    }

    /// Ticking months: space ticks one (or a whole year), x ticks every month
    /// from the last one ticked to this one, a click ticks; enter scans
    /// what's ticked, or the highlighted month or year when nothing is.
    private func handleMonths(_ key: Terminal.Key) -> (handled: Bool, action: Action?) {
        switch key {
        case .char(" "): tick(selected)
        case .char("x"): tickRange()
        case .char("c"):
            guard !ticked.isEmpty else { return (true, nil) }
            message = ui.dim("Cleared \(ticked.count) ticked month\(ticked.count == 1 ? "" : "s")")
            ticked = []
            anchor = nil
            saveTicks()
        case .click(let row, _):
            let index = row - listTop + scroll
            if rows.indices.contains(index), isSelectable(rows[index]) {
                selected = index
                tick(index)
            }
        case .enter, .right:
            if !ticked.isEmpty { return (true, .scan(Source.selection(of: Array(ticked)))) }
            if case .year(_, let months, _) = rows[selected] { return (true, .scan(Source.selection(of: months))) }
            return (false, nil)
        default: return (false, nil)
        }
        return (true, nil)
    }

    private func tick(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        if case .year(_, let months, _) = rows[index] {
            if months.allSatisfy(ticked.contains) { ticked.subtract(months) } else { ticked.formUnion(months) }
            anchor = nil
        } else if let start = monthStart(rows[index]) {
            if ticked.contains(start) { ticked.remove(start) } else { ticked.insert(start) }
            anchor = start
        }
        saveTicks()
    }

    private func tickRange() {
        guard let end = monthStart(rows[selected]), let start = anchor else { return tick(selected) }
        let (low, high) = start < end ? (start, end) : (end, start)
        for row in rows {
            if let month = monthStart(row), month >= low, month <= high { ticked.insert(month) }
        }
        anchor = end
        saveTicks()
    }

    private func move(_ step: Int) {
        var next = selected + step
        while rows.indices.contains(next), !isSelectable(rows[next]) { next += step }
        if rows.indices.contains(next) { selected = next }
    }

    private func activate(_ row: Row, opening: Bool) -> Action? {
        switch row {
        case .heading: return nil
        case .source(let source, _): return opening ? nil : .scan(source)
        case .month(let source, _): return .scan(source)
        case .resume(let id, _, _, _, _): return .resume(id)
        case .year: return nil
        case .months:
            screen = .months
            load()
        case .browse(let url, _, _):
            screen = .browser(url)
            load()
        case .folder(let url):
            // Somewhere inside: where "Back to …" will go.
            screen = .browser(url)
            remember(url)
            load()
        case .scanHere(let url, _): return opening ? nil : .scan(.folder(url))
        case .choose: prompt = ""
        case .settings: return .settings
        case .range(let source, _, _): return opening ? nil : .scan(source)
        case .empty: return .empty
        case .albums:
            screen = .albums
            load()
        case .folders:
            screen = .folders
            load()
        }
        return nil
    }

    private func back() {
        switch screen {
        case .home: return
        case .months, .albums, .folders: screen = .home
        case .browser(let url):
            let parent = url.deletingLastPathComponent()
            let home = FileManager.default.homeDirectoryForCurrentUser
            screen = url.path == "/" || url == home || url.path.split(separator: "/").count <= 2 ? .home : .browser(parent)
        }
        load()
    }

    /// The "Choose another folder…" line editor. Accepts a typed or pasted
    /// path, or a folder dragged in from Finder.
    private func editPrompt(_ key: Terminal.Key) -> Source? {
        guard var text = prompt else { return nil }
        switch key {
        case .escape, .quit:
            prompt = nil
            return nil
        case .click(let row, let col):
            if ui.promptClick(row: row, col: col) == .outside { prompt = nil }
            return nil
        case .backspace:
            if !text.isEmpty { text.removeLast() }
        case .char(let c):
            text.append(ui.term.typed ?? c)
        case .enter:
            let path = cleanPath(text)
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue {
                prompt = nil
                screen = .browser(URL(fileURLWithPath: path))
                remember(URL(fileURLWithPath: path))
                load()
                return nil
            }
            message = ui.red("No folder at “\(path)”")
        default: break
        }
        prompt = text
        return nil
    }

    private func cleanPath(_ text: String) -> String {
        var path = text.trimmingCharacters(in: .whitespaces)
        if (path.hasPrefix("'") && path.hasSuffix("'")) || (path.hasPrefix("\"") && path.hasSuffix("\"")) {
            path = String(path.dropFirst().dropLast())
        }
        path = path.replacingOccurrences(of: "\\ ", with: " ")
        return (path as NSString).expandingTildeInPath
    }

    // MARK: - Scan

    /// Back into a review, as it was left: the current one, or one set
    /// aside, which swaps in (the current one is set aside in its place).
    private func resume(_ id: String?) async throws -> ReviewSession.Outcome {
        defer { drawnFrame = nil }
        if let id {
            do {
                try Reviews.resume(id)
            } catch {
                message = ui.red("That review can't be opened: \(error.localizedDescription)")
                reload()
                return .home
            }
            ui.forgetImages()
        }
        guard let run = try? Run.load() else {
            message = ui.red("The last scan can't be opened; scan again.")
            return .home
        }
        if run.source?.isPhotos ?? true, !photosAllowed {
            message = ui.red("PixelGraph needs access to Photos for that.")
            return .home
        }
        let outcome: ReviewSession.Outcome
        do {
            outcome = try await ReviewSession(run: run, ui: ui).show()
        } catch {
            message = ui.red(error.localizedDescription)
            return .home
        }
        screen = .home
        load()
        return outcome
    }

    private func scan(_ source: Source) async throws -> ReviewSession.Outcome {
        // The scan and the review take over the screen, so the home screen
        // must repaint fully when it comes back.
        defer { drawnFrame = nil }
        if source.isPhotos && !photosAllowed {
            message = ui.red("PixelGraph needs access to Photos for that.")
            return .home
        }
        if case .folder(let path) = source { remember(URL(fileURLWithPath: path)) }
        // The review you were in the middle of waits under Continue reviewing.
        Reviews.prepareScan(of: source)
        let started = Date.now
        ui.term.write(ui.clear())
        let scanner = Scanner(source: source, options: options, fullScreen: true)
        ui.term.allowInterrupt(true)
        let stop = StopHandler { [ui] in
            scanner.board.abandon()
            ui.leave()
        }
        let run: Run
        do {
            run = try await scanner.run()
        } catch {
            stop.cancel()
            ui.term.allowInterrupt(false)
            message = ui.red(error.localizedDescription)
            screen = .home
            load()
            return .home
        }
        stop.cancel()
        ui.term.allowInterrupt(false)

        guard !run.allGroups.isEmpty else {
            message = ui.green("✓") + " Nothing to tidy in \(source): no lookalikes, junk or documents."
            screen = .home
            load()
            return .home
        }
        // A long scan may have been left to run: ring, and ask the terminal to say so.
        if Date.now.timeIntervalSince(started) > 20 {
            ui.term.write("\u{07}\u{1B}]9;PixelGraph finished scanning \(source.description.filter { $0.isLetter || $0.isNumber || " ,–-".contains($0) })\u{07}")
        }
        // What was found stays on screen; enter goes on to review it.
        ui.term.drainInput()
        ui.term.write(ui.barLine(ui.rows, ui.spread(ui.hints("enter review it · esc back to the start screen"), ui.button("enter Review"),
                                                    width: ui.cols - 4)))
        guard waitToReview() else {
            message = ui.green("✓") + " Scanned \(source) · “Continue reviewing” picks it up when you're ready"
            screen = .home
            load()
            return .home
        }
        ui.forgetImages()
        let outcome = try await ReviewSession(run: run, ui: ui).show()
        screen = .home
        load()
        return outcome
    }

    // MARK: - Drawing

    /// What the last full frame showed, apart from the selection.
    private var drawnFrame: String?
    private var drawnSelected = -1

    /// The screen is a centred column, sitting a third of the way down when
    /// the list is short; long lists start near the top and scroll.
    private var columnWidth: Int { max(20, min(ui.cols - 4, 88)) }
    private var left: Int { max(3, (ui.cols - columnWidth) / 2 + 1) }
    private var listTop: Int { max(4, (ui.rows - 3 - (rows.count + 2)) / 3 + 2) }

    /// Moving the selection repaints just the two rows involved and the
    /// action bar; anything else repaints the screen.
    private func draw() {
        if ui.tooSmall {
            ui.term.write(ui.tooSmallScreen())
            drawnFrame = nil
            return
        }
        if showingKeys {
            ui.term.write(keysPage())
            drawnFrame = nil
            return
        }
        let visible = max(1, ui.rows - listTop - 3)
        if selected < scroll { scroll = selected }
        if selected >= scroll + visible { scroll = selected - visible + 1 }
        let asking = prompt != nil || emptying != nil || rescanning != nil
        let key = "\(screen) \(scroll) \(rows.count) \(ui.cols)x\(ui.rows) \(message ?? "-") \(ticked.count) \(asking)"

        var out: String
        if key == drawnFrame, !asking {
            out = rowLine(drawnSelected) + rowLine(selected)
        } else {
            out = ui.clear()
            let title: String
            switch screen {
            case .home: title = ui.bold("PixelGraph")
            case .months: title = ui.bold("Months and years")
            case .albums: title = ui.bold("Albums")
            case .folders: title = ui.bold("Folders and drives")
            case .browser(let url): title = ui.bold(url.lastPathComponent) + ui.dim("  ·  " + url.deletingLastPathComponent().path)
            }
            out += ui.at(listTop - 2, left) + ui.clip(title, columnWidth)
            for index in rows.indices.dropFirst(scroll).prefix(visible) { out += rowLine(index) }
            if let message { out += ui.at(ui.rows - 2, left) + ui.clip(message, columnWidth) }
        }
        // A question takes the bottom two rows in place of the bar; nothing covers the list.
        out += question() ?? actionBar()
        ui.term.write(out)
        drawnFrame = asking ? nil : key
        drawnSelected = selected
    }

    /// The question being asked, if any, for the bottom of the screen.
    private func question() -> String? {
        if let prompt {
            return ui.prompt("Folder  › " + prompt + "▏", note: ui.dim("Type or paste a path, or drag a folder here from Finder"),
                             keys: "", buttons: ui.hints("enter open · esc cancel"))
        }
        if let source = rescanning, let replacing {
            return ui.prompt("Scan \(ui.fit(source.description, 30)) again and start over?",
                             note: ui.dim("Your review of \(replacing.scope) has \(replacing.waiting) photos waiting; "
                                          + "pick it under Continue reviewing to go back to it instead"),
                             keys: "esc keep it", buttons: ui.button("enter Scan again"))
        }
        if let due = emptying {
            func count(_ n: Int, _ what: String) -> String { "\(n) \(what)\(n == 1 ? "" : "s")" }
            var what: [String] = []
            if !due.photos.isEmpty { what.append(count(due.photos.count, "photo") + " from your library") }
            if !due.files.isEmpty { what.append(count(due.files.count, "file")) }
            return ui.prompt("Delete what has waited \(settings.int(.emptyDays))+ days?",
                             note: ui.dim(what.joined(separator: " and ") + " in PGDuplicates or PGJunk · photos go to Recently Deleted "
                                          + "for 30 days (macOS asks first), files to the Trash"),
                             buttons: ui.dangerButton("d Delete \(due.photos.count + due.files.count)"))
        }
        return nil
    }

    /// ?: the keys for this screen, as a page of its own.
    private func keysPage() -> String {
        var sections: [(name: String, keys: [(key: String, does: String)])] = [
            ("Moving around", [("↑ ↓", "choose · home and end: first and last"), ("enter", "scan it, continue it, or open it"),
                               ("→  ←", "open · go back")]),
        ]
        switch screen {
        case .months:
            sections.append(("Months", [("space", "tick a month, or a whole year"), ("x", "tick every month from the last one ticked"),
                                        ("c", "clear the ticks"), ("enter", "scan what's ticked")]))
        case .browser:
            sections.append(("Folders", [("s", "scan this folder, and the folders in it"), ("p", "pin a folder to the start screen")]))
        case .home, .folders:
            sections.append(("Folders", [("p", "pin a folder to the start screen; again to unpin")]))
        case .albums:
            break
        }
        sections.append(("Elsewhere", [(",", "settings"), ("q", "quit; everything is saved")]))
        return ui.keysPage("Keys", sections)
    }

    /// Empty…: what has waited long enough in PGDuplicates and PGJunk, to confirm.
    private func prepareEmpty() async {
        let days = settings.int(.emptyDays)
        guard let due = try? await Empty.due(olderThan: days, photos: photosAllowed), !(due.photos.isEmpty && due.files.isEmpty) else {
            message = ui.dim("Nothing has waited \(days) days in PGDuplicates or PGJunk any more.")
            reload()
            return
        }
        emptying = due
    }

    private func empty(_ due: (photos: [String], files: [URL])) async {
        do {
            let deleted = try await Empty.delete(photos: due.photos, files: due.files)
            message = ui.green("✓") + " Deleted \(deleted.photos) photos and \(deleted.files) files"
                + ui.dim(" · photos stay in Recently Deleted for 30 days, files in the Trash")
        } catch {
            message = ui.red("Couldn't delete: \(error.localizedDescription)")
        }
        drawnFrame = nil
        reload()
    }

    /// After a scan: enter (or a click) reviews it, esc goes back to the start screen.
    private func waitToReview() -> Bool {
        while true {
            switch ui.term.nextKey() {
            case .enter, .char(" "), .click: return true
            case .escape, .backspace, .char("q"), .quit: return false
            default: continue
            }
        }
    }

    /// One list row, highlighted when selected, covering the full width so
    /// a previous highlight never shows through.
    private func rowLine(_ index: Int) -> String {
        guard rows.indices.contains(index) else { return "" }
        let r = listTop + index - scroll
        guard r >= listTop, r < ui.rows - 2 else { return "" }
        let line = render(rows[index], width: columnWidth - 2)
        if index == selected {
            return ui.at(r, 1) + "\u{1B}[2K" + ui.at(r, left - 2) + ui.bar() + ui.highlight(" " + line, width: columnWidth)
        }
        return ui.at(r, 1) + "\u{1B}[2K" + ui.at(r, left) + line
    }

    private func actionBar() -> String {
        var action: String
        switch rows.indices.contains(selected) ? rows[selected] : .choose {
        case .source(let source, _), .month(let source, _): action = ui.button("Scan \(ui.fit(source.description, 28))")
        case .scanHere(let url, _): action = ui.button("Scan \(ui.fit(url.lastPathComponent, 28))")
        case .browse, .folder, .months, .albums, .folders: action = ui.button("Open")
        case .resume: action = ui.button("Continue")
        case .settings: action = ui.button("Open settings")
        case .range(_, let title, _): action = ui.button("Scan \(title.lowercased())")
        case .empty: action = ui.button("Empty…")
        default: action = ""
        }
        // What enter does for the highlighted row, in the bar's own words.
        let verb: String
        switch rows.indices.contains(selected) ? rows[selected] : .choose {
        case .resume: verb = "continue"
        case .source, .month, .range, .scanHere, .year: verb = "scan"
        case .empty: verb = "empty"
        case .choose: verb = "choose"
        default: verb = "open"
        }
        let backHint = screen == .home ? "" : " · ← back"
        let scanHint: String
        if case .browser = screen { scanHint = " · s scan this folder" } else { scanHint = "" }
        let pinHint = rows.indices.contains(selected) && folderURL(rows[selected]) != nil ? " · p pin" : ""
        // The bar lines up with the column above it.
        var hints = "↑↓ choose · enter \(verb)\(scanHint)\(pinHint)\(backHint) · , settings · q quit · ? keys"
        var short = "↑↓ · enter \(verb)\(backHint) · ? keys"
        if screen == .months, rows.indices.contains(selected) {
            hints = "↑↓ choose · space tick · x tick range · c clear · enter scan · ← back · ? keys"
            short = "space tick · x range · enter scan"
            if !ticked.isEmpty {
                let photos = ticked.reduce(0) { $0 + (monthCounts[$1] ?? 0) }
                action = ui.button("Scan \(ticked.count) month\(ticked.count == 1 ? "" : "s") · \(photos.formatted()) photos")
            } else if case .year(let year, _, _) = rows[selected] {
                action = ui.button("Scan \(year)")
            } else if let start = monthStart(rows[selected]) {
                let year = Calendar.current.component(.year, from: start)
                action = ui.button("Scan \(Self.monthName.string(from: start)) \(year)")
            }
        }
        let room = columnWidth - ui.visibleWidth(action) - 2
        let text = ui.visibleWidth(hints) <= room ? hints : short
        // The bar runs the full width; its text lines up with the column above.
        return ui.barLine(ui.rows, String(repeating: " ", count: max(0, left - 3))
            + ui.spread(ui.clip(ui.hints(text), max(0, room)), action, width: columnWidth))
    }

    /// How far these places got, for the status column: "Scanned Oct 2"
    /// quietly, and in green once something was done ("Moved 34 · Oct 2").
    private func status(_ places: [String]) -> String {
        guard let latest = places.compactMap({ statuses[$0] }).max(by: { $0.date < $1.date }) else { return "" }
        return latest.acted ? ui.green(latest.label) : ui.dim(latest.label)
    }

    private func status(_ url: URL) -> String { status(Source.folder(url).places) }

    /// A row in three columns that start at the same place on every row:
    /// what it is, how many photos, and how far it got. Rows that open
    /// another screen end in ›. `accessory` sits at the end of the name
    /// column (the bar on each month). Narrow windows keep name and count.
    private func columns(_ name: String, _ count: String = "", _ status: String = "", opens: Bool = false,
                         accessory: String = "", width: Int) -> String {
        let countWidth = 13, statusWidth = width >= 80 ? 20 : 16, chevron = 2
        let nameWidth = width - countWidth - statusWidth - chevron - 2
        guard nameWidth >= 12 else { return ui.spread(name + (opens ? ui.dim(" ›") : ""), count, width: width) }
        var left = ui.clip(name, accessory.isEmpty ? nameWidth : nameWidth - ui.visibleWidth(accessory) - 1)
        if !accessory.isEmpty { left = ui.spread(left, accessory, width: nameWidth) }
        let shown = ui.clip(status, statusWidth)
        return left + String(repeating: " ", count: max(1, nameWidth + countWidth - ui.visibleWidth(left) - ui.visibleWidth(count))) + count
            + "  " + shown + String(repeating: " ", count: max(0, statusWidth - ui.visibleWidth(shown))) + (opens ? ui.dim(" ›") : "  ")
    }

    private func render(_ row: Row, width: Int) -> String {
        switch row {
        case .heading(let text): return ui.dim(ui.clip(text, width))
        case .resume(_, let scope, let waiting, let reviewed, let groups):
            let bar = ProgressBoard.bar(Double(reviewed) / Double(max(1, groups)), width: 8)
            return columns(scope, ui.dim("\(waiting.formatted()) waiting"), bar + ui.dim(" \(reviewed) of \(groups)"), width: width)
        case .source(let source, let text):
            return columns(source.description, ui.dim(text), status(source.places), width: width)
        case .range(_, let title, let text):
            return columns(title, ui.dim(text), width: width)
        case .albums(let count):
            return columns("Albums", ui.dim("\(count) album\(count == 1 ? "" : "s")"), opens: true, width: width)
        case .months(let total):
            return columns("Months and years", ui.dim(Self.photos(total)), opens: true, width: width)
        case .folders:
            return columns("Folders and drives", opens: true, width: width)
        case .year(let year, let months, let count):
            let all = months.allSatisfy(ticked.contains), some = months.contains(where: ticked.contains)
            let box = all ? ui.green("[✓]") : some ? ui.green("[–]") : ui.dim("[ ]")
            let done = months.filter { statuses[Source.monthPlace($0)] != nil }.count
            let progress = done == 0 ? "" : ui.dim("\(done) of \(months.count) months scanned")
            return columns(box + " " + ui.bold(String(year)), ui.dim(Self.photos(count)), progress, width: width)
        case .month(let source, let count):
            let start = monthStart(row)
            let box = start.map(ticked.contains) == true ? ui.green("[✓]") : ui.dim("[ ]")
            let name = start.map { Self.monthName.string(from: $0) } ?? source.description
            // A bar per month, against the busiest one, to see where the photos are.
            let bar = ProgressBoard.bar(Double(count) / Double(max(1, monthCounts.values.max() ?? 1)), width: 8)
            return columns("    " + box + " " + name, ui.dim(Self.photos(count)), status(source.places), accessory: bar, width: width)
        case .browse(let url, let title, let text):
            return columns(title, ui.dim(text), status(url), opens: true, width: width)
        case .choose:
            return ui.dim("Choose another folder…")
        case .scanHere(let url, let count):
            return columns(ui.bold("Scan “\(url.lastPathComponent)”") + ui.dim(" and its folders"), ui.dim(count > 0 ? "\(count) here" : ""),
                           status(url), width: width)
        case .folder(let url):
            let pinned = pins.contains(url.resolvingSymlinksInPath().path) ? "pinned" : ""
            return columns(url.lastPathComponent, ui.dim(pinned), status(url), opens: true, width: width)
        case .settings(let changed):
            return columns("Settings", "", ui.dim(changed == 0 ? "All defaults" : "\(changed) changed"), opens: true, width: width)
        case .empty(let count, let days):
            return columns("Empty PGDuplicates and PGJunk…", ui.amber("\(count) waiting"), ui.dim("for \(days)+ days"), width: width)
        }
    }
}
