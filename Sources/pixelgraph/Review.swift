import Foundation

/// Reviewing a scan: groups first, then the photos in a group, then one photo
/// enlarged. Every photo is Keep or Move; everything but the best starts
/// selected to move, so most of the time you only confirm.
final class ReviewSession {
    enum Outcome { case quit, home }

    private(set) var run: Run
    private let runFile: URL
    private let folder: URL
    private let images: [String: Report.Images]
    private let ui: UI
    /// Started from the home screen, so Esc on the groups goes back there.
    private let fromHome: Bool

    private enum Screen { case groups, group, photo, compare }
    private enum Sheet { case reason, confirm([String]), help }
    private enum Overview { case mosaic, filmstrip }
    private enum Hit { case group(Int), photo(Int), more }

    private var screen = Screen.groups
    private var sheet: Sheet?
    private var overview = Overview.mosaic
    private var groupIndex = 0
    private var cursor = 0
    /// Compare: the photo held on the left while candidates change on the right.
    private var pinned = 0
    private var scroll = 0
    /// The open group's photos in display order, fixed while it's open so
    /// numbers don't jump around as you change things.
    private var order: [Run.Member] = []
    private var hits: [(rows: ClosedRange<Int>, cols: ClosedRange<Int>, hit: Hit)] = []
    private var toast: String?
    private var dirty = false

    init(run: Run, runFile: URL = Paths.lastRun, folder: URL = Paths.report,
         graphics: TerminalImage.Mode = .auto, ui: UI? = nil) throws {
        self.run = run
        self.runFile = runFile
        self.folder = folder
        self.images = try Report.manifest(in: folder)
        self.ui = ui ?? UI(graphics: graphics)
        self.fromHome = ui != nil
    }

