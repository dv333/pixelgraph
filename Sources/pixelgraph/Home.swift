import Foundation

/// `pixelgraph` on its own: choose where your photos are, scan, review, and
/// come back here for the next one.
final class App {
    private var options: Scanner.Options
    /// The source waiting for "What should PixelGraph do?".
    private var choosing: Source?
    private var taskCursor = 0
    private let ui = UI()

    private enum Row {
        case heading(String)
        /// The last scan, still being reviewed.
        case resume(scope: String, detail: String)
        case source(Source, detail: String)
        case months(total: Int)
        /// A year on the months screen; ticking it ticks all its months.
        case year(Int, months: [Date], count: Int)
        case month(Source, count: Int)
        case browse(URL, title: String, detail: String)
        case choose
        case scanHere(URL, count: Int)
        case folder(URL)
    }

    private enum Screen: Equatable {
        case home, months
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
    /// Months ticked on the months screen (their first moments), the last
    /// one ticked (where x ranges from), and each month's photo count.
    private var ticked: Set<Date> = []
    private var anchor: Date?
    private var monthCounts: [Date: Int] = [:]
    /// Esc was pressed once with months ticked; a second Esc drops them.
    private var discardArmed = false
    /// The unfinished review a new scan would replace, shown as a warning.
    private var replacing: Run?

    init(options: Scanner.Options, intro: Bool = true) {
        self.options = options
        self.intro = intro
    }

    func run() async throws {
        // Ask for Photos access before taking over the screen, so the system
        // prompt isn't hidden. Folders still work without it.
        photosAllowed = (try? await Library.requestAccess()) != nil
        ui.enter()
        defer { ui.leave() }
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
            if let source = choosing {
                switch key {
                case .up, .down: taskCursor = 1 - taskCursor
                case .char(" "):
                    if taskCursor == 0 { options.documents.toggle() } else { options.describe.toggle() }
                case .enter:
                    choosing = nil
                    replacing = nil
                    if try await scan(source) == .quit { return }
                case .escape, .backspace:
                    choosing = nil
                    replacing = nil
                case .quit, .char("q"): return
                default: break
                }
            } else if prompt != nil {
                if let source = editPrompt(key) { choose(source) }
            } else if let action = handle(key) {
                switch action {
                case .quit: return
                case .scan(let source):
                    choose(source)
                case .resume:
                    if try await resume() == .quit { return }
                }
            }
            draw()
        }
    }

    private enum Action { case quit, scan(Source), resume }

    /// Opens "What should PixelGraph do?", noting any review it would replace.
    private func choose(_ source: Source) {
        choosing = source
        taskCursor = 0
        replacing = (try? Run.load()).flatMap { $0.reviewedGroups > 0 && $0.waiting > 0 ? $0 : nil }
    }

    // MARK: - Rows

    private func load() {
        rows = []
        if screen != .months { ticked = []; anchor = nil }
        switch screen {
        case .home: loadHome()
        case .months: loadMonths()
        case .browser(let url): loadFolder(url)
        }
        selected = rows.firstIndex(where: isSelectable) ?? 0
        scroll = 0
    }

    private func loadHome() {
        if let last = try? Run.load(), last.source != nil, last.waiting > 0 {
            rows.append(.heading("PICK UP WHERE YOU LEFT OFF"))
            rows.append(.resume(scope: last.scope, detail: "\(last.waiting) waiting · \(last.reviewedGroups) of \(last.allGroups.count) groups looked at"))
            rows.append(.heading(""))
        }
        let recents = Recents.all()
        rows.append(.heading("PHOTOS LIBRARY · iCloud Photos"))
        if photosAllowed {
            let recentPhotos = recents.filter { $0.source.isPhotos }
            for entry in recentPhotos.prefix(3) {
                rows.append(.source(entry.source, detail: "\(entry.photos) photos · last scan: \(entry.groups) group\(entry.groups == 1 ? "" : "s")"))
            }
            let shown = Set(recentPhotos.map(\.source))
            for album in Library.albums().prefix(8) where !shown.contains(.album(id: album.id, title: album.title)) {
                rows.append(.source(.album(id: album.id, title: album.title), detail: "\(album.count.formatted()) photos"))
            }
            rows.append(.months(total: Library.totalCount()))
        } else {
            rows.append(.heading("  No access to Photos · allow it in System Settings → Privacy & Security → Photos"))
        }

        rows.append(.heading(""))
        rows.append(.heading("FOLDERS AND DRIVES"))
        for entry in recents.filter({ !$0.source.isPhotos }).prefix(4) {
            rows.append(.source(entry.source, detail: "\(entry.source.kind.lowercased()) · last scan: \(entry.groups) group\(entry.groups == 1 ? "" : "s")"))
        }
        for volume in externalVolumes() {
            rows.append(.browse(volume, title: volume.lastPathComponent, detail: "external drive"))
        }
        let iCloud = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if FileManager.default.fileExists(atPath: iCloud.path) {
            rows.append(.browse(iCloud, title: "iCloud Drive", detail: "browse folders"))
        }
        let pictures = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures")
        rows.append(.browse(pictures, title: "Pictures", detail: "browse folders"))
        rows.append(.choose)
    }

