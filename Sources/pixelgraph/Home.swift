import Foundation

/// `pixelgraph` on its own: choose where your photos are, scan, review, and
/// come back here for the next one.
final class App {
    private let options: Scanner.Options
    private let ui = UI()

    private enum Row {
        case heading(String)
        case source(Source, detail: String)
        case months(total: Int)
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

    init(options: Scanner.Options) {
        self.options = options
    }

    func run() async throws {
        // Ask for Photos access before taking over the screen, so the system
        // prompt isn't hidden. Folders still work without it.
        photosAllowed = (try? await Library.requestAccess()) != nil
        ui.enter()
        defer { ui.leave() }
        load()
        draw()
        while true {
            let key = ui.term.nextKey()
            if prompt != nil {
                if let source = editPrompt(key) { if try await scan(source) == .quit { return } }
            } else if let action = handle(key) {
                switch action {
                case .quit: return
                case .scan(let source): if try await scan(source) == .quit { return }
                }
            }
            draw()
        }
    }

    private enum Action { case quit, scan(Source) }

    // MARK: - Rows

    private func load() {
        rows = []
        switch screen {
        case .home: loadHome()
        case .months: loadMonths()
        case .browser(let url): loadFolder(url)
        }
        selected = rows.firstIndex(where: isSelectable) ?? 0
        scroll = 0
    }

    private func loadHome() {
        let recents = Recents.all()
        rows.append(.heading("PHOTOS LIBRARY · iCloud Photos"))
        if photosAllowed {
            let recentPhotos = recents.filter { $0.source.isPhotos }
            for entry in recentPhotos.prefix(3) {
                rows.append(.source(entry.source, detail: "\(entry.photos) photos · last scan: \(entry.groups) groups"))
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
            rows.append(.source(entry.source, detail: "\(entry.source.kind.lowercased()) · last scan: \(entry.groups) groups"))
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
        for month in Library.months(36) {
            rows.append(.month(.dates(from: month.start, to: month.end), count: month.count))
        }
    }

    private func loadFolder(_ url: URL) {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles])) ?? []
        let images = contents.filter { Files.imageExtensions.contains($0.pathExtension.lowercased()) }.count
        rows.append(.scanHere(url, count: images))
        let folders = contents.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && $0.lastPathComponent != Files.duplicatesFolder
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
        switch key {
        case .quit, .char("q"): return .quit
        case .up: move(-1)
        case .down: move(1)
        case .enter, .right: return activate(rows[selected], opening: key == .right)
        case .left, .escape, .backspace: back()
        case .click(let row, _):
            let index = row - 4 + scroll
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

    private func scan(_ source: Source) async throws -> ReviewSession.Outcome {
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
        let outcome = try await ReviewSession(run: run, ui: ui).show()
        screen = .home
        load()
        return outcome
    }

    // MARK: - Drawing

    private func draw() {
        let (cols, height) = (ui.cols, ui.rows)
        var out = ui.clear()
        let title: String
        switch screen {
        case .home: title = ui.bold("PixelGraph") + ui.dim("  ·  find near-identical photos and keep the best")
        case .months: title = ui.bold("Photos library") + ui.dim("  ·  choose a month")
        case .browser(let url): title = ui.bold(url.lastPathComponent) + ui.dim("  ·  " + url.deletingLastPathComponent().path)
        }
        out += ui.at(2, 3) + ui.clip(title, cols - 4)

        let listTop = 4
        let visible = max(1, height - listTop - 3)
        if selected < scroll { scroll = selected }
        if selected >= scroll + visible { scroll = selected - visible + 1 }
        for (offset, index) in rows.indices.dropFirst(scroll).prefix(visible).enumerated() {
            let line = render(rows[index], width: cols - 6)
            let r = listTop + offset
            if index == selected {
                out += ui.at(r, 2) + ui.blue("›") + " " + ui.highlight(line, width: cols - 5)
            } else {
                out += ui.at(r, 4) + line
            }
        }

        if let message { out += ui.at(height - 2, 3) + ui.clip(message, cols - 4) }
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

        let action: String
        switch rows.indices.contains(selected) ? rows[selected] : .choose {
        case .source(let source, _), .month(let source, _): action = ui.button("Scan \(ui.fit(source.description, 28))")
        case .scanHere(let url, _): action = ui.button("Scan \(ui.fit(url.lastPathComponent, 28))")
        case .browse, .folder, .months: action = ui.button("Open")
        default: action = ""
        }
        let backHint = screen == .home ? "" : " · ← back"
        let scanHint: String
        if case .browser = screen { scanHint = " · s scan this folder" } else { scanHint = "" }
        out += ui.actionBar(hints: "↑↓ choose · enter \(screen == .home ? "scan" : "open")\(scanHint)\(backHint) · q quit",
                            short: "↑↓ · enter\(backHint) · q", action: action)
        ui.term.write(out)
    }

    private func render(_ row: Row, width: Int) -> String {
        switch row {
        case .heading(let text): return ui.dim(text)
        case .source(let source, let detail):
            return ui.spread(source.description, ui.dim(detail), width: width)
        case .months(let total):
            return ui.spread("All photos, by month…", ui.dim("\(total.formatted()) photos"), width: width)
        case .month(let source, let count):
            return ui.spread(source.description.replacingOccurrences(of: "Photos, ", with: ""), ui.dim("\(count.formatted()) photos"), width: width)
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
