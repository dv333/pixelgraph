import Foundation

/// Reviewing a scan: groups first, then the photos in a group, then one photo
/// enlarged. Every photo is Keep or Move; everything but the best starts
/// selected to move, so most of the time you only confirm.
final class ReviewSession {
    /// rescan: scan the same place again, from scratch, and review that.
    enum Outcome { case quit, home, rescan }

    private(set) var run: Run
    private let runFile: URL
    private let folder: URL
    private let images: [String: Report.Images]
    private let ui: UI
    /// Started from the home screen, so Esc on the groups goes back there.
    private let fromHome: Bool

    private enum Screen { case groups, group, photo, compare }
    private enum Sheet { case reason, confirm(file: [String], duplicates: [String], describe: [String]), help, leave(Outcome), done }
    private enum Overview { case mosaic, filmstrip }
    private enum Hit { case group(Int), photo(Int), more }

    private var screen = Screen.groups
    private var sheet: Sheet?
    private var overview = Overview.mosaic
    private var groupIndex = 0
    private var cursor = 0
    /// Compare: the photo held on the left while candidates change on the right.
    private var pinned = 0
    /// z: looking closer (or comparing) shows just the faces.
    private var zoomed = false
    /// Faces found in each photo looked at closely, and its width ÷ height.
    private var faceInfo: [String: (boxes: [CGRect], aspect: Double)] = [:]
    private var scroll = 0
    /// The open group's photos in display order, fixed while it's open so
    /// numbers don't jump around as you change things.
    private var order: [Run.Member] = []
    private var hits: [(rows: ClosedRange<Int>, cols: ClosedRange<Int>, hit: Hit)] = []
    /// The message above the action bar. It stays at least a few seconds,
    /// so "Moved 34 · u undo" doesn't vanish with the next arrow key.
    private var toast: String? { didSet { if toast != nil { toastSince = .now } } }
    private var toastSince = Date.distantPast
    private var dirty = false
    /// Every group was reviewed already, so finishing isn't noted again.
    private var finished = false
    /// "Every group reviewed" has been shown (or wasn't needed: they all were at the start).
    private var announcedDone = false
    /// Settings when the review opened: what enter does in the move sheet,
    /// and whether kept photos are described.
    private let settings = Settings.load()

    /// The group to open first, e.g. g3 or j1.
    private let start: String?

    init(run: Run, runFile: URL = Paths.lastRun, folder: URL = Paths.report,
         graphics: TerminalImage.Mode = .auto, ui: UI? = nil, start: String? = nil) throws {
        self.run = run
        self.start = start
        self.runFile = runFile
        self.folder = folder
        self.images = try Report.manifest(in: folder)
        self.ui = ui ?? UI(graphics: graphics)
        self.fromHome = ui != nil
        finished = run.reviewedGroups == run.allGroups.count
        announcedDone = finished
        // A scan with only documents (or only junk) opens on the tab that has them.
        tab = tabs.first ?? .duplicates
    }

    private var source: Source { run.source ?? .dates(from: nil, to: nil) }
    private enum Tab { case duplicates, documents }
    private var tab = Tab.duplicates

    /// The groups on the current tab: lookalikes followed by the junk
    /// groups (one per reason), or documents.
    private var groups: [Run.Group] {
        get {
            switch tab {
            case .duplicates: run.groups + (run.junkGroups ?? [])
            case .documents: run.documentGroups ?? []
            }
        }
        set {
            switch tab {
            case .duplicates:
                let lookalikes = run.groups.count
                run.groups = Array(newValue.prefix(lookalikes))
                if run.junkGroups != nil { run.junkGroups = Array(newValue.dropFirst(lookalikes)) }
            case .documents: run.documentGroups = newValue
            }
        }
    }

    private var hasDocuments: Bool { !(run.documentGroups ?? []).isEmpty }
    private var junkCount: Int { (run.junkGroups ?? []).reduce(0) { $0 + $1.photos.count } }
    /// Photos from the junk groups, which move to PGJunk rather than PGDuplicates.
    private var junkIDs: Set<String> { Set((run.junkGroups ?? []).flatMap { $0.photos.map(\.id) }) }
    /// The tabs this scan has, in the order tab goes through them.
    private var tabs: [Tab] {
        let duplicates = !run.groups.isEmpty || !(run.junkGroups ?? []).isEmpty
        return (duplicates ? [.duplicates] : []) + (hasDocuments ? [.documents] : [])
    }

    private var group: Run.Group { groups[groupIndex] }
    private var pick: Pick { group.pick }

    @discardableResult
    func show() async throws -> Outcome {
        let ownsTerminal = !ui.active
        ui.enter()
        defer {
            save()
            if ownsTerminal {
                ui.leave()
                let moving = run.toMove.count
                print(moving > 0 ? "\(moving) photos still selected to move. Run `pixelgraph review` to finish." : "All done.")
            }
        }
        // Older scans don't know how big their photos are: look them up once.
        let unsized = run.unsized
        if !unsized.isEmpty {
            let sizes = Items.lookup(unsized).compactMap { id, item in item.bytes.map { (id, $0) } }
            run.fillSizes(Dictionary(sizes, uniquingKeysWith: { first, _ in first }))
            dirty = dirty || !sizes.isEmpty
        }
        if let start, let index = groupIndex(start) { open(index) }
        draw()
        while true {
            let key = ui.term.nextKey()
            // The wheel only scrolls the groups; elsewhere it changes nothing,
            // so don't redraw for it.
            if case .scroll = key, (screen != .groups && screen != .group) || sheet != nil { continue }
            if let outcome = await handle(key) { return outcome }
            noteSeen()
            announceIfDone()
            draw()
        }
    }

    private func save() {
        guard dirty else { return }
        try? run.save(to: runFile)
        try? Report.render(run, images: images, in: folder)
        Decisions.record(run)
        dirty = false
        if !finished, run.reviewedGroups == run.allGroups.count {
            finished = true
            Places.note(.reviewed, run.source)
        }
    }

    // MARK: - Input

    /// Returns an outcome to leave the review.
    private func handle(_ key: Terminal.Key) async -> Outcome? {
        if key == .resize { return nil }
        if Date.now.timeIntervalSince(toastSince) > 4 { toast = nil }
        await refreshEdited()

        // Leaving always asks first: a stray Esc or q shouldn't end a long review.
        if case .leave(let outcome)? = sheet {
            switch key {
            case .enter, .char("y"):
                sheet = nil
                return outcome
            case .quit, .char("q"):
                // q again while asked to quit means yes; on "back home" it asks to quit instead.
                if outcome == .quit {
                    sheet = nil
                    return .quit
                }
                sheet = .leave(.quit)
            case .click(let row, let col):
                switch ui.sheetClick(row: row, col: col) {
                case .button:
                    sheet = nil
                    return outcome
                case .outside:
                    sheet = nil
                    needsFull = true
                case .inside: break
                }
            case .escape, .backspace, .char("n"):
                sheet = nil
                needsFull = true
            default: break
            }
            return nil
        }
        // q and ctrl-c ask before quitting, from anywhere.
        if key == .quit || key == .char("q") {
            sheet = .leave(.quit)
            return nil
        }
        if let sheet {
            await handleSheet(sheet, key)
            return nil
        }
        if key == .char("?") {
            sheet = .help
            return nil
        }

        switch screen {
        case .groups:
            let perRow = overview == .mosaic ? mosaicLayout().perRow : 1
            let page = perRow * (overview == .mosaic ? mosaicLayout().visibleRows : filmstripVisible)
            switch key {
            case .left: select(groupIndex - 1)
            case .right: select(groupIndex + 1)
            case .up: select(groupIndex - perRow)
            case .down: select(groupIndex + perRow)
            case .pageDown: select(groupIndex + page)
            case .pageUp: select(groupIndex - page)
            case .home: select(0)
            case .end: select(groups.count - 1)
            case .char("]"), .char("["):
                if let next = unreviewed(from: groupIndex, step: key == .char("]") ? 1 : -1) { select(next) } else { allReviewed() }
            case .scroll(let ticks):
                // About three wheel ticks a row, at most two rows a step.
                let rows = ticks > 0 ? min(2, max(1, ticks / 3)) : max(-2, min(-1, ticks / 3))
                scrollBy(rows, perRow: perRow, page: page)
            case .enter, .char(" "): open(groupIndex)
            case .char("k"): keepGroup(groupIndex)
            case .char("x"): moveGroupRest(groupIndex)
            case .char("v"): overview = overview == .mosaic ? .filmstrip : .mosaic; scroll = 0
            case .char("a"): acceptClear()
            case .char("m"): askToMove(everything: true)
            case .char("R"):
                guard run.source != nil else {
                    toast = ui.dim("This scan is too old to scan again from here; start it from the start screen.")
                    break
                }
                sheet = .leave(.rescan)
            case .tab:
                guard tabs.count > 1 else {
                    toast = ui.dim(tab == .documents ? "No lookalikes or junk in this scan." : "No documents in this scan.")
                    break
                }
                tab = tabs[((tabs.firstIndex(of: tab) ?? 0) + 1) % tabs.count]
                groupIndex = 0
                scroll = 0
                needsFull = true
            case .char("u"): await undo()
            case .escape where fromHome: sheet = .leave(.home)
            case .click(let row, let col):
                switch hit(row, col) {
                case .group(let i)?: open(i)
                case .more?: select(groupIndex + page)
                default: break
                }
            default: break
            }

        case .group:
            let perRow = gridLayout.perRow
            if allSelected {
                // A selected every photo: the next K, X, R or M applies to all of them.
                allSelected = false
                needsFull = true
                switch key {
                case .char("k"): keepAll(); return nil
                case .char("x"): moveAll(); return nil
                case .char("r"):
                    allSelected = true
                    sheet = .reason
                    return nil
                case .char("m"):
                    moveAll()
                    askToMove(everything: false)
                    return nil
                case .char("e"):
                    await editPhotos(order.map(\.id))
                    return nil
                case .escape, .backspace, .char("a"):
                    toast = ui.dim("Selection cleared")
                    return nil
                default: break
                }
            }
            switch key {
            case .char("a"):
                allSelected = true
                needsFull = true
                toast = ui.blue("All \(order.count) photos selected") + ui.dim(" · k keep · x move · r reason · m move now · esc clear")
            case .left: cursor = max(0, cursor - 1)
            case .right: cursor = min(order.count - 1, cursor + 1)
            case .up: cursor = max(0, cursor - perRow)
            case .down: cursor = min(order.count - 1, cursor + perRow)
            // Space looks closer, like Quick Look in Finder.
            case .enter, .char(" "): screen = .photo
            case .scroll(let ticks): cursor = min(max(0, cursor + (ticks > 0 ? perRow : -perRow)), order.count - 1)
            case .home: cursor = 0
            case .end: cursor = order.count - 1
            case .char("i"):
                details.toggle()
                needsFull = true
            case .char("]"), .char("["):
                if let next = unreviewed(from: groupIndex, step: key == .char("]") ? 1 : -1) { open(next) } else { allReviewed() }
            case .char(let c) where ("1"..."9").contains(c):
                // The number on a tile goes straight to it.
                if let n = c.wholeNumberValue, n <= order.count { cursor = n - 1 }
            case .pageDown, .pageUp:
                let page = gridLayout.visible
                cursor = min(max(0, cursor + (key == .pageDown ? page : -page)), order.count - 1)
            case .char("c"): openCompare()
            case .char("o"): reveal(order[cursor].id)
            case .char("e"): await editPhotos([order[cursor].id])
            case .char("k"): keep(order[cursor].id)
            case .char("x"): markMove(order[cursor].id)
            case .char("b"): makeBest(order[cursor].id)
            case .char("r"): if !pick.moved.contains(order[cursor].id) { sheet = .reason }
            case .char("m"): askToMove(everything: false)
            case .char("d"): fileAsDocument(order[cursor].id)
            case .char("u"): await undo()
            case .char("n"): open(groupIndex + 1)
            case .char("p"): open(groupIndex - 1)
            case .escape, .backspace: screen = .groups
            case .click(let row, let col):
                if case .photo(let i)? = hit(row, col) { cursor = i; screen = .photo }
            default: break
            }

        case .photo:
            switch key {
            case .left, .up: cursor = (cursor - 1 + order.count) % order.count
            case .right, .down: cursor = (cursor + 1) % order.count
            case .home: cursor = 0
            case .end: cursor = order.count - 1
            case .char(let c) where ("1"..."9").contains(c):
                if let n = c.wholeNumberValue, n <= order.count { cursor = n - 1 }
            case .char("z"): toggleZoom([order[cursor]])
            case .char("c"): openCompare()
            case .char("o"): reveal(order[cursor].id)
            case .char("e"): await editPhotos([order[cursor].id])
            case .char("k"): keep(order[cursor].id)
            case .char("x"): markMove(order[cursor].id)
            case .char("b"): makeBest(order[cursor].id)
            case .char("r"): if !pick.moved.contains(order[cursor].id) { sheet = .reason }
            case .escape, .backspace, .enter, .click, .char(" "):
                screen = .group
                zoomed = false
            default: break
            }

        case .compare:
            switch key {
            case .right, .down: cursor = nextCandidate(after: cursor, step: 1)
            case .left: cursor = nextCandidate(after: cursor, step: -1)
            case .up, .tab: swap(&pinned, &cursor)
            case .char("z"): toggleZoom([order[pinned], order[cursor]])
            case .char("o"): reveal(order[cursor].id)
            case .char("e"): await editPhotos([order[cursor].id])
            case .char("k"): keep(order[cursor].id)
            case .char("x"): markMove(order[cursor].id)
            case .char("b"): makeBest(order[cursor].id)
            case .char("r"): if !pick.moved.contains(order[cursor].id) { sheet = .reason }
            case .char(" "), .enter: screen = .photo
            case .escape, .backspace, .char("c"), .click:
                screen = .group
                zoomed = false
            default: break
            }
        }
        return nil
    }