    private var source: Source { run.source ?? .dates(from: nil, to: nil) }
    private var group: Run.Group { run.groups[groupIndex] }
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
        draw()
        while true {
            let key = ui.term.nextKey()
            if let outcome = await handle(key) { return outcome }
            draw()
        }
    }

    private func save() {
        guard dirty else { return }
        try? run.save(to: runFile)
        try? Report.render(run, images: images, in: folder)
        dirty = false
    }

    // MARK: - Input

    /// Returns an outcome to leave the review.
    private func handle(_ key: Terminal.Key) async -> Outcome? {
        if key == .resize { return nil }
        toast = nil

        // q and ctrl-c quit from anywhere, closing any open sheet.
        if key == .quit || key == .char("q") {
            sheet = nil
            return .quit
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
            case .scrollDown: scrollBy(1, perRow: perRow, page: page)
            case .scrollUp: scrollBy(-1, perRow: perRow, page: page)
            case .enter, .char(" "): open(groupIndex)
            case .char("k"): keepGroup(groupIndex)
            case .char("x"): moveGroupRest(groupIndex)
            case .char("v"): overview = overview == .mosaic ? .filmstrip : .mosaic; scroll = 0
            case .char("m"): askToMove(run.toMove)
            case .char("u"): await undo()
            case .escape where fromHome: return .home
            case .click(let row, let col):
                switch hit(row, col) {
                case .group(let i)?: open(i)
                case .more?: select(groupIndex + page)
                default: break
                }
            default: break
            }

        case .group:
            let perRow = GroupLayout(count: order.count, cols: ui.cols, rows: ui.rows).perRow
            switch key {
            case .left: cursor = max(0, cursor - 1)
            case .right: cursor = min(order.count - 1, cursor + 1)
            case .up: cursor = max(0, cursor - perRow)
            case .down: cursor = min(order.count - 1, cursor + perRow)
            // Space looks closer, like Quick Look in Finder.
            case .enter, .char(" "): screen = .photo
            case .char("c"): openCompare()
            case .char("k"): keep(order[cursor].id)
            case .char("x"): markMove(order[cursor].id)
            case .char("b"): makeBest(order[cursor].id)
            case .char("r"): if !pick.moved.contains(order[cursor].id) { sheet = .reason }
            case .char("m"): askToMove(group.photos.map(\.id).filter { pick.willMove($0) })
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
            case .char("c"): openCompare()
            case .char("k"): keep(order[cursor].id)
            case .char("x"): markMove(order[cursor].id)
            case .char("b"): makeBest(order[cursor].id)
            case .char("r"): if !pick.moved.contains(order[cursor].id) { sheet = .reason }
            case .escape, .backspace, .enter, .click, .char(" "): screen = .group
            default: break
            }

        case .compare:
            switch key {
            case .right, .down: cursor = nextCandidate(after: cursor, step: 1)
            case .left: cursor = nextCandidate(after: cursor, step: -1)
            case .up, .tab: swap(&pinned, &cursor)
            case .char("k"): keep(order[cursor].id)
            case .char("x"): markMove(order[cursor].id)
            case .char("b"): makeBest(order[cursor].id)
            case .char("r"): if !pick.moved.contains(order[cursor].id) { sheet = .reason }
            case .char(" "), .enter: screen = .photo
            case .escape, .backspace, .char("c"), .click: screen = .group
            default: break
            }
        }
        return nil
    }

    private func handleSheet(_ current: Sheet, _ key: Terminal.Key) async {
        switch current {
        case .reason:
            let id = order[cursor].id
            switch key {
            case .escape, .backspace, .click: sheet = nil
            case .enter:
                setReason(id, pick.suggestions[id] ?? "other")
                sheet = nil
            case .char(let c):
                guard let n = c.wholeNumberValue, (1...Inspector.reasons.count).contains(n) else { return }
                setReason(id, Inspector.reasons[n - 1])
                sheet = nil
            default: break
            }
        case .help:
            sheet = nil
        case .confirm(let ids):
            switch key {
            case .enter, .char("y"):
                sheet = nil
                await move(ids)
            case .escape, .backspace, .click, .char("n"): sheet = nil
            default: break
            }
        }
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
        let lastFirst = max(0, (run.groups.count - 1) / perRow - (page / perRow) + 1)
        scroll = min(max(0, scroll + rows), lastFirst)
        let first = scroll * perRow
        if groupIndex < first { groupIndex = first }
        if groupIndex >= first + page { groupIndex = min(run.groups.count - 1, first + page - 1) }
    }

    private func hit(_ row: Int, _ col: Int) -> Hit? {
        hits.first { $0.rows.contains(row) && $0.cols.contains(col) }?.hit
    }

    private func select(_ index: Int) {
        groupIndex = min(max(index, 0), run.groups.count - 1)
    }

    private func open(_ index: Int) {
        select(index)
        order = Run.displayOrder(group)
        cursor = 0
        if run.groups[groupIndex].reviewed != true {
            run.groups[groupIndex].reviewed = true
            dirty = true
        }
        screen = .group
    }

    // MARK: - Keep and move
    //
    // Keys set a state rather than toggle it, so pressing twice can't undo
    // what you meant; every change can be undone with u.

    private enum Action {
        case mark(group: Int, before: Pick)
        case move([String])
    }

    private var history: [Action] = []

    private func edit(_ index: Int? = nil, say message: String? = nil, _ change: (inout Pick) -> Void) {
        let g = index ?? groupIndex
        let before = run.groups[g].pick
        change(&run.groups[g].pick)
        if let first = run.groups[g].pick.keepers.first { run.groups[g].pick.best = first }
        guard run.groups[g].pick.keepers != before.keepers || run.groups[g].pick.kept != before.kept
            || run.groups[g].pick.reasons != before.reasons else {
            if let message { toast = ui.dim(message + " already") }
            return
        }
        run.groups[g].pick.decidedBy = "you"
        history.append(.mark(group: g, before: before))
        dirty = true
        if let message { toast = message + ui.dim(" · ") + ui.blue("u") + ui.dim(" undo") }
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

    private func setReason(_ id: String, _ reason: String) {
        edit(say: "\(name(id)) → Move · \(reason)") { pick in
            pick.reasons[id] = reason
            pick.keepers.removeAll { $0 == id }
            pick.kept.removeAll { $0 == id }
        }
    }

    private func movedAlready() {
        toast = ui.dim("Already moved to Duplicates · u to put it back")
    }

    /// k on a group: keep every photo in it.
    private func keepGroup(_ index: Int) {
        let g = run.groups[index]
        let movable = g.photos.map(\.id).filter { !g.pick.moved.contains($0) }
        edit(index, say: "Group \(index + 1) → keep all") { pick in
            pick.kept = movable.filter { !pick.keepers.contains($0) }
        }
    }

    /// x on a group: back to keeping the best and moving the rest.
    private func moveGroupRest(_ index: Int) {
        let g = run.groups[index]
        let movable = g.photos.map(\.id).filter { !g.pick.moved.contains($0) }
        edit(index, say: "Group \(index + 1) → move all but the best") { pick in
            pick.kept = []
            pick.reasons = [:]
            if pick.keepers.isEmpty, let first = movable.first { pick.keepers = [first] }
        }
    }

    private func askToMove(_ ids: [String]) {
        guard !ids.isEmpty else {
            toast = ui.dim("Nothing selected to move.")
            return
        }
        sheet = .confirm(ids)
    }

    private func move(_ ids: [String]) async {
        do {
            _ = try await Mover.move(ids, from: source)
            run.markMoved(ids)
            history.append(.move(ids))
            dirty = true
            save()
            toast = ui.green("✓") + " Moved \(ids.count) photo\(ids.count == 1 ? "" : "s") to Duplicates · " + ui.blue("u") + ui.dim(" undo")
        } catch {
            toast = ui.red("Couldn't move: \(error.localizedDescription)")
        }
    }

    /// Undoes the last thing you did: a mark, or a move (this session's, or
    /// the last one saved from before).
    private func undo() async {
        if case .mark(let g, let before)? = history.last {
            history.removeLast()
            run.groups[g].pick = before
            dirty = true
            toast = ui.green("✓") + " Undone"
            return
        }
        if case .move? = history.last { history.removeLast() }
        guard let last = Mover.history().last, last.source == source else {
            toast = ui.dim("Nothing to undo.")
            return
        }
        do {
            try await Mover.undoLast()
            run.unmark(last.ids)
            dirty = true
            save()
            toast = ui.green("✓") + " Put back \(last.ids.count) photo\(last.ids.count == 1 ? "" : "s")"
        } catch {
            toast = ui.red("Couldn't undo: \(error.localizedDescription)")
        }
    }

    // MARK: - Drawing

    private func draw() {
        hits = []
        var out = ui.clear()
        switch screen {
        case .groups: out += overview == .mosaic ? mosaic() : filmstrip()
        case .group: out += groupGrid()
        case .photo: out += photoView()
        case .compare: out += compareView()
        }
        if let toast { out += ui.at(ui.rows - 1, 2) + "\u{1B}[2K" + ui.center(toast, width: ui.cols - 2) }
        switch sheet {
        case .reason: out += reasonSheet()
        case .confirm(let ids): out += confirmSheet(ids)
        case .help: out += helpSheet()
        case nil: break
        }
        ui.term.write(out)
    }

    private func moveButton(_ count: Int, label: String = "Move to Duplicates") -> String {
        count > 0 ? ui.dim("\(count) selected  ") + ui.button("m · \(label)") : ui.dim("nothing selected")
    }

    private func overviewHeader(range: String = "") -> String {
        let photos = run.groups.reduce(0) { $0 + $1.photos.count }
        let reviewed = run.groups.filter { $0.reviewed == true }.count
        let left = ui.bold(run.scope) + ui.dim(" · \(run.groups.count) groups · \(photos) photos")
        return ui.at(1, 2) + ui.spread(left, ui.dim(range + "\(reviewed) reviewed"), width: ui.cols - 2)
    }

    /// "Apr 21 · 7:12 PM" plus marks: ✓ reviewed, ✦ close call, problems spotted.
    private func cardTitle(_ g: Run.Group, selected: Bool) -> String {
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
        let n = run.groups.count
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
        let last = min(run.groups.count, first + shown)
        return last - first < run.groups.count ? "\(first + 1)–\(last) of \(run.groups.count) · " : ""
    }

    private func moreIndicator(after last: Int) -> String {
        let remaining = run.groups.count - last
        guard remaining > 0 else { return "" }
        let text = "▼ \(remaining) more · scroll or page down"
        let col = max(2, (ui.cols - text.count) / 2)
        hits.append((ui.rows - 1...ui.rows - 1, col...(col + text.count), .more))
        return ui.at(ui.rows - 1, col) + ui.blue(text)
    }

    private func mosaic() -> String {
        let layout = mosaicLayout()
        let selectedRow = groupIndex / layout.perRow
        if selectedRow < scroll { scroll = selectedRow }
        if selectedRow >= scroll + layout.visibleRows { scroll = selectedRow - layout.visibleRows + 1 }

        let first = scroll * layout.perRow
        let last = min(run.groups.count, first + layout.visibleRows * layout.perRow)
        var out = overviewHeader(range: range(first: first, shown: last - first))
        let inner = layout.cardWidth - 2
        let coverWidth = inner * 2 / 3
        let sideWidth = inner - coverWidth - 1
        for index in first..<last {
            let g = run.groups[index]
            let r = 3 + (index / layout.perRow - scroll) * (layout.imageRows + 5)
            let c = 2 + (index % layout.perRow) * (layout.cardWidth + 3)
            let selected = index == groupIndex
            out += ui.box(row: r, col: c, width: layout.cardWidth, height: layout.imageRows + 2,
                          paint: { [ui] in selected ? ui.blue($0) : ui.gray($0) }, heavy: selected)

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
            out += ui.at(r + layout.imageRows + 2, c) + ui.clip(cardTitle(g, selected: selected), layout.cardWidth)
            out += ui.at(r + layout.imageRows + 3, c) + ui.clip(cardCounts(g), layout.cardWidth)
            hits.append((r...(r + layout.imageRows + 3), c...(c + layout.cardWidth - 1), .group(index)))
        }
        return out + moreIndicator(after: last) + ui.actionBar(
            hints: "space open · k keep group · x move rest · m move · u undo · ? keys",
            short: "space open · ? keys", action: moveButton(run.toMove.count))
    }

    // Overview B: one row per group, every photo visible.
    private func filmstrip() -> String {
        let (cols, rows) = (ui.cols, ui.rows)
        let thumbRows = rows >= 40 ? 5 : 4
        let thumbWidth = thumbRows * 8 / 3
        let stacked = cols < 64
        let rowHeight = thumbRows + (stacked ? 3 : 2)
        let visible = filmstripVisible
        if groupIndex < scroll { scroll = groupIndex }
        if groupIndex >= scroll + visible { scroll = groupIndex - visible + 1 }

        let labelWidth = stacked ? 0 : 26
        let fits = max(1, (cols - labelWidth - 4) / (thumbWidth + 1))
        let last = min(run.groups.count, scroll + visible)
        var out = overviewHeader(range: range(first: scroll, shown: last - scroll))
        for index in scroll..<last {
            let g = run.groups[index]
            let r = 3 + (index - scroll) * rowHeight
            let selected = index == groupIndex
            if stacked {
                out += ui.at(r, 3) + ui.clip(cardTitle(g, selected: selected) + "  " + cardCounts(g), cols - 3)
            } else {
                out += ui.at(r, 3) + ui.clip(cardTitle(g, selected: selected), labelWidth - 1)
                out += ui.at(r + 1, 3) + ui.clip(cardCounts(g), labelWidth - 1)
                out += ui.at(r + 2, 3) + ui.dim("\(g.photos.count) photos")
            }
            let strip = stacked ? r + 1 : r
            if selected { for y in 0..<(strip - r + thumbRows) { out += ui.at(r + y, 1) + ui.blue("▌") } }

            let shown = Run.displayOrder(g)
            for (k, member) in shown.prefix(fits).enumerated() {
                let c = 3 + labelWidth + k * (thumbWidth + 1)
                if fits > 1, k == fits - 1, shown.count > fits {
                    out += ui.at(strip + thumbRows / 2, c + 3) + ui.bold("+\(shown.count - fits + 1)")
                    break
                }
                let kept = g.pick.isKept(member.id)
                if let url = thumb(member) {
                    out += ui.image(url, row: strip, col: c, cols: thumbWidth, rows: thumbRows, dim: !kept)
                }
                // A rule under each: green best, white kept, blue moving.
                let rule = String(repeating: "▔", count: thumbWidth)
                out += ui.at(strip + thumbRows, c)
                    + (g.pick.keepers.contains(member.id) ? ui.green(rule) : kept ? rule : g.pick.moved.contains(member.id) ? ui.gray(rule) : ui.blue(rule))
            }
            hits.append((r...(strip + thumbRows), 1...cols, .group(index)))
        }
        return out + moreIndicator(after: last) + ui.actionBar(
            hints: "space open · k keep group · x move rest · m move · u undo · ? keys",
            short: "space open · ? keys", action: moveButton(run.toMove.count))
    }

    /// Photo tiles for one group, as large as the window allows while
    /// showing them all, in 4:3 boxes (a cell is two square pixels tall).
    private struct GroupLayout {
        var perRow = 1, tileWidth = 20, imageRows = 4, visible = 0

        init(count n: Int, cols: Int, rows: Int) {
            let available = rows - 4
            var best: (perRow: Int, width: Int, imageRows: Int)?
            for perRow in 1...max(1, min(n, 8)) {
                var width = min(60, (cols - 2 - (perRow - 1) * 2) / perRow)
                guard width >= 14 else { break }
                let lines = (n + perRow - 1) / perRow
                let byWidth = (width - 2) * 3 / 8
                let imageRows = min(byWidth, available / lines - 6)
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
            visible = min(n, max(1, available / (imageRows + 6)) * perRow)
        }
    }

    private enum State { case best, keep, move, moved }

    private func state(_ id: String) -> State {
        pick.keepers.contains(id) ? .best : pick.isKept(id) ? .keep : pick.moved.contains(id) ? .moved : .move
    }

    private func label(_ state: State, number: Int) -> String {
        switch state {
        case .best: return ui.green(" \(number) ★ Best ")
        case .keep: return " \(number) Keep "
        case .move: return ui.blue(" \(number) ✓ Move ")
        case .moved: return ui.dim(" \(number) Moved ")
        }
    }

    /// The line under a photo: what happens to it and why.
    private func caption(_ id: String, _ state: State, width: Int) -> [String] {
        let note = pick.notes[id] ?? ""
        switch state {
        case .best: return ui.wrap(note, width: width, lines: 2).map { self.ui.green($0) }
        case .keep: return ui.wrap("Keep · " + (pick.decidedBy == "you" ? "you chose" : note), width: width, lines: 2)
        case .moved: return [ui.dim(ui.fit("Moved to Duplicates", width))]
        case .move:
            if let reason = pick.reasons[id] ?? pick.suggestions[id] {
                return [ui.blue("Move · ") + ui.amber(ui.fit(reason, width - 7))]
            }
            return ui.wrap("Move · " + note, width: width, lines: 2).map { self.ui.blue($0) }
        }
    }

    private func groupGrid() -> String {
        let (cols, rows) = (ui.cols, ui.rows)
        let n = order.count
        let layout = GroupLayout(count: n, cols: cols, rows: rows)
        let moving = group.photos.map(\.id).filter { pick.willMove($0) }.count
        var header = ui.bold(Format.day.string(from: group.photos[0].date)) + ui.dim(" · ")
            + ui.blue(group.kind.title) + ui.dim(" · \(n) photos · group \(groupIndex + 1) of \(run.groups.count)")
        if pick.decidedBy == "apple-model" { header += ui.dim("  ✦ close call, picked by Apple Intelligence") }
        var out = ui.at(1, 2) + ui.clip(header, cols - 2)

        for index in 0..<min(n, layout.visible) {
            let member = order[index]
            let s = state(member.id)
            let r = 3 + (index / layout.perRow) * (layout.imageRows + 6)
            let c = 2 + (index % layout.perRow) * (layout.tileWidth + 2)
            let ui = self.ui, focused = index == cursor
            let paint: (String) -> String = { focused ? ui.blue($0) : s == .best ? ui.green($0) : ui.gray($0) }
            out += ui.box(row: r, col: c, width: layout.tileWidth, height: layout.imageRows + 2,
                          label: label(s, number: index + 1), paint: paint, heavy: index == cursor)
            if let url = thumb(member) {
                out += ui.image(url, row: r + 1, col: c + 1, cols: layout.tileWidth - 2, rows: layout.imageRows,
                                dim: s == .move || s == .moved)
            }
            for (k, line) in caption(member.id, s, width: layout.tileWidth).prefix(2).enumerated() {
                out += ui.at(r + layout.imageRows + 2 + k, c) + line
            }
            out += ui.at(r + layout.imageRows + 4, c) + ui.dim(ui.fit(meta(member, short: true), layout.tileWidth))
            hits.append((r...(r + layout.imageRows + 1), c...(c + layout.tileWidth - 1), .photo(index)))
        }
        if layout.visible < n {
            out += ui.at(rows - 2, 2) + ui.dim(ui.fit("+\(n - layout.visible) more: enlarge any photo and use → to reach them", cols - 2))
        }
        return out + ui.actionBar(
            hints: "space look · k keep · x move · b best · c compare · u undo · esc back · ? keys",
            short: "k keep · x move · ? keys", action: moveButton(moving, label: "Move \(moving)"))
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
        case .move: status = ui.blue("✓ Move") + ((pick.reasons[member.id] ?? pick.suggestions[member.id]).map { ui.dim(" · ") + ui.amber($0) } ?? "")
        }
        let header = ui.bold(Format.day.string(from: group.photos[0].date))
            + ui.dim(" · photo \(cursor + 1) of \(order.count)  ") + status
        var out = ui.at(1, 2) + ui.clip(header, cols - 2)
        if let files = images[member.id] {
            out += ui.image(folder.appendingPathComponent(files.full), row: 3, col: 2, cols: cols - 2,
                            rows: max(4, rows - 6), dim: false, large: true)
        }
        let note = ui.fit(pick.notes[member.id] ?? "", cols - 2)
        out += ui.at(rows - 2, 2) + ui.center(s == .best ? ui.green(note) : note, width: cols - 2)
        out += ui.at(rows - 1, 2) + ui.center(ui.dim(ui.fit(meta(member, short: false), cols - 2)), width: cols - 2)
        return out + ui.actionBar(
            hints: "← → photos · k keep · x move · b best · c compare · space back · ? keys",
            short: "k keep · x move · space back")
    }

    /// Two photos side by side: the pinned one on the left (the best shot to
    /// start with) and a candidate on the right, with what's better or worse.
    private func compareView() -> String {
        let (cols, rows) = (ui.cols, ui.rows)
        let left = order[pinned], right = order[cursor]
        let candidates = order.indices.filter { $0 != pinned }
        let position = (candidates.firstIndex(of: cursor) ?? 0) + 1
        var out = ui.at(1, 2) + ui.clip(ui.bold("Compare") + ui.dim(" · ")
            + Format.day.string(from: group.photos[0].date)
            + ui.dim(" · candidate \(position) of \(candidates.count) · group \(groupIndex + 1) of \(run.groups.count)"), cols - 2)

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
                out += ui.image(folder.appendingPathComponent(files.full), row: 4, col: c + 1,
                                cols: paneWidth - 2, rows: imageRows, dim: false, large: true)
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
            hints: "← → next candidate · ↑ pin it · k keep · x move · b best · esc back · ? keys",
            short: "← → · k keep · x move · esc")
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
        return ui.sheet([
            ui.bold("Keys"),
            "",
            row("← → ↑ ↓", "move around"),
            row("space", "look closer · again to go back"),
            row("enter", "open · confirm"),
            row("esc", "back · cancel (never changes anything)"),
            "",
            row("k", "keep this photo (or the whole group)"),
            row("x", "move this photo (group: all but the best)"),
            row("b", "make it the best ★"),
            row("r", "say why it's moving"),
            row("c", "compare two photos side by side"),
            "",
            row("m", "move the selection to Duplicates (asks first)"),
            row("u", "undo the last change or move"),
            row("v", "mosaics or filmstrips"),
            row("n  p", "next or previous group"),
            row("q", "quit · everything is saved as you go"),
            "",
            ui.dim("any key to close"),
        ], width: 64)
    }

    private func reasonSheet() -> String {
        let id = order[cursor].id
        let suggestion = pick.suggestions[id]
        var lines = [ui.bold("Why move photo \(cursor + 1)?")]
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

    private func confirmSheet(_ ids: [String]) -> String {
        let count = "\(ids.count) photo\(ids.count == 1 ? "" : "s")"
        let detail: [String]
        switch source {
        case .album(_, let title):
            detail = ["They’ll leave \(title) but stay in your library.", "Delete them from the Duplicates album whenever you’re ready."]
        case .dates:
            detail = ["They stay in your library, collected in the", "“\(Library.duplicatesAlbum)” album for you to delete when ready."]
        case .folder(let path):
            detail = ["They’ll go into a “\(Files.duplicatesFolder)” folder", "inside \((path as NSString).lastPathComponent), with their RAW and sidecar files."]
        }
        let destination = source.isPhotos ? "“\(Library.duplicatesAlbum)”" : "Duplicates"
        var lines = [ui.bold("Move \(count) to \(destination)?"), ""]
        lines += detail.map { ui.dim($0) }
        lines += ["", ui.spread("", ui.dim("esc Cancel   ") + ui.button("enter Move \(ids.count)"), width: min(ui.cols - 2, 60) - 4)]
        return ui.sheet(lines)
    }

    private func meta(_ member: Run.Member, short: Bool) -> String {
        var parts = [Format.time.string(from: member.date)]
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