    private func loadMonths() {
        rows.append(.heading("ALL PHOTOS, BY MONTH"))
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
        default: break
        }
        return nil
    }

    /// Ticking months: space ticks one (or a whole year), x ticks every month
    /// from the last one ticked to this one, a click ticks; enter scans
    /// what's ticked, or the highlighted month or year when nothing is.
    private func handleMonths(_ key: Terminal.Key) -> (handled: Bool, action: Action?) {
        let armed = discardArmed
        discardArmed = false
        switch key {
        case .escape, .left, .backspace:
            guard !ticked.isEmpty, !armed else { return (false, nil) }
            discardArmed = true
            message = ui.amber("Press esc again to drop \(ticked.count) ticked month\(ticked.count == 1 ? "" : "s")")
            return (true, nil)
        case .char(" "): tick(selected)
        case .char("x"): tickRange()
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
    }

    private func tickRange() {
        guard let end = monthStart(rows[selected]), let start = anchor else { return tick(selected) }
        let (low, high) = start < end ? (start, end) : (end, start)
        for row in rows {
            if let month = monthStart(row), month >= low, month <= high { ticked.insert(month) }
        }
        anchor = end
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
        case .resume: return .resume
        case .year: return nil
        case .months:
            screen = .months
            load()
        case .browse(let url, _, _), .folder(let url):
            screen = .browser(url)
            load()
        case .scanHere(let url, _): return opening ? nil : .scan(.folder(url))
        case .choose: prompt = ""
        }
        return nil
    }

    private func back() {
        switch screen {
        case .home: return
        case .months: screen = .home
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
        case .backspace:
            if !text.isEmpty { text.removeLast() }
        case .char(let c):
            text.append(c)
        case .enter:
            let path = cleanPath(text)
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue {
                prompt = nil
                screen = .browser(URL(fileURLWithPath: path))
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

    /// Back into the last scan's review, as it was left.
    private func resume() async throws -> ReviewSession.Outcome {
        defer { drawnFrame = nil }
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

        guard !run.groups.isEmpty else {
            message = ui.green("✓") + " No near-identical photos in \(source)."
            screen = .home
            load()
            return .home
        }
        try? await Task.sleep(for: .milliseconds(700))
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
        let visible = max(1, ui.rows - listTop - 3)
        if selected < scroll { scroll = selected }
        if selected >= scroll + visible { scroll = selected - visible + 1 }
        let key = "\(screen) \(scroll) \(rows.count) \(ui.cols)x\(ui.rows) \(prompt ?? "-") \(message ?? "-") \(choosing != nil) \(taskCursor) \(options.documents) \(options.describe) \(ticked.count)"

        var out: String
        if key == drawnFrame, prompt == nil, choosing == nil {
            out = rowLine(drawnSelected) + rowLine(selected)
        } else {
            out = ui.clear()
            let title: String
            switch screen {
            case .home: title = ui.bold("PixelGraph") + ui.dim("  ·  find near-identical photos and keep the best")
            case .months: title = ui.bold("Photos library") + ui.dim("  ·  choose a month")
            case .browser(let url): title = ui.bold(url.lastPathComponent) + ui.dim("  ·  " + url.deletingLastPathComponent().path)
            }
            out += ui.at(listTop - 2, left) + ui.clip(title, columnWidth)
            for index in rows.indices.dropFirst(scroll).prefix(visible) { out += rowLine(index) }
            if let message { out += ui.at(ui.rows - 2, left) + ui.clip(message, columnWidth) }
            if let source = choosing {
                func task(_ index: Int?, _ on: Bool, _ name: String, _ detail: String) -> String {
                    let box = on ? ui.green("[✓]") : "[ ]"
                    let line = box + " " + name.padding(toLength: 22, withPad: " ", startingAt: 0) + ui.dim(detail)
                    return index == taskCursor ? ui.blue("› ") + line : "  " + line
                }
                out += ui.sheet([
                    ui.bold("What should PixelGraph do with \(ui.fit(source.description, 30))?"),
                    "",
                    task(nil, true, "Clean up duplicates", "keep the best, move the rest"),
                    task(0, options.documents, "Sort documents", "receipts, forms, screenshots → PGDocuments"),
                    task(1, options.describe, "Tag scenes", "what's in each grouped photo: beach, dog, sunset"),
                    "",
                ] + (replacing.map { last in [
                    ui.amber("This replaces your unfinished review of \(ui.fit(last.scope, 34)) (\(last.waiting) waiting)."),
                    ui.dim("Esc, then “Continue reviewing”, to go back to it instead."),
                    "",
                ] } ?? []) + [
                    ui.dim("↑↓ choose · space tick · enter start · esc back"),
                ], width: 82)
            }
            if let prompt {
                out += ui.sheet([
                    ui.bold("Choose a folder"),
                    ui.dim("Type or paste a path, or drag a folder here from Finder."),
                    "",
                    ui.blue("› ") + prompt + "▏",
                    "",
                    ui.dim("enter open · esc cancel"),
                ], width: 70)
            }
        }
        out += actionBar()
        ui.term.write(out)
        drawnFrame = key
        drawnSelected = selected
    }

    /// One list row, highlighted when selected, covering the full width so
    /// a previous highlight never shows through.
    private func rowLine(_ index: Int) -> String {
        guard rows.indices.contains(index) else { return "" }
        let r = listTop + index - scroll
        guard r >= listTop, r < ui.rows - 2 else { return "" }
        let line = render(rows[index], width: columnWidth - 2)
        if index == selected {
            return ui.at(r, 1) + "\u{1B}[2K" + ui.at(r, left - 2) + ui.blue("›") + " " + ui.highlight(line, width: columnWidth - 1)
        }
        return ui.at(r, 1) + "\u{1B}[2K" + ui.at(r, left) + line
    }

    private func actionBar() -> String {
        var action: String
        switch rows.indices.contains(selected) ? rows[selected] : .choose {
        case .source(let source, _), .month(let source, _): action = ui.button("Scan \(ui.fit(source.description, 28))")
        case .scanHere(let url, _): action = ui.button("Scan \(ui.fit(url.lastPathComponent, 28))")
        case .browse, .folder, .months: action = ui.button("Open")
        case .resume: action = ui.button("Continue")
        default: action = ""
        }
        let backHint = screen == .home ? "" : " · ← back"
        let scanHint: String
        if case .browser = screen { scanHint = " · s scan this folder" } else { scanHint = "" }
        // The bar lines up with the column above it.
        var hints = "↑↓ choose · enter \(screen == .home ? "scan" : "open")\(scanHint)\(backHint) · q quit"
        var short = "↑↓ · enter\(backHint) · q"
        if screen == .months, rows.indices.contains(selected) {
            hints = "↑↓ choose · space tick · x tick range · enter scan · ← back · q quit"
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
        return ui.at(ui.rows, 1) + "\u{1B}[2K" + ui.at(ui.rows, left)
            + ui.spread(ui.dim(ui.clip(text, max(0, room))), action, width: columnWidth)
    }

    private func render(_ row: Row, width: Int) -> String {
        switch row {
        case .heading(let text): return ui.dim(text)
        case .resume(let scope, let detail):
            return ui.spread(ui.bold("Continue reviewing ") + scope, ui.dim(detail), width: width)
        case .source(let source, let detail):
            return ui.spread(source.description, ui.dim(detail), width: width)
        case .months(let total):
            return ui.spread("All photos, by month…", ui.dim("\(total.formatted()) photos"), width: width)
        case .year(let year, let months, let count):
            let all = months.allSatisfy(ticked.contains), some = months.contains(where: ticked.contains)
            let box = all ? ui.green("[✓]") : some ? ui.green("[–]") : ui.dim("[ ]")
            return ui.spread(box + " " + ui.bold(String(year)), ui.dim("\(count.formatted()) photos"), width: width)
        case .month(let source, let count):
            let start = monthStart(row)
            let box = start.map(ticked.contains) == true ? ui.green("[✓]") : ui.dim("[ ]")
            let name = start.map { Self.monthName.string(from: $0) } ?? source.description
            return ui.spread("    " + box + " " + name, ui.dim("\(count.formatted()) photos"), width: width)
        case .browse(_, let title, let detail):
            return ui.spread(title, ui.dim(detail), width: width)
        case .choose:
            return ui.dim("Choose another folder…")
        case .scanHere(let url, let count):
            let here = count > 0 ? "\(count) images here, plus subfolders" : "includes subfolders"
            return ui.spread(ui.bold("Scan “\(url.lastPathComponent)”"), ui.dim(here), width: width)
        case .folder(let url):
            return url.lastPathComponent + ui.dim("  ›")
        }
    }
}