    private func handleSheet(_ current: Sheet, _ key: Terminal.Key) async {
        switch current {
        case .reason:
            let id = order[cursor].id
            let forAll = allSelected
            func apply(_ reason: String) {
                if forAll { reasonForAll(reason) } else { setReason(id, reason) }
                sheet = nil
                allSelected = false
                needsFull = true
            }
            switch key {
            case .click(let row, let col) where ui.sheetClick(row: row, col: col) != .outside: break
            case .escape, .backspace, .click:
                sheet = nil
                allSelected = false
                needsFull = true
            case .enter: apply(forAll ? "other" : pick.suggestions[id] ?? "other")
            case .char(let c):
                guard let n = c.wholeNumberValue, (1...Inspector.reasons.count).contains(n) else { return }
                apply(Inspector.reasons[n - 1])
            default: break
            }
        case .help:
            sheet = nil
        case .done:
            switch key {
            case .enter, .char("m"), .click where ui.sheetClick(key) == .button(danger: false):
                screen = .groups
                askToMove(everything: true)
                if case .done? = sheet { sheet = nil }
            case .click where ui.sheetClick(key) == .inside: break
            case .resize: break
            default:
                sheet = nil
                needsFull = true
            }
        case .leave:
            break
        case .confirm(let file, let duplicates, let describe):
            switch key {
            case .enter, .char("y"), .char("p"), .click where ui.sheetClick(key) == .button(danger: false):
                sheet = nil
                await move(file: file, duplicates: duplicates, to: .duplicates, describe: describe)
            case .char("d") where !duplicates.isEmpty, .click where ui.sheetClick(key) == .button(danger: true):
                sheet = nil
                await move(file: file, duplicates: duplicates, to: .trash, describe: describe)
            case .click where ui.sheetClick(key) == .inside: break
            case .escape, .backspace, .click, .char("n"): sheet = nil
            default: break
            }
        }
    }

    /// z: in on the faces, or back out to the whole photo. Stays in as you
    /// go from photo to photo, so the same faces can be checked shot by shot.
    private func toggleZoom(_ members: [Run.Member]) {
        zoomed.toggle()
        guard zoomed, !members.contains(where: { faceCrop($0, cols: 8, rows: 4) != nil }) else { return }
        zoomed = false
        toast = ui.dim(members.count == 1 ? "No faces found in this photo" : "No faces found in these photos")
    }

    /// The part of a photo to show in a box of `cols` × `rows` while zoomed:
    /// all its faces, with room around them. Nil when not zoomed or no faces.
    private func faceCrop(_ member: Run.Member, cols: Int, rows: Int) -> CGRect? {
        guard zoomed, let files = images[member.id] else { return nil }
        if faceInfo[member.id] == nil {
            let image = TerminalImage.load(folder.appendingPathComponent(files.full), maxSide: 1024)
            faceInfo[member.id] = image.map { (Faces.boxes(in: $0), Double($0.width) / Double(max(1, $0.height))) } ?? ([], 1)
        }
        guard let info = faceInfo[member.id] else { return nil }
        return Faces.crop(info.boxes, aspect: info.aspect, boxAspect: Double(cols) * ui.term.cellAspect / Double(max(1, rows)))
    }

    /// Compare starts with the best shot pinned on the left and the photo
    /// under the cursor (or the next one) as the candidate.
    private func openCompare() {
        guard order.count > 1 else { return }
        pinned = order.firstIndex { pick.keepers.contains($0.id) } ?? 0
        if cursor == pinned { cursor = nextCandidate(after: pinned, step: 1) }
        screen = .compare
    }

    private func nextCandidate(after index: Int, step: Int) -> Int {
        var next = (index + step + order.count) % order.count
        if next == pinned { next = (next + step + order.count) % order.count }
        return next
    }

    /// Mouse wheel on the groups: move the view a row at a time, keeping the
    /// selection on screen.
    private func scrollBy(_ rows: Int, perRow: Int, page: Int) {
        let lastFirst = max(0, (groups.count - 1) / perRow - (page / perRow) + 1)
        scroll = min(max(0, scroll + rows), lastFirst)
        let first = scroll * perRow
        if groupIndex < first { groupIndex = first }
        if groupIndex >= first + page { groupIndex = min(groups.count - 1, first + page - 1) }
    }

    private func hit(_ row: Int, _ col: Int) -> Hit? {
        hits.first { $0.rows.contains(row) && $0.cols.contains(col) }?.hit
    }

    private func select(_ index: Int) {
        groupIndex = min(max(index, 0), groups.count - 1)
    }

    /// ] and [: the next (or previous) group without a ✓, going round; nil
    /// when every group on this tab has one.
    private func unreviewed(from index: Int, step: Int) -> Int? {
        guard !groups.isEmpty else { return nil }
        for k in 1...groups.count {
            let i = ((index + step * k) % groups.count + groups.count) % groups.count
            if groups[i].reviewed != true { return i }
        }
        return nil
    }

    private func allReviewed() {
        toast = ui.green("✓") + " Every group here is reviewed" + ui.dim(run.waiting > 0 ? " · m to move what's selected" : "")
    }

    /// Where g3 (lookalikes) or j1 (junk) is on the Duplicates tab, which
    /// lists the lookalikes and then the junk.
    private func groupIndex(_ id: String) -> Int? {
        guard let kind = id.lowercased().first, let n = Int(id.dropFirst()), n >= 1 else { return nil }
        if kind == "g", n <= run.groups.count { return n - 1 }
        if kind == "j", n <= (run.junkGroups ?? []).count { return run.groups.count + n - 1 }
        return nil
    }

    private func open(_ index: Int) {
        select(index)
        order = Run.displayOrder(group)
        cursor = 0
        zoomed = false
        gridScroll = 0
        seen = []
        allSelected = false
        screen = .group
    }

    // MARK: - Show in Finder

    /// o: shows a photo where it lives: selected in Finder for files (in
    /// PGDuplicates or the Trash if it has been moved), in Photos for the library.
    private func reveal(_ id: String) {
        if id.hasPrefix("file:") {
            var path = String(id.dropFirst(5))
            if !FileManager.default.fileExists(atPath: path),
               let moved = Mover.history().reversed().lazy.flatMap(\.files).first(where: { $0.from == path }) {
                path = moved.to
            }
            guard FileManager.default.fileExists(atPath: path) else {
                toast = ui.dim("Can't find that file any more")
                return
            }
            launch(["/usr/bin/open", "-R", path])
            toast = ui.green("✓") + " Shown in Finder"
        } else {
            launch(["/usr/bin/osascript", "-e", "on run argv", "-e", "tell application \"Photos\"", "-e", "activate",
                 "-e", "spotlight media item id (item 1 of argv)", "-e", "end tell", "-e", "end run", id])
            toast = ui.green("✓") + " Shown in Photos"
        }
    }

    // MARK: - Edit in Photos

    /// Photos sent off to be edited, with when each was last changed, so
    /// their previews are made again once the edit is saved.
    private var editing: [String: Date] = [:]
    private var lastEditCheck = Date.distantPast

    /// e: library photos open in Photos' editor (one straight into Edit;
    /// several in the "PG Edit" album); files open in Preview.
    private func editPhotos(_ ids: [String]) async {
        let items = Items.lookup(ids)
        for id in ids { if let item = items[id] { editing[id] = item.modified } }
        let files = ids.filter { $0.hasPrefix("file:") }.compactMap { id -> String? in
            var path = String(id.dropFirst(5))
            if !FileManager.default.fileExists(atPath: path),
               let moved = Mover.history().reversed().lazy.flatMap(\.files).first(where: { $0.from == path }) {
                path = moved.to
            }
            return FileManager.default.fileExists(atPath: path) ? path : nil
        }
        let library = ids.filter { !$0.hasPrefix("file:") }
        var said: [String] = []
        if !files.isEmpty {
            launch(["/usr/bin/open", "-a", "Preview"] + files)
            said.append("\(files.count == 1 ? "Opened" : "Opened \(files.count)") in Preview")
        }
        if library.count == 1, let id = library.first {
            // Show it, then Return, which is Edit in Photos. Pressing a key
            // needs Accessibility permission; without it the photo is just shown.
            launch(["/usr/bin/osascript", "-e", "on run argv",
                    "-e", "tell application \"Photos\"", "-e", "activate",
                    "-e", "spotlight media item id (item 1 of argv)", "-e", "end tell",
                    "-e", "delay 1.2",
                    "-e", "try", "-e", "tell application \"System Events\" to keystroke return", "-e", "end try",
                    "-e", "end run", id])
            said.append("Opened in Photos' editor (only shown? press Return there)")
        } else if library.count > 1 {
            do {
                try await Library.fillEditAlbum(library)
                launch(["/usr/bin/osascript", "-e", "tell application \"Photos\"", "-e", "activate",
                        "-e", "spotlight (first album whose name is \"\(Library.editAlbum)\")", "-e", "end tell"])
                said.append("\(library.count) in the “\(Library.editAlbum)” album in Photos: Return edits, → next")
            } catch {
                toast = ui.red("Couldn't open them in Photos: \(error.localizedDescription)")
                return
            }
        }
        guard !said.isEmpty else {
            toast = ui.dim("Can't find that photo any more")
            return
        }
        toast = ui.green("✓") + " " + said.joined(separator: " · ") + ui.dim(" · previews update when you're back")
    }

    /// Makes new previews for photos edited since e sent them off, at most
    /// every couple of seconds, so the review shows the edit.
    private func refreshEdited() async {
        guard !editing.isEmpty, Date.now.timeIntervalSince(lastEditCheck) > 2 else { return }
        lastEditCheck = .now
        let items = Items.lookup(Array(editing.keys))
        var updated = 0
        for (id, before) in editing {
            guard let item = items[id], item.modified > before, images[id] != nil,
                  let thumb = await item.image(maxSide: Report.thumbSide, fetch: .localOnly),
                  let full = await item.image(maxSide: Report.fullSide, fetch: .download(timeout: 30)) else { continue }
            // Same file names as before, so the review picks them up as they are.
            _ = Report.save(thumb: thumb, full: full, as: Report.previewName(id), in: folder)
            editing[id] = item.modified
            updated += 1
        }
        guard updated > 0 else { return }
        ui.forgetImages()
        needsFull = true
        toast = ui.green("✓") + " Showing your edit" + (updated == 1 ? "" : "s to \(updated) photos")
    }

    private func launch(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    // MARK: - Reviewed
    //
    // A group gets its ✓ once you've acted on it (kept, moved, changed the
    // best, given a reason), once nothing in it is left to do, or once you've
    // looked at every photo in it. Opening it alone doesn't count.

    /// Photos in the open group you've had the highlight on.
    private var seen: Set<String> = []

    private func markReviewed(_ g: Int) {
        guard groups.indices.contains(g), groups[g].reviewed != true else { return }
        groups[g].reviewed = true
        dirty = true
        changed.insert(g)
    }

    /// Notes the photo under the highlight (and the pinned one in compare);
    /// when every photo in the group has been looked at, it's reviewed.
    private func noteSeen() {
        guard screen != .groups, order.indices.contains(cursor) else { return }
        seen.insert(order[cursor].id)
        if screen == .compare, order.indices.contains(pinned) { seen.insert(order[pinned].id) }
        if order.allSatisfy({ seen.contains($0.id) }) { markReviewed(groupIndex) }
    }

    /// Every group, on any tab, that a move took photos from.
    private func markReviewed(containing ids: [String]) {
        let set = Set(ids)
        func mark(_ list: inout [Run.Group]) {
            for g in list.indices where list[g].photos.contains(where: { set.contains($0.id) }) { list[g].reviewed = true }
        }
        mark(&run.groups)
        if run.documentGroups != nil { mark(&run.documentGroups!) }
        if run.junkGroups != nil { mark(&run.junkGroups!) }
    }

    // MARK: - Keep and move
    //
    // Keys set a state rather than toggle it, so pressing twice can't undo
    // what you meant; every change can be undone with u.

    private enum Action {
        case mark(tab: Tab, group: Int, before: Pick)
        case move([String])
        /// a on the groups: these lookalike groups were accepted as they are.
        case accept([Int])
    }

    private var history: [Action] = []

    private func edit(_ index: Int? = nil, say message: String? = nil, _ change: (inout Pick) -> Void) {
        let g = index ?? groupIndex
        // Acting on a group reviews it, even when the choice was already so.
        markReviewed(g)
        let before = groups[g].pick
        change(&groups[g].pick)
        if let first = groups[g].pick.keepers.first { groups[g].pick.best = first }
        guard groups[g].pick.keepers != before.keepers || groups[g].pick.kept != before.kept
            || groups[g].pick.reasons != before.reasons else {
            if let message { toast = ui.dim(message + " already") }
            return
        }
        groups[g].pick.decidedBy = "you"
        history.append(.mark(tab: tab, group: g, before: before))
        dirty = true
        noteChanges(in: g, from: before)
        if let message { toast = message + ui.dim(" · ") + ui.blue("u") + ui.dim(" undo") }
    }

    /// Records which cards or tiles a change touched, so only those repaint.
    private func noteChanges(in g: Int, from before: Pick) {
        if screen == .groups {
            changed.insert(g)
            return
        }
        let after = groups[g].pick
        for (index, member) in order.enumerated() {
            let id = member.id
            // Your first change also rewords every "Keep" caption to "you chose".
            let reworded = before.decidedBy != "you" && after.isKept(id) && !after.keepers.contains(id)
            if reworded || before.keepers.contains(id) != after.keepers.contains(id) || before.isKept(id) != after.isKept(id)
                || before.reasons[id] != after.reasons[id] {
                changed.insert(index)
            }
        }
    }

    private func name(_ id: String) -> String {
        "Photo \((order.firstIndex { $0.id == id } ?? 0) + 1)"
    }

    private func keep(_ id: String) {
        guard !pick.moved.contains(id) else { return movedAlready() }
        edit(say: "\(name(id)) → Keep") { pick in
            if !pick.isKept(id) { pick.kept.append(id) }
            pick.reasons[id] = nil
        }
    }

    private func markMove(_ id: String) {
        guard !pick.moved.contains(id) else { return movedAlready() }
        edit(say: "\(name(id)) → Move") { pick in
            pick.keepers.removeAll { $0 == id }
            pick.kept.removeAll { $0 == id }
        }
    }

    private func makeBest(_ id: String) {
        guard !pick.moved.contains(id) else { return movedAlready() }
        edit(say: "\(name(id)) → ★ Best") { pick in
            pick.kept.removeAll { $0 == id }
            if !pick.keepers.contains(id) { pick.keepers.append(id) }
            pick.reasons[id] = nil
        }
    }

    /// d: on the Documents tab, file this copy in PGDocuments.
    private func fileAsDocument(_ id: String) {
        guard tab == .documents else {
            toast = ui.dim("Documents are on their own tab · press tab on the groups screen")
            return
        }
        guard !pick.moved.contains(id) else { return movedAlready() }
        edit(say: "\(name(id)) → PGDocuments") { pick in
            pick.kept.removeAll { $0 == id }
            if !pick.keepers.contains(id) { pick.keepers.append(id) }
        }
    }

    /// A then K, X or R: every photo in the group not already moved.
    private var allSelected = false

    private var movable: [String] { group.photos.map(\.id).filter { !pick.moved.contains($0) } }

    private func keepAll() {
        let ids = movable
        edit(say: "All \(ids.count) → Keep") { pick in
            for id in ids where !pick.isKept(id) { pick.kept.append(id) }
            for id in ids { pick.reasons[id] = nil }
        }
    }

    /// Every photo to move, the best included, so the group is emptied.
    private func moveAll() {
        let ids = movable
        edit(say: "All \(ids.count) → Move") { pick in
            pick.keepers.removeAll { ids.contains($0) }
            pick.kept.removeAll { ids.contains($0) }
        }
    }

    private func reasonForAll(_ reason: String) {
        let ids = movable
        edit(say: "All \(ids.count) → Move · \(reason)") { pick in
            pick.keepers.removeAll { ids.contains($0) }
            pick.kept.removeAll { ids.contains($0) }
            for id in ids { pick.reasons[id] = reason }
        }
    }

    private func setReason(_ id: String, _ reason: String) {
        edit(say: "\(name(id)) → Move · \(reason)") { pick in
            pick.reasons[id] = reason
            pick.keepers.removeAll { $0 == id }
            pick.kept.removeAll { $0 == id }
        }
    }

    private func movedAlready() {
        toast = ui.dim("Already moved · u to put it back")
    }

    /// k on a group: keep every photo in it.
    private func keepGroup(_ index: Int) {
        let g = groups[index]
        let movable = g.photos.map(\.id).filter { !g.pick.moved.contains($0) }
        edit(index, say: "Group \(index + 1) → keep all") { pick in
            pick.kept = movable.filter { !pick.keepers.contains($0) }
        }
    }

    /// x on a group: back to keeping the best and moving the rest.
    private func moveGroupRest(_ index: Int) {
        let g = groups[index]
        let movable = g.photos.map(\.id).filter { !g.pick.moved.contains($0) }
        edit(index, say: "Group \(index + 1) → move all but the best") { pick in
            pick.kept = []
            pick.reasons = [:]
            if pick.keepers.isEmpty, let first = movable.first { pick.keepers = [first] }
        }
    }

    /// m: on the Duplicates tab, move what's selected; on the Documents tab,
    /// file the documents in PGDocuments and move their extra copies.
    private func askToMove(everything: Bool) {
        let scope = everything ? groups : [group]
        let selected = scope.flatMap { g in g.photos.map(\.id).filter { g.pick.willMove($0) } }
        let file = tab == .documents ? scope.flatMap { g in g.pick.keepers.filter { !g.pick.moved.contains($0) } } : []
        guard !selected.isEmpty || !file.isEmpty else {
            toast = ui.dim("Nothing selected to move.")
            return
        }
        // The photos kept in the groups something is leaving, not yet captioned.
        let leaving = Set(selected + file)
        let describe = tab == .duplicates && settings.bool(.moveDescribe)
            ? scope.filter { g in g.photos.contains { leaving.contains($0.id) } }
                .flatMap { g in g.photos.filter { g.pick.isKept($0.id) && !g.pick.moved.contains($0.id) && $0.captioned != true }.map(\.id) }
            : []
        sheet = .confirm(file: file, duplicates: selected, describe: describe)
    }

    private func move(file: [String], duplicates: [String], to target: Mover.Destination, describe keepers: [String]) async {
        func count(_ n: Int) -> String { "\(n) photo\(n == 1 ? "" : "s")" }
        let deletes = target == .trash
        let bin = source.isPhotos ? "Recently Deleted" : "the Trash"
        let total = (file.isEmpty ? 0 : 1) + (duplicates.isEmpty ? 0 : 1) + keepers.count
        var done = 0
        func step(_ detail: String) { showProgress(done: done, total: total, detail: detail) }
        defer { needsFull = true }
        // Take the confirm sheet off the screen first: the progress panel is
        // smaller and would leave the sheet's edges showing around it.
        needsFull = true
        draw()
        do {
            let batch = UUID()
            var records: [Mover.Record] = []
            if !file.isEmpty {
                step("Filing \(count(file.count)) in PGDocuments…")
                records.append(try await Mover.move(file, from: source, to: .documents, batch: batch))
                done += 1
            }
            if !duplicates.isEmpty {
                if deletes {
                    step("Deleting \(count(duplicates.count))…")
                    records.append(try await Mover.move(duplicates, from: source, to: .trash, batch: batch))
                } else {
                    // Junk goes to its own album or folder, apart from the duplicates.
                    let junk = junkIDs
                    let copies = duplicates.filter { !junk.contains($0) }, rejects = duplicates.filter { junk.contains($0) }
                    if !copies.isEmpty {
                        step("Moving \(count(copies.count)) to PGDuplicates…")
                        records.append(try await Mover.move(copies, from: source, to: .duplicates, batch: batch))
                    }
                    if !rejects.isEmpty {
                        step("Moving \(count(rejects.count)) to PGJunk…")
                        records.append(try await Mover.move(rejects, from: source, to: .junk, batch: batch))
                    }
                }
                done += 1
            }
            run.markMoved(file + duplicates)
            markReviewed(containing: file + duplicates)
            let base = done
            let (captioned, captionError) = await writeCaptions(keepers, batch: batch) { n in
                done = base + n
                step("Describing kept photo \(n + 1) of \(keepers.count)…")
            }
            run.markCaptioned(captioned)
            history.append(.move(file + duplicates))
            dirty = true
            needsFull = true
            save()
            var parts: [String] = []
            if !file.isEmpty { parts.append("filed \(file.count) in PGDocuments") }
            if !duplicates.isEmpty {
                let junkIDs = self.junkIDs
                let junk = duplicates.filter { junkIDs.contains($0) }.count
                if deletes {
                    parts.append("deleted \(duplicates.count) to \(bin)")
                } else {
                    if duplicates.count > junk { parts.append("moved \(duplicates.count - junk) to PGDuplicates") }
                    if junk > 0 { parts.append("moved \(junk) junk to PGJunk") }
                }
            }
            if !captioned.isEmpty { parts.append("described \(captioned.count) kept") }
            var message = ui.green("✓") + " " + parts.joined(separator: ", ").capitalizedFirst
            if let total = run.bytes(file + duplicates) { message += ui.dim(" · " + Run.size(total)) }
            if case .album(let id, let name) = source, records.contains(where: { $0.leftInSource == true }) {
                message += ui.amber(" · still in \(name) too: it’s \(Library.readOnlyReason(id) ?? "read-only")")
            }
            if let captionError { message += ui.amber(" · couldn’t describe: \(captionError.localizedDescription)") }
            if records.contains(where: { $0.deleted != true }) || !captioned.isEmpty { message += " · " + ui.blue("u") + ui.dim(" undo") }
            toast = message
        } catch {
            toast = ui.red("Couldn't move: \(error.localizedDescription)")
        }
    }

    /// Writes a caption, title and keywords to the photos kept, logged with
    /// the move's batch so undo puts the old ones back. Stops at the first
    /// failure, usually no permission to control Photos.
    private func writeCaptions(_ ids: [String], batch: UUID,
                               progress: (Int) -> Void) async -> (written: [String], error: Error?) {
        guard !ids.isEmpty else { return ([], nil) }
        let items = Items.lookup(ids)
        let useModel = settings.bool(.model) && Picker.modelAvailable
        var changes: [Captions.Change] = []
        var failure: Error?
        for (n, id) in ids.enumerated() {
            progress(n)
            guard let item = items[id], let fields = await Captions.make(item, useModel: useModel) else { continue }
            do {
                if let change = try await Captions.write(fields, to: id) { changes.append(change) }
            } catch {
                failure = error
                break
            }
        }
        do { try Mover.logCaptions(changes, source: source, batch: batch) } catch { failure = failure ?? error }
        return (changes.map(\.id), failure)
    }

    /// A sheet with a progress bar, drawn straight away while a move runs.
    private func showProgress(done: Int, total: Int, detail: String) {
        let fraction = total == 0 ? 1 : Double(done) / Double(total)
        let percent = "\(Int((fraction * 100).rounded()))%"
        let width = min(ui.cols - 2, 60) - 4
        ui.term.write(ui.sheet([ui.bold(detail), "",
                                ProgressBoard.bar(fraction, width: max(4, width - percent.count - 2)) + "  " + ui.dim(percent)]))
    }

    /// A lookalike group PixelGraph is sure about: every photo it selected to
    /// move is one the nightly clean-up would move on its own (an exact copy,
    /// or a shot well behind a clean best). Close calls never are.
    private func isClear(_ g: Run.Group) -> Bool {
        let waiting = g.photos.map(\.id).filter { g.pick.willMove($0) }
        return !waiting.isEmpty && g.pick.decidedBy != "you" && Set(Agent.clearMoves(g)) == Set(waiting)
    }

    /// a on the groups: marks every clear group reviewed, as PixelGraph
    /// chose, and goes to the first group still to look at. m then moves
    /// everything selected; u takes the acceptance back.
    private func acceptClear() {
        guard tab == .duplicates else {
            toast = ui.dim("Documents always wait for you · accepting is for lookalike groups")
            return
        }
        let clear = groups.indices.filter { groups[$0].reviewed != true && groups[$0].kind != .junk && isClear(groups[$0]) }
        guard !clear.isEmpty else {
            toast = ui.dim("No clear groups left to accept · the rest need a look")
            return
        }
        for g in clear { groups[g].reviewed = true }
        history.append(.accept(clear))
        dirty = true
        needsFull = true
        let photos = clear.reduce(0) { n, g in n + groups[g].photos.filter { groups[g].pick.willMove($0.id) }.count }
        let left = groups.indices.filter { groups[$0].reviewed != true }
        if let first = left.first { groupIndex = first }
        toast = ui.green("✓") + " Accepted \(clear.count) clear group\(clear.count == 1 ? "" : "s") (\(photos) photo\(photos == 1 ? "" : "s") to move)"
            + ui.dim(left.isEmpty ? " · every group reviewed" : " · \(left.count) left to look at") + ui.dim(" · ") + ui.blue("u") + ui.dim(" undo")
    }

    /// Undoes the last thing you did: a mark, an acceptance, or a move (this
    /// session's, or the last one saved from before).
    private func undo() async {
        if case .accept(let accepted)? = history.last {
            history.removeLast()
            let current = tab
            tab = .duplicates
            for g in accepted where groups.indices.contains(g) { groups[g].reviewed = nil }
            tab = current
            dirty = true
            needsFull = true
            toast = ui.green("✓") + " Undone · \(accepted.count) group\(accepted.count == 1 ? "" : "s") to look at again"
            return
        }
        if case .mark(let markTab, let g, let before)? = history.last {
            history.removeLast()
            let current = tab
            tab = markTab
            groups[g].pick = before
            tab = current
            dirty = true
            needsFull = true
            toast = ui.green("✓") + " Undone"
            return
        }
        if case .move? = history.last { history.removeLast() }
        guard let last = Mover.history().last, last.source == source else {
            toast = ui.dim("Nothing to undo.")
            return
        }
        do {
            guard let undone = try await Mover.undoLast() else { return }
            run.unmark(undone.ids)
            run.markCaptioned(undone.captioned, false)
            dirty = true
            needsFull = true
            save()
            func count(_ n: Int) -> String { "\(n) photo\(n == 1 ? "" : "s")" }
            var parts: [String] = []
            if !undone.ids.isEmpty { parts.append(ui.green("✓") + " Put back \(count(undone.ids.count))") }
            if !undone.captioned.isEmpty { parts.append(ui.green("✓") + " Old captions back on \(count(undone.captioned.count))") }
            if !undone.deleted.isEmpty {
                parts.append(ui.amber("\(count(undone.deleted.count)) deleted: recover in Photos → Recently Deleted"))
            }
            toast = parts.joined(separator: ui.dim(" · "))
        } catch {
            toast = ui.red("Couldn't undo: \(error.localizedDescription)")
        }
    }

    // MARK: - Drawing

    /// What the last full frame showed, apart from the selection.
    private var drawnFrame: String?
    /// The selected card or tile when the screen was last drawn.
    private var drawnSelection = -1
    private var drawnTitle = ""
    /// Cards or tiles whose content changed since the last draw.
    private var changed: Set<Int> = []
    /// Set when many things change at once (a move, an undo).
    private var needsFull = true

    /// Everything that, if different, means the whole screen must be redrawn.
    private func frameKey() -> String {
        let s: String
        switch screen {
        case .groups: s = "groups \(overview) \(scroll)"
        case .group: s = "group \(groupIndex) \(gridScroll) \(allSelected) \(details)"
        case .photo: s = "photo \(groupIndex) \(cursor) \(zoomed)"
        case .compare: s = "compare \(groupIndex) \(pinned) \(cursor) \(zoomed)"
        }
        return "\(s) \(ui.cols)x\(ui.rows) \(sheet == nil)"
    }

    private var selection: Int { screen == .groups ? groupIndex : cursor }

    /// Redraws only what changed when the screen is otherwise the same:
    /// moving the selection repaints two frames, marking a photo repaints its
    /// tile. Everything else repaints the whole screen.
    private func draw() {
        if ui.tooSmall {
            ui.term.write(ui.tooSmallScreen())
            needsFull = true
            drawnFrame = nil
            return
        }
        let title = "PixelGraph · \(run.scope) · \(run.reviewedGroups)/\(run.allGroups.count) reviewed"
        if title != drawnTitle {
            ui.term.write(ui.title(title))
            drawnTitle = title
        }
        if screen == .group { keepGridVisible() }
        if screen == .groups { keepSelectionVisible() }
        let key = frameKey()
        let partial = !needsFull && sheet == nil && key == drawnFrame && (screen == .groups || screen == .group)
        var out: String
        if partial {
            out = ""
            for index in changed.union([drawnSelection, selection]) {
                out += item(index, content: changed.contains(index))
            }
            let (first, last) = currentRange()
            out += screen == .groups ? overviewHeader(range: range(first: first, shown: last - first)) : groupHeader()
            out += footer()
        } else {
            hits = []
            out = ui.clear()
            switch screen {
            case .groups: out += overview == .mosaic ? mosaic() : filmstrip()
            case .group: out += groupGrid()
            case .photo: out += photoView()
            case .compare: out += compareView()
            }
        }
        out += toastLine()
        switch sheet {
        case .reason: out += reasonSheet()
        case .confirm(let file, let duplicates, let describe): out += confirmSheet(file: file, duplicates: duplicates, describe: describe)
        case .help: out += helpSheet()
        case .done: out += doneSheet()
        case .leave(let outcome): out += leaveSheet(outcome)
        case nil: break
        }
        ui.term.write(out)
        drawnFrame = key
        drawnSelection = selection
        changed = []
        needsFull = false
    }

    /// The row above the action bar: a message if there is one, otherwise
    /// what normally lives there.
    private func toastLine() -> String {
        let row = ui.rows - 1
        if let toast { return ui.at(row, 1) + "\u{1B}[2K " + ui.center(toast, width: ui.cols - 2) }
        if screen == .group { return ui.at(row, 1) + "\u{1B}[2K" }
        guard screen == .groups else { return "" }
        return ui.at(row, 1) + "\u{1B}[2K" + moreIndicator(after: currentRange().last)
    }

    /// One card (overview) or tile (group): just its frame and labels when
    /// only the selection moved, everything when its photos' marks changed.
    private func item(_ index: Int, content: Bool) -> String {
        switch screen {
        case .groups:
            guard (currentRange().first..<currentRange().last).contains(index) else { return "" }
            return overview == .mosaic ? mosaicCard(index, layout: mosaicLayout(), content: content)
                : filmstripRow(index, content: content)
        case .group:
            let layout = gridLayout
            let first = gridScroll * layout.perRow
            guard index >= first, index < min(order.count, first + layout.visible) else { return "" }
            return groupTile(index, layout: layout, content: content)
        default: return ""
        }
    }

    private func footer() -> String {
        switch screen {
        case .groups:
            if tab == .documents {
                return ui.actionBar(hints: "space open · tab duplicates · m file · u undo · ? keys",
                                    short: "space open · tab · m file", action: fileButton(run.documentsToFile.count, copies: run.documentCopies.count))
            }
            let selected = groups.flatMap { g in g.photos.map(\.id).filter { g.pick.willMove($0) } }
            return ui.actionBar(hints: "space open · a accept clear · k keep group · x move rest · m move · u undo" + (tabs.count > 1 ? " · tab next tab" : "") + " · ? keys",
                                short: "space open · ? keys", action: moveButton(selected))
        default:
            let movingIDs = group.photos.map(\.id).filter { pick.willMove($0) }
            let moving = movingIDs.count
            if tab == .documents {
                let filing = pick.keepers.filter { !pick.moved.contains($0) }.count
                return ui.actionBar(hints: "space look · d file · k keep here · x duplicate · c compare · u undo · esc back",
                                    short: "d file · k keep · x dup · esc", action: fileButton(filing, copies: moving))
            }
            return ui.actionBar(hints: "space look · k keep · x move · b best · a all · c compare · e edit · o show in Finder · u undo · esc back · ? keys",
                                short: "k keep · x move · ? keys", action: moveButton(movingIDs, label: "Move \(moving)"))
        }
    }

    private func fileButton(_ filing: Int, copies: Int) -> String {
        guard filing + copies > 0 else { return ui.dim("nothing to file") }
        var label = "m · File \(filing) in PGDocuments"
        if copies > 0 { label += ", move \(copies) cop\(copies == 1 ? "y" : "ies")" }
        return ui.button(label)
    }

    /// "34 selected · 412 MB" and the move button, or "nothing selected".
    private func moveButton(_ ids: [String], label: String = "Move or delete") -> String {
        guard !ids.isEmpty else { return ui.dim("nothing selected") }
        let size = run.bytes(ids).map { " · " + Run.size($0) } ?? ""
        return ui.dim("\(ids.count) selected\(size)  ") + ui.button("m · \(label)")
    }

    private func overviewHeader(range: String = "") -> String {
        let photos = groups.reduce(0) { $0 + $1.photos.count }
        let reviewed = groups.filter { $0.reviewed == true }.count
        let counted = tab == .documents ? "\(groups.count) documents"
            : junkCount > 0 ? "\(run.groups.count) groups + \((run.junkGroups ?? []).count) junk" : "\(groups.count) groups"
        var left = ui.bold(run.scope) + ui.dim(" · \(counted) · \(photos) photos")
        if tabs.count > 1 {
            let on = { [ui] (text: String) in ui.bold("[" + text + "]") }
            func label(_ t: Tab) -> String {
                switch t {
                case .duplicates: "Duplicates \(run.groups.count)" + (junkCount > 0 ? " + Junk \(junkCount)" : "")
                case .documents: "Documents \((run.documentGroups ?? []).reduce(0) { $0 + $1.photos.count })"
                }
            }
            left = tabs.map { $0 == tab ? on(label($0)) : ui.dim(label($0)) }.joined(separator: "  ") + ui.dim("  tab · ") + left
        }
        let progress = ProgressBoard.bar(Double(reviewed) / Double(max(1, groups.count)), width: 8)
        return ui.at(1, 2) + ui.spread(left, ui.dim(range) + progress + ui.dim(" \(reviewed)/\(groups.count) reviewed"), width: ui.cols - 2)
    }

    /// "Apr 21 · 7:12 PM" plus marks: ✓ reviewed, ✦ close call, problems spotted.
    private func cardTitle(_ g: Run.Group, selected: Bool) -> String {
        if g.kind == .documents {
            let best = g.photos.first { $0.id == g.pick.best } ?? g.photos[0]
            let title = best.document ?? "Document"
            return (selected ? ui.bold(title) : title) + (g.reviewed == true ? " " + ui.green("✓") : "")
        }
        if g.kind == .junk {
            let title = "Junk · " + (g.pick.suggestions.values.first ?? "junk").capitalizedFirst
            return ui.amber(selected ? ui.bold(title) : title) + (g.reviewed == true ? " " + ui.green("✓") : "")
        }
        var title = Format.day.string(from: g.photos[0].date)
        title = selected ? ui.bold(title) : title
        if g.reviewed == true { title += " " + ui.green("✓") }
        if g.pick.decidedBy == "apple-model" { title += " " + ui.amber("✦") }
        let flagged = g.pick.suggestions.filter { g.pick.willMove($0.key) }
        if let reason = flagged.values.first {
            title += " " + ui.amber(flagged.count == 1 ? reason : "\(flagged.count) flagged")
        }
        return title
    }

    private func cardCounts(_ g: Run.Group) -> String {
        let ids = g.photos.map(\.id)
        if g.kind == .documents {
            let filing = g.pick.keepers.filter { !g.pick.moved.contains($0) }.count
            let copies = ids.filter { g.pick.willMove($0) }.count
            var parts: [String] = []
            if filing > 0 { parts.append(ui.blue("→ PGDocuments")) }
            if copies > 0 { parts.append(ui.dim("\(copies) cop\(copies == 1 ? "y" : "ies") to move")) }
            if !g.pick.kept.isEmpty { parts.append(ui.dim("keep here")) }
            if !g.pick.moved.isEmpty { parts.append(ui.green("\(g.pick.moved.count) moved")) }
            return parts.joined(separator: ui.dim(" · ")) + ui.dim(" · " + Format.day.string(from: g.photos[0].date))
        }
        let moving = ids.filter { g.pick.willMove($0) }.count
        let kept = ids.filter { g.pick.isKept($0) }.count
        var text = ui.dim("keep \(kept) · move ") + (moving > 0 ? ui.blue("\(moving)") : ui.dim("0"))
        if !g.pick.moved.isEmpty { text += ui.dim(" · ") + ui.green("\(g.pick.moved.count) moved") }
        return text
    }

    private func thumb(_ member: Run.Member) -> URL? {
        images[member.id].map { folder.appendingPathComponent($0.thumb) }
    }

    // Overview A: the best shot large, the others stacked beside it.
    private struct MosaicLayout { var perRow: Int; var cardWidth: Int; var imageRows: Int; var visibleRows: Int }

    /// Cards sized to use the whole window: every group if they fit at a
    /// readable size, otherwise the largest cards that fill whole rows.
    private func mosaicLayout() -> MosaicLayout {
        let n = groups.count
        let available = ui.rows - 4  // header, gap, "more" line, action bar
        var showsAll: (layout: MosaicLayout, area: Int)?
        var fallback: MosaicLayout?
        for perRow in 1...8 {
            let width = min(70, (ui.cols - 2 - (perRow - 1) * 3) / perRow)
            guard width >= 26 else { break }
            let natural = max(4, ((width - 2) * 2 / 3) * 3 / 8)
            let rowsNeeded = (n + perRow - 1) / perRow
            let visibleRows = max(1, min(rowsNeeded, available / (natural + 5)))
            // Stretch to fill the height; photos stay centred inside.
            let imageRows = max(4, min(natural * 3 / 2, available / visibleRows - 5))
            let layout = MosaicLayout(perRow: perRow, cardWidth: width, imageRows: imageRows, visibleRows: visibleRows)
            if visibleRows * perRow >= n {
                let area = width * imageRows
                if showsAll == nil || area > showsAll!.area { showsAll = (layout, area) }
            } else if width >= 34, fallback == nil || visibleRows * perRow >= fallback!.visibleRows * fallback!.perRow {
                fallback = layout
            }
        }
        return showsAll?.layout ?? fallback ?? MosaicLayout(perRow: 1, cardWidth: ui.cols - 2, imageRows: 6, visibleRows: 1)
    }

    private var filmstripVisible: Int {
        let thumbRows = ui.rows >= 40 ? 5 : 4
        return max(1, (ui.rows - 5) / (thumbRows + (ui.cols < 64 ? 3 : 2)))
    }

    /// "1–8 of 23" in the header and a clickable "▼ 15 more" above the action bar.
    private func range(first: Int, shown: Int) -> String {
        let last = min(groups.count, first + shown)
        return last - first < groups.count ? "\(first + 1)–\(last) of \(groups.count) · " : ""
    }

    private func moreIndicator(after last: Int) -> String {
        let remaining = groups.count - last
        guard remaining > 0 else { return "" }
        let text = "▼ \(remaining) more · scroll or page down"
        let col = max(2, (ui.cols - text.count) / 2)
        if !hits.contains(where: { if case .more = $0.hit { return true } else { return false } }) {
            hits.append((ui.rows - 1...ui.rows - 1, col...(col + text.count), .more))
        }
        return ui.at(ui.rows - 1, col) + ui.blue(text)
    }

    /// Scrolls just enough to keep the selected group on screen.
    private func keepSelectionVisible() {
        if overview == .mosaic {
            let layout = mosaicLayout()
            let row = groupIndex / layout.perRow
            if row < scroll { scroll = row }
            if row >= scroll + layout.visibleRows { scroll = row - layout.visibleRows + 1 }
        } else {
            if groupIndex < scroll { scroll = groupIndex }
            if groupIndex >= scroll + filmstripVisible { scroll = groupIndex - filmstripVisible + 1 }
        }
    }

    /// The groups on screen.
    private func currentRange() -> (first: Int, last: Int) {
        if overview == .mosaic {
            let layout = mosaicLayout()
            let first = scroll * layout.perRow
            return (first, min(groups.count, first + layout.visibleRows * layout.perRow))
        }
        return (scroll, min(groups.count, scroll + filmstripVisible))
    }

    private func mosaic() -> String {
        let layout = mosaicLayout()
        let (first, last) = currentRange()
        var out = overviewHeader(range: range(first: first, shown: last - first))
        for index in first..<last {
            out += mosaicCard(index, layout: layout, content: true)
            let (r, c) = mosaicOrigin(index, layout)
            hits.append((r...(r + layout.imageRows + 3), c...(c + layout.cardWidth - 1), .group(index)))
        }
        return out + footer()
    }

    private func mosaicOrigin(_ index: Int, _ layout: MosaicLayout) -> (row: Int, col: Int) {
        (3 + (index / layout.perRow - scroll) * (layout.imageRows + 5), 2 + (index % layout.perRow) * (layout.cardWidth + 3))
    }

    /// A group card: frame and the two lines under it, plus the photos when
    /// `content` is set.
    private func mosaicCard(_ index: Int, layout: MosaicLayout, content: Bool) -> String {
        let g = groups[index]
        let (r, c) = mosaicOrigin(index, layout)
        let selected = index == groupIndex
        // Blue while selected; green once reviewed; grey otherwise.
        let done = g.reviewed == true
        var out = ui.box(row: r, col: c, width: layout.cardWidth, height: layout.imageRows + 2,
                         paint: { [ui] in selected ? ui.blue($0) : done ? ui.green($0) : ui.gray($0) }, heavy: selected)
        if content {
            let inner = layout.cardWidth - 2
            let coverWidth = inner * 2 / 3
            let sideWidth = inner - coverWidth - 1
            out += blank(row: r + 1, col: c + 1, cols: inner, rows: layout.imageRows)
            let shown = Run.displayOrder(g)
            if let url = thumb(shown[0]) {
                out += ui.image(url, row: r + 1, col: c + 1, cols: coverWidth, rows: layout.imageRows, dim: !g.pick.isKept(shown[0].id))
            }
            let others = Array(shown.dropFirst())
            let slots = min(3, others.count)
            if slots > 0 {
                let slotRows = max(1, (layout.imageRows - (slots - 1)) / slots)
                for k in 0..<slots {
                    let sr = r + 1 + k * (slotRows + 1), sc = c + 1 + coverWidth + 1
                    if k == slots - 1, others.count > slots {
                        out += ui.at(sr + slotRows / 2, sc + max(0, (sideWidth - 3) / 2)) + ui.bold("+\(others.count - slots + 1)")
                    } else if let url = thumb(others[k]) {
                        out += ui.image(url, row: sr, col: sc, cols: sideWidth, rows: slotRows, dim: !g.pick.isKept(others[k].id))
                    }
                }
            }
        }
        out += ui.at(r + layout.imageRows + 2, c) + pad(cardTitle(g, selected: selected), layout.cardWidth)
        out += ui.at(r + layout.imageRows + 3, c) + pad(cardCounts(g), layout.cardWidth)
        return out
    }

    /// Spaces over an area, so a redrawn item never shows leftovers.
    private func blank(row: Int, col: Int, cols: Int, rows: Int) -> String {
        let spaces = String(repeating: " ", count: max(0, cols))
        return (0..<max(0, rows)).map { ui.at(row + $0, col) + spaces }.joined()
    }

    /// Styled text cut or padded to exactly `width` cells.
    private func pad(_ styled: String, _ width: Int) -> String {
        let text = ui.clip(styled, width)
        return text + "\u{1B}[0m" + String(repeating: " ", count: max(0, width - ui.visibleWidth(text)))
    }

    // Overview B: one row per group, every photo visible.
    private struct FilmstripLayout {
        var thumbRows: Int, thumbWidth: Int, stacked: Bool, rowHeight: Int, labelWidth: Int, fits: Int
    }

    private func filmstripLayout() -> FilmstripLayout {
        let thumbRows = ui.rows >= 40 ? 5 : 4
        let thumbWidth = thumbRows * 8 / 3
        let stacked = ui.cols < 64
        let labelWidth = stacked ? 0 : 26
        return FilmstripLayout(thumbRows: thumbRows, thumbWidth: thumbWidth, stacked: stacked,
                               rowHeight: thumbRows + (stacked ? 3 : 2), labelWidth: labelWidth,
                               fits: max(1, (ui.cols - labelWidth - 4) / (thumbWidth + 1)))
    }

    private func filmstrip() -> String {
        let layout = filmstripLayout()
        let (first, last) = currentRange()
        var out = overviewHeader(range: range(first: first, shown: last - first))
        for index in first..<last {
            out += filmstripRow(index, content: true)
            let r = 3 + (index - scroll) * layout.rowHeight
            hits.append((r...(r + layout.rowHeight - 2), 1...ui.cols, .group(index)))
        }
        return out + footer()
    }

    private func filmstripRow(_ index: Int, content: Bool) -> String {
        let layout = filmstripLayout()
        let g = groups[index]
        let r = 3 + (index - scroll) * layout.rowHeight
        let selected = index == groupIndex
        var out = ""
        if layout.stacked {
            out += ui.at(r, 3) + pad(cardTitle(g, selected: selected) + "  " + cardCounts(g), ui.cols - 3)
        } else {
            out += ui.at(r, 3) + pad(cardTitle(g, selected: selected), layout.labelWidth - 1)
            out += ui.at(r + 1, 3) + pad(cardCounts(g), layout.labelWidth - 1)
            out += ui.at(r + 2, 3) + pad(ui.dim("\(g.photos.count) photos"), layout.labelWidth - 1)
        }
        let strip = layout.stacked ? r + 1 : r
        let mark = selected ? ui.blue("▌") : g.reviewed == true ? ui.green("▌") : " "
        for y in 0..<(strip - r + layout.thumbRows) { out += ui.at(r + y, 1) + mark }
        guard content else { return out }

        let shown = Run.displayOrder(g)
        out += blank(row: strip, col: 3 + layout.labelWidth, cols: ui.cols - 3 - layout.labelWidth, rows: layout.thumbRows + 1)
        for (k, member) in shown.prefix(layout.fits).enumerated() {
            let c = 3 + layout.labelWidth + k * (layout.thumbWidth + 1)
            if layout.fits > 1, k == layout.fits - 1, shown.count > layout.fits {
                out += ui.at(strip + layout.thumbRows / 2, c + 3) + ui.bold("+\(shown.count - layout.fits + 1)")
                break
            }
            let kept = g.pick.isKept(member.id)
            if let url = thumb(member) {
                out += ui.image(url, row: strip, col: c, cols: layout.thumbWidth, rows: layout.thumbRows, dim: !kept)
            }
            // A rule under each: green best, white kept, blue moving.
            let rule = String(repeating: "▔", count: layout.thumbWidth)
            out += ui.at(strip + layout.thumbRows, c)
                + (g.pick.keepers.contains(member.id) ? ui.green(rule) : kept ? rule : g.pick.moved.contains(member.id) ? ui.gray(rule) : ui.blue(rule))
        }
        return out
    }

    /// Photo tiles for one group, as large as the window allows while
    /// showing them all, in 4:3 boxes (a cell is two square pixels tall).
    private struct GroupLayout {
        var perRow = 1, tileWidth = 20, imageRows = 4, visible = 0
        /// Rows each tile takes besides its photo: frame, captions, gap.
        var extra = 7

        init(count n: Int, cols: Int, rows: Int, extra: Int = 7) {
            self.extra = extra
            let available = rows - 4
            var best: (perRow: Int, width: Int, imageRows: Int)?
            for perRow in 1...max(1, min(n, 8)) {
                var width = min(60, (cols - 2 - (perRow - 1) * 2) / perRow)
                guard width >= 14 else { break }
                let lines = (n + perRow - 1) / perRow
                let byWidth = (width - 2) * 3 / 8
                let imageRows = min(byWidth, available / lines - extra)
                guard imageRows >= 3 else { continue }
                if imageRows < byWidth { width = min(width, imageRows * 8 / 3 + 2) }
                if best == nil || imageRows * width > best!.imageRows * best!.width { best = (perRow, width, imageRows) }
            }
            if let best {
                (perRow, tileWidth, imageRows, visible) = (best.perRow, best.width, best.imageRows, n)
                return
            }
            // Too many photos for the window: show the rows that fit.
            perRow = max(1, (cols - 2) / 20)
            tileWidth = min(60, (cols - 2 - (perRow - 1) * 2) / perRow)
            imageRows = max(3, (tileWidth - 2) * 3 / 8)
            visible = min(n, max(1, available / (imageRows + extra)) * perRow)
        }
    }

    private enum State { case best, keep, move, moved }

    private func state(_ id: String) -> State {
        pick.keepers.contains(id) ? .best : pick.isKept(id) ? .keep : pick.moved.contains(id) ? .moved : .move
    }

    private func label(_ state: State, number: Int) -> String {
        if tab == .documents {
            switch state {
            case .best: return ui.blue(" \(number) → PGDocuments ")
            case .keep: return " \(number) Keep here "
            case .move: return ui.dim(" \(number) → Move ")
            case .moved: return ui.dim(" \(number) Moved ")
            }
        }
        switch state {
        case .best: return ui.green(" \(number) ★ Best ")
        case .keep: return " \(number) Keep "
        case .move: return ui.blue(" \(number) → Move ")
        case .moved: return ui.dim(" \(number) Moved ")
        }
    }

    /// The line under a photo: what happens to it and why.
    private func caption(_ id: String, _ state: State, width: Int) -> [String] {
        let note = pick.notes[id] ?? ""
        if tab == .documents {
            let member = group.photos.first { $0.id == id }
            var lines = [ui.fit(member?.document ?? "Document", width)]
            if let same = member?.sameText, state == .move {
                lines.append(ui.dim(ui.fit("copy · same text \(Int((same * 100).rounded()))%", width)))
            } else if let excerpt = member?.excerpt {
                lines.append(ui.dim(ui.fit("“" + excerpt + "”", width)))
            }
            return lines
        }
        switch state {
        case .best: return ui.wrap(note, width: width, lines: 2).map { self.ui.green($0) }
        case .keep: return ui.wrap("Keep · " + (pick.decidedBy == "you" ? "you chose" : note), width: width, lines: 2)
        case .moved: return [ui.dim(ui.fit("Moved", width))]
        case .move:
            if let reason = pick.reasons[id] ?? pick.suggestions[id] {
                return [ui.blue("Move · ") + ui.amber(ui.fit(reason, width - 7))]
            }
            return ui.wrap("Move · " + note, width: width, lines: 2).map { self.ui.blue($0) }
        }
    }

    /// Where you are, before the screen's own title: "Japan 2025 › Group 3 › ".
    private func crumbs(group: Bool = false) -> String {
        ui.dim(ui.fit(run.scope, 32) + " › " + (group ? "Group \(groupIndex + 1) › " : ""))
    }

    private func groupHeader() -> String {
        var header = crumbs() + ui.bold("Group \(groupIndex + 1) of \(groups.count)") + ui.dim(" · ")
            + Format.day.string(from: group.photos[0].date) + ui.dim(" · ") + ui.blue(group.kind.title) + ui.dim(" · \(order.count) photos")
        if pick.decidedBy == "apple-model" { header += ui.dim("  ✦ close call, picked by Apple Intelligence") }
        return ui.at(1, 1) + "\u{1B}[2K " + ui.clip(header, ui.cols - 2)
    }

    private func groupGrid() -> String {
        let n = order.count
        let layout = gridLayout
        var out = groupHeader()
        let first = gridScroll * layout.perRow
        for index in first..<min(n, first + layout.visible) {
            out += groupTile(index, layout: layout, content: true)
            let (r, c) = tileOrigin(index, layout)
            hits.append((r...(r + layout.imageRows + 1), c...(c + layout.tileWidth - 1), .photo(index)))
        }
        if layout.visible < n {
            let last = min(n, first + layout.visible)
            out += ui.at(ui.rows - 2, 2) + ui.dim(ui.fit("photos \(first + 1)–\(last) of \(n) · ↑↓, the wheel or page up/down for more", ui.cols - 2))
        }
        return out + footer()
    }

    private func tileOrigin(_ index: Int, _ layout: GroupLayout) -> (row: Int, col: Int) {
        let k = index - gridScroll * layout.perRow
        return (3 + (k / layout.perRow) * (layout.imageRows + layout.extra), 2 + (k % layout.perRow) * (layout.tileWidth + 2))
    }

    /// The first row of photos shown in a group too big for the window.
    private var gridScroll = 0
    /// i: tiles show scene tags, time and scores under each photo, or just
    /// what happens to it, which leaves the photos more room.
    private var details = true
    private var gridLayout: GroupLayout { GroupLayout(count: order.count, cols: ui.cols, rows: ui.rows, extra: details ? 7 : 5) }

    /// Scrolls the group's grid so the highlighted photo is on screen.
    private func keepGridVisible() {
        let layout = gridLayout
        let rowsShown = max(1, layout.visible / layout.perRow), row = cursor / layout.perRow
        if row < gridScroll { gridScroll = row }
        if row >= gridScroll + rowsShown { gridScroll = row - rowsShown + 1 }
    }

    /// A photo tile: frame with its label, plus the photo and captions when
    /// `content` is set (its marks changed).
    private func groupTile(_ index: Int, layout: GroupLayout, content: Bool) -> String {
        let member = order[index]
        let s = state(member.id)
        let (r, c) = tileOrigin(index, layout)
        let ui = self.ui, focused = index == cursor || allSelected
        let paint: (String) -> String = { focused ? ui.blue($0) : s == .best ? ui.green($0) : ui.gray($0) }
        var out = ui.box(row: r, col: c, width: layout.tileWidth, height: layout.imageRows + 2,
                         label: label(s, number: index + 1), paint: paint, heavy: focused)
        guard content else { return out }
        if let url = thumb(member) {
            out += ui.image(url, row: r + 1, col: c + 1, cols: layout.tileWidth - 2, rows: layout.imageRows,
                            dim: s == .move || s == .moved)
        }
        let lines = caption(member.id, s, width: layout.tileWidth)
        for k in 0..<2 {
            out += ui.at(r + layout.imageRows + 2 + k, c) + pad(k < lines.count ? lines[k] : "", layout.tileWidth)
        }
        if details {
            out += ui.at(r + layout.imageRows + 4, c) + pad(ui.dim(about(member)), layout.tileWidth)
            out += ui.at(r + layout.imageRows + 5, c) + pad(ui.dim(meta(member, short: true)), layout.tileWidth)
        }
        return out
    }

    private func photoView() -> String {
        let (cols, rows) = (ui.cols, ui.rows)
        let member = order[cursor]
        let s = state(member.id)
        let status: String
        switch s {
        case .best: status = ui.green("★ Best")
        case .keep: status = "Keep"
        case .moved: status = ui.dim("Moved")
        case .move: status = ui.blue("→ Move") + ((pick.reasons[member.id] ?? pick.suggestions[member.id]).map { ui.dim(" · ") + ui.amber($0) } ?? "")
        }
        let crop = faceCrop(member, cols: cols - 2, rows: max(4, rows - 7))
        let zoom = !zoomed ? "" : crop == nil ? ui.dim("  · no faces in this one") : ui.dim("  · faces · z whole photo")
        let header = crumbs(group: true) + ui.bold("Photo \(cursor + 1) of \(order.count)") + ui.dim(" · ")
            + Format.day.string(from: member.date) + "  " + status + zoom
        var out = ui.at(1, 2) + ui.clip(header, cols - 2)
        if let files = images[member.id] {
            out += ui.image(folder.appendingPathComponent(files.full), row: 3, col: 2, cols: cols - 2,
                            rows: max(4, rows - 7), dim: false, large: true, crop: crop)
        }
        let about = tab == .documents
            ? [member.document, member.excerpt.map { "“" + $0 + "”" }].compactMap { $0 }.joined(separator: "  ")
            : self.about(member)
        if !about.isEmpty { out += ui.at(rows - 3, 2) + ui.center(ui.fit(about, cols - 2), width: cols - 2) }
        let note = ui.fit(pick.notes[member.id] ?? "", cols - 2)
        out += ui.at(rows - 2, 2) + ui.center(s == .best ? ui.green(note) : ui.dim(note), width: cols - 2)
        out += ui.at(rows - 1, 2) + ui.center(ui.dim(ui.fit(meta(member, short: false), cols - 2)), width: cols - 2)
        return out + ui.actionBar(
            hints: "← → photos · k keep · x move · b best · z faces · c compare · space back · ? keys",
            short: "k keep · x move · z faces · space back")
    }

    /// Two photos side by side: the pinned one on the left (the best shot to
    /// start with) and a candidate on the right, with what's better or worse.
    private func compareView() -> String {
        let (cols, rows) = (ui.cols, ui.rows)
        let left = order[pinned], right = order[cursor]
        let candidates = order.indices.filter { $0 != pinned }
        let position = (candidates.firstIndex(of: cursor) ?? 0) + 1
        var out = ui.at(1, 2) + ui.clip(crumbs(group: true) + ui.bold("Compare")
            + ui.dim(" · candidate \(position) of \(candidates.count)")
            + (zoomed ? ui.dim("  · faces · z whole photos") : ""), cols - 2)

        let paneWidth = (cols - 5) / 2
        let imageRows = max(4, rows - 9)
        for (side, index) in [(0, pinned), (1, cursor)] {
            let member = order[index]
            let c = 2 + side * (paneWidth + 3)
            let s = state(member.id)
            let title = side == 0 ? " Pinned " : " Candidate "
            let paint: (String) -> String = { [ui] in side == 1 ? ui.blue($0) : ui.gray($0) }
            out += ui.box(row: 3, col: c, width: paneWidth, height: imageRows + 2,
                          label: title + label(s, number: index + 1), paint: paint, heavy: side == 1)
            if let files = images[member.id] {
                out += ui.image(folder.appendingPathComponent(files.full), row: 4, col: c + 1, cols: paneWidth - 2, rows: imageRows,
                                dim: false, large: true, crop: faceCrop(member, cols: paneWidth - 2, rows: imageRows))
            }
            let lines = caption(member.id, s, width: paneWidth)
            out += ui.at(imageRows + 6, c) + (lines.first ?? "")
            out += ui.at(imageRows + 7, c) + ui.dim(ui.fit(meta(member, short: false), paneWidth))
        }
        // How the candidate differs from the pinned photo.
        let notes = differences(right, comparedTo: left)
        if !notes.isEmpty {
            out += ui.at(imageRows + 8, 2 + paneWidth + 3) + ui.clip(ui.dim("vs left: ") + notes, paneWidth)
        }
        return out + ui.actionBar(
            hints: "← → next candidate · ↑ pin it · k keep · x move · b best · z faces · esc back · ? keys",
            short: "← → · k keep · x move · z faces · esc")
    }

    private func differences(_ a: Run.Member, comparedTo b: Run.Member) -> String {
        var parts: [String] = []
        if b.sharpness > 0 {
            let ratio = Double(a.sharpness) / Double(b.sharpness)
            if ratio > 1.15 { parts.append(ui.green("sharper")) } else if ratio < 0.87 { parts.append(ui.amber("softer")) }
        }
        let look = a.aesthetic - b.aesthetic
        if look > 0.05 { parts.append(ui.green("better look")) } else if look < -0.05 { parts.append(ui.amber("weaker look")) }
        if a.faceCount > 0, b.faceCount > 0 {
            let faces = a.faceQuality - b.faceQuality
            if faces > 0.08 { parts.append(ui.green("better faces")) } else if faces < -0.08 { parts.append(ui.amber("weaker faces")) }
        }
        if a.width * a.height < b.width * b.height * 3 / 4 { parts.append(ui.amber("smaller")) }
        return parts.isEmpty ? ui.dim("about the same") : parts.joined(separator: ui.dim(" · "))
    }

    private func helpSheet() -> String {
        func row(_ key: String, _ text: String) -> String { ui.blue(key.padding(toLength: 12, withPad: " ", startingAt: 0)) + text }
        let sections: [[String]] = [
            [row("← → ↑ ↓", "move around · home and end: first and last"), row("space enter", "open · look closer · confirm"),
             row("esc", "back · cancel (never changes anything)"), row("1–9  i", "go to that photo · show or hide details")],
            [row("k", "keep this photo (or the whole group)"), row("x", "move this photo (group: all but the best)"),
             row("b", "make it the best ★"), row("r", "say why it's moving"),
             row("a", "groups: accept every clear group · in a group: select all"),
             row("c", "compare two photos side by side"), row("z", "zoom in on the faces, when looking closer"),
             row("o", "show the photo in Finder (Photos library: in Photos)"),
             row("e", "edit in Photos (folders: Preview) · after a: all of them"),
             row("d", "documents tab: file this copy in PGDocuments"), row("tab", "switch between Duplicates and Documents")],
            [row("m", "move or delete the selection (asks first)"), row("u", "undo the last change or move"),
             row("v", "mosaics or filmstrips"), row("n p  ] [", "next or previous group · one still to review"),
             row("R", "groups: scan the same place again, from scratch"),
             row("q", "quit · everything is saved as you go")],
        ]
        let close = ui.dim("any key to close")
        let full = [ui.bold("Keys"), ""] + Array(sections.joined(separator: [""])) + ["", close]
        // In a short window: no title or gaps, so every key still fits.
        return ui.sheet(full.count <= ui.rows - 4 ? full : Array(sections.joined()) + [close], width: 78)
    }

    private func reasonSheet() -> String {
        let id = order[cursor].id
        let suggestion = allSelected ? nil : pick.suggestions[id]
        var lines = [ui.bold(allSelected ? "Why move all \(order.count) photos?" : "Why move photo \(cursor + 1)?")]
        if let suggestion { lines.append(ui.dim("PixelGraph noticed: ") + ui.amber(suggestion)) }
        lines.append("")
        let options = Inspector.reasons.enumerated().map { ui.blue("\($0.offset + 1)") + " \($0.element)" }
        if ui.cols >= 54 {
            lines += [options.prefix(3).joined(separator: "   "), options.dropFirst(3).joined(separator: "   ")]
        } else {
            lines += options
        }
        lines += ["", ui.dim(suggestion == nil ? "enter other · esc cancel" : "enter use suggestion · esc cancel")]
        return ui.sheet(lines)
    }

    /// The moment the last group gets its ✓: offers to carry out what's
    /// selected, once a session.
    private func announceIfDone() {
        guard !announcedDone, sheet == nil, run.reviewedGroups == run.allGroups.count else { return }
        announcedDone = true
        if run.waiting > 0 { sheet = .done }
    }

    private func doneSheet() -> String {
        let width = min(ui.cols - 2, 64) - 4
        let waiting = groups.flatMap { g in g.photos.map(\.id).filter { g.pick.willMove($0) } }
        let size = run.bytes(waiting).map { " (\(Run.size($0)))" } ?? ""
        var lines = [ui.green("✓ ") + ui.bold("Every group has been reviewed"), ""]
        lines += ui.wrap("\(waiting.count) photo\(waiting.count == 1 ? " is" : "s are")\(size) selected to "
                         + (tab == .documents ? "file or move" : "move") + ". Do it now, or look again first: nothing happens until you confirm.",
                         width: width, lines: 3).map { ui.dim($0) }
        lines += ["", ui.spread("", ui.dim("esc Not yet   ") + ui.button("enter Move now…"), width: width)]
        return ui.sheet(lines, width: 68)
    }

    /// Asks before leaving the review. Nothing is lost either way (choices
    /// are saved as you go), but a stray key shouldn't end a long session.
    private func leaveSheet(_ outcome: Outcome) -> String {
        let waiting = run.waiting
        let note = waiting > 0
            ? "\(waiting) photo\(waiting == 1 ? " is" : "s are") still selected to move or file; that waits for you."
            : "Everything you chose has been carried out."
        let width = min(ui.cols - 2, 64) - 4
        if outcome == .rescan {
            var lines = [ui.bold("Scan \(ui.fit(run.scope, 36)) again?"), ""]
            lines += ui.wrap("It's grouped afresh with your current settings, and every group starts again from PixelGraph's own picks: "
                             + "your choices in this review are dropped. Photos already moved stay moved.", width: width, lines: 4).map { ui.dim($0) }
            lines += ["", ui.spread("", ui.hints("esc Stay   ") + ui.button("enter Scan again"), width: width)]
            return ui.sheet(lines, width: 68)
        }
        let (title, after, button) = outcome == .home
            ? ("Back to the start screen?", "“Continue reviewing” on the start screen brings you back here.", "enter Leave")
            : ("Quit PixelGraph?", "Run pixelgraph again to continue where you left off.", "enter Quit")
        var lines = [ui.bold(title), ""]
        lines += ui.wrap("Your choices are saved. \(note)", width: width, lines: 3).map { ui.dim($0) }
        lines += ui.wrap(after, width: width, lines: 2).map { ui.dim($0) }
        lines += ["", ui.spread("", ui.dim("esc Stay   ") + ui.button(button), width: width)]
        return ui.sheet(lines, width: 68)
    }

    /// The move sheet: enter (or p) moves the copies to PGDuplicates, d
    /// deletes them instead. Documents are always filed in PGDocuments.
    private func confirmSheet(file: [String], duplicates: [String], describe: [String]) -> String {
        func count(_ n: Int) -> String { "\(n) photo\(n == 1 ? "" : "s")" }
        let width = min(ui.cols - 2, 64) - 4
        var lines: [String]
        if duplicates.isEmpty {
            lines = [ui.bold("File \(count(file.count)) in PGDocuments?"), ""]
        } else {
            let size = run.bytes(duplicates).map { " (\(Run.size($0)))" } ?? ""
            lines = [ui.bold(file.isEmpty ? "What should happen to \(count(duplicates.count))\(size)?"
                             : "File \(file.count) in PGDocuments. What about \(count(duplicates.count))\(size)?"), ""]
        }
        let keep: String
        switch source {
        case .album(let id, let name):
            if let reason = Library.readOnlyReason(id) {
                keep = "added to the “\(Library.duplicatesAlbum)” album; \(name) is \(reason), so they stay in it too"
            } else {
                keep = "out of \(name), into the “\(Library.duplicatesAlbum)” album; still in your library"
            }
        case .dates, .months:
            keep = "into the “\(Library.duplicatesAlbum)” album; still in your library"
        case .folder(let path):
            keep = "into “\(Files.duplicatesFolder)” inside \((path as NSString).lastPathComponent), with RAW and sidecars"
        }
        if !duplicates.isEmpty {
            let gone = source.isPhotos
                ? "to Recently Deleted in Photos (30 days); macOS asks first; PixelGraph can’t undo it"
                : "to the Trash, with RAW and sidecars; u puts them back"
            let junkIDs = self.junkIDs
            let junk = duplicates.filter { junkIDs.contains($0) }.count
            let into = junk == 0 ? "PGDuplicates" : junk == duplicates.count ? "PGJunk" : "PGDuplicates, junk to PGJunk"
            let moveLines = [ui.blue("enter") + "  Move to \(into)"]
                + ui.wrap(keep, width: width - 7, lines: 2).map { "       " + ui.dim($0) }
            let deleteLines = [ui.red("d    ") + "  Delete"]
                + ui.wrap(gone, width: width - 7, lines: 2).map { "       " + ui.dim($0) }
            lines += moveLines + [""] + deleteLines
        }
        if !file.isEmpty, !source.isPhotos {
            lines += ["", ui.dim("Documents go into “\(Files.documentsFolder)” inside the folder.")]
        }
        if !describe.isEmpty {
            lines += ["", ui.dim("The \(count(describe.count)) you keep get a caption, title and"),
                      ui.dim(source.isPhotos ? "keywords in Photos, after what’s already there." : "keywords in their files, after what’s already there.")]
        }
        // Deleting is a red button of its own, never what enter does.
        let buttons = duplicates.isEmpty ? ui.button("enter File \(file.count)")
            : ui.dangerButton("d Delete \(duplicates.count)") + "  " + ui.button("enter Move \(duplicates.count + file.count)")
        lines += ["", ui.spread("", ui.dim("esc Cancel   ") + buttons, width: width)]
        return ui.sheet(lines, width: 68)
    }

    /// The photo's description and scene tags, or for documents their tags line.
    private func about(_ member: Run.Member) -> String {
        let tags = (member.tags ?? []).joined(separator: ", ")
        switch (member.summary, tags.isEmpty) {
        case (let summary?, false): return summary + " · " + tags
        case (let summary?, true): return summary
        case (nil, false): return tags
        default: return ""
        }
    }

    /// How long after the group's first shot this one was taken, "+0.4 s" or
    /// "+2 min", so a burst reads differently from a scene revisited.
    private func gap(_ member: Run.Member) -> String? {
        guard let first = group.photos.map(\.date).min(), member.date > first else { return nil }
        let seconds = member.date.timeIntervalSince(first)
        switch seconds {
        case ..<10: return String(format: "+%.1f s", seconds)
        case ..<60: return "+\(Int(seconds)) s"
        case ..<3_600: return "+\(Int(seconds / 60)) min"
        case ..<86_400: return "+\(Int(seconds / 3_600)) h"
        default:
            let days = Int(seconds / 86_400)
            return "+\(days) day\(days == 1 ? "" : "s")"
        }
    }

    private func meta(_ member: Run.Member, short: Bool) -> String {
        var parts = [Format.time.string(from: member.date)]
        if let gap = gap(member) { parts.append(gap) }
        if !short { parts.append("\(member.width)×\(member.height)") }
        parts.append("look \(Int((member.aesthetic + 1) * 50))")
        if member.faceCount > 0 { parts.append("faces \(Int(member.faceQuality * 100))") }
        return parts.joined(separator: " · ")
    }
}

enum Format {
    static let day: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd jmm")
        return f
    }()

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
