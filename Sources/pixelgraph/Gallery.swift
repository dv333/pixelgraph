import CoreGraphics
import Foundation

/// How a gallery's tiles sit in its part of the screen and scroll, in text
/// rows and columns. Photos fill rows left to right, oldest first.
struct GalleryGrid: Equatable {
    /// How many photos, the area's size and a tile's size, all in cells.
    var count: Int
    var cols: Int
    var rows: Int
    var tileCols: Int
    var tileRows: Int

    var perRow: Int { max(1, cols / max(1, tileCols)) }
    /// The columns left over, half of them on each side.
    var margin: Int { max(0, cols - perRow * tileCols) / 2 }
    /// Every row of tiles, in text rows, and how far down that scrolls.
    var contentRows: Int { (count + perRow - 1) / perRow * tileRows }
    var maxTop: Int { max(0, contentRows - rows) }

    /// The text rows a photo's tile takes, counted from the top of them all.
    func span(of index: Int) -> Range<Int> {
        let first = index / perRow * tileRows
        return first..<(first + tileRows)
    }

    /// The scroll position nearest `top` that shows the whole of a photo's tile.
    func top(showing index: Int, from top: Int) -> Int {
        let span = span(of: index)
        if span.lowerBound < top { return span.lowerBound }
        if span.upperBound > top + rows { return min(maxTop, span.upperBound - rows) }
        return min(max(0, top), maxTop)
    }

    /// The photo at a spot of the area (0-based) when scrolled to `top`; nil
    /// beside the tiles or past the last one.
    func index(row: Int, col: Int, top: Int) -> Int? {
        let across = col - margin
        guard row >= 0, row < rows, across >= 0, across < perRow * tileCols else { return nil }
        let index = (top + row) / tileRows * perRow + across / tileCols
        return index < count ? index : nil
    }

    /// The photos with any part of their tile in the text rows `span`.
    func indices(in span: Range<Int>) -> Range<Int> {
        guard !span.isEmpty, count > 0 else { return 0..<0 }
        let first = min(count, max(0, span.lowerBound) / tileRows * perRow)
        let last = min(count, ((span.upperBound - 1) / tileRows + 1) * perRow)
        return first..<max(first, last)
    }
}

/// "Jun 20, 2025", "Jun 19 – 21, 2025", "Jun 19 – Jul 2, 2025" or "Dec 2024
/// – Jan 2025": when the photos on screen were taken.
enum GalleryDates {
    static func range(_ from: Date, _ to: Date) -> String {
        let calendar = Calendar.current
        let full = Date.FormatStyle.dateTime.month(.abbreviated).day().year()
        if calendar.isDate(from, inSameDayAs: to) { return from.formatted(full) }
        if calendar.isDate(from, equalTo: to, toGranularity: .month) {
            // "Jun 19 – 21, 2025": the day and year on their own don't format as one piece.
            return from.formatted(.dateTime.month(.abbreviated).day())
                + " – \(calendar.component(.day, from: to)), \(calendar.component(.year, from: to))"
        }
        if calendar.isDate(from, equalTo: to, toGranularity: .year) {
            return from.formatted(.dateTime.month(.abbreviated).day()) + " – " + to.formatted(full)
        }
        let month = Date.FormatStyle.dateTime.month(.abbreviated).year()
        return from.formatted(month) + " – " + to.formatted(month)
    }
}

/// Loads pictures away from the main loop, a few at a time, in the order
/// they were asked for, so browsing never waits on a photo.
private final class GalleryLoader: @unchecked Sendable {
    typealias Work = @Sendable () async -> CGImage?

    private let lock = NSLock()
    private var waiting: [(key: String, work: Work)] = []
    /// Waiting or being loaded.
    private var known: Set<String> = []
    private var running = 0
    private var finished: [(key: String, image: CGImage?)] = []
    private let limit = 6

    /// Asks for `key`, unless it's already on its way; `first` puts it ahead
    /// of what's waiting.
    func want(_ key: String, first: Bool = false, _ work: @escaping Work) {
        lock.withLock {
            guard !known.contains(key) else { return }
            known.insert(key)
            if first { waiting.insert((key, work), at: 0) } else { waiting.append((key, work)) }
        }
        pump()
    }

    /// Gives up on what's waiting (not what's already loading) unless `keep` wants it.
    func drop(unless keep: (String) -> Bool) {
        lock.withLock {
            for entry in waiting where !keep(entry.key) { known.remove(entry.key) }
            waiting.removeAll { !keep($0.key) }
        }
    }

    /// What has finished since this was last asked.
    func collect() -> [(key: String, image: CGImage?)] {
        lock.withLock {
            let done = finished
            finished = []
            return done
        }
    }

    var busy: Bool { lock.withLock { running > 0 || !waiting.isEmpty || !finished.isEmpty } }

    private func pump() {
        let starting: [(key: String, work: Work)] = lock.withLock {
            var starting: [(key: String, work: Work)] = []
            while running < limit, !waiting.isEmpty {
                starting.append(waiting.removeFirst())
                running += 1
            }
            return starting
        }
        for entry in starting {
            Task.detached(priority: .userInitiated) {
                let image = await entry.work()
                self.finish(entry.key, image)
            }
        }
    }

    private func finish(_ key: String, _ image: CGImage?) {
        lock.withLock {
            running -= 1
            known.remove(key)
            finished.append((key, image))
        }
        pump()
    }
}

/// Looking through a place's photos the way Photos shows a library: a grid
/// of square tiles, oldest at the top, opened at the newest; and any photo
/// opened large to look at, zoom into and step through. Nothing is changed.
final class GallerySession {
    enum Outcome { case back, quit }

    private let title: String
    private let items: [Item]
    private let ui: UI
    private let settings = Settings.load()
    private let loader = GalleryLoader()

    private enum Screen { case grid, photo, keys }
    private var screen = Screen.grid
    /// Where ? was pressed, to go back to.
    private var keysFrom = Screen.grid
    /// The photo highlighted in the grid, or open.
    private var selected: Int
    private var message: String?
    private var lastInput = Date.now

    // MARK: The grid

    /// A tile's height in text rows: the sizes + and − go through.
    private static let sizes = [3, 4, 5, 6, 8, 10, 13, 16]
    private static let usualSize = 6
    private var tileRows: Int
    /// Text rows scrolled off the top.
    private var top = 0
    /// Small copies of the photos near what's on screen, whole (not cropped
    /// square): a tile is cut from one, and it stands in when a photo opens.
    private var thumbs: [Int: CGImage] = [:]
    private var blockLines: [Int: [String]] = [:]
    private var failed: Set<Int> = []
    /// Tiles on screen were drawn a few rows at a time while scrolling;
    /// once it rests they're drawn again whole, so no joins are left.
    private var pieced = false
    private let gridTop = 3, gridLeft = 2

    // MARK: The open photo

    private var zoom = 1.0
    private var center = CGPoint(x: 0.5, y: 0.5)
    private var dragFrom: (row: Int, col: Int)?
    /// The biggest copy loaded of the photos around the open one: 1 is a
    /// preview, 2 full size.
    private var pictures: [Int: (image: CGImage, level: Int)] = [:]
    private var fullAsked: Set<Int> = []
    /// As in the review: the key being handled is part of a gesture, so the
    /// photo is drawn quickly; and what's on screen was, and is owed a sharp one.
    private var live = false
    private var rough = false
    private var frameStarted = Date.distantPast
    private let photoRow = 3, photoCol = 2

    init(source: Source, items: [Item], graphics: TerminalImage.Mode = .auto, ui: UI? = nil) {
        title = source.description
        self.items = items
        self.ui = ui ?? UI(graphics: graphics)
        selected = max(0, items.count - 1)
        let saved = Database.open()?.state("gallery-tile-rows").flatMap { Int($0) }
        tileRows = saved.flatMap { Self.sizes.contains($0) ? $0 : nil } ?? Self.usualSize
    }

    func show() async -> Outcome {
        guard !items.isEmpty else { return .back }
        let ownsTerminal = !ui.active
        ui.enter()
        defer {
            Database.open()?.setState("gallery-tile-rows", String(tileRows))
            if ownsTerminal { ui.leave() }
        }
        fitSize()
        // Opens at the newest photos, as Photos does.
        top = grid.maxTop
        repaint()
        while true {
            // A gesture's frames come no faster than a display shows them.
            let early = 1.0 / 60 - Date.now.timeIntervalSince(frameStarted)
            if rough, early > 0 { usleep(UInt32(early * 1_000_000)) }
            guard let key = ui.term.nextKey(live: patience()) else {
                rest()
                continue
            }
            frameStarted = .now
            if let outcome = handle(key) { return outcome }
        }
    }

    /// How long to wait for a key before seeing to what's owed: pictures
    /// that have loaded, the sharp frame after a gesture, the full-size
    /// copy of a photo that's zoomed in. Nil when nothing is.
    private func patience() -> Int32? {
        var waits: [Double] = []
        if loader.busy { waits.append(0.03) }
        if screen == .grid, pieced { waits.append(0.25 - Date.now.timeIntervalSince(lastInput)) }
        if screen == .photo {
            let rested = Date.now.timeIntervalSince(lastInput)
            if rough { waits.append(0.15 - rested) } else if owesFullSize { waits.append(0.5 - rested) }
        }
        return waits.min().map { Int32((max(0.001, $0) * 1000).rounded(.up)) }
    }

    private var owesFullSize: Bool {
        zoom > 1 && (pictures[selected]?.level ?? 0) < 2 && !fullAsked.contains(selected)
    }

    /// No key for a while: draw what has loaded, and, with the fingers at
    /// rest, the photo sharp, then fetch its full-size copy.
    private func rest() {
        live = false
        var out = arrivals()
        if screen == .grid, pieced, Date.now.timeIntervalSince(lastInput) >= 0.25 {
            out = gridDrawing()
        }
        if screen == .photo {
            let rested = Date.now.timeIntervalSince(lastInput)
            if rough, rested >= 0.15 {
                out = photoFrame()
            } else if !rough, owesFullSize, rested >= 0.5 {
                wantFullSize(selected)
            }
        }
        emit(out)
    }

    private func emit(_ drawing: String) {
        ui.term.write(ui.frame(drawing))
    }

    // MARK: - Input

    private func handle(_ key: Terminal.Key) -> Outcome? {
        lastInput = .now
        switch key {
        case .quit, .char("q"): return .quit
        case .resize:
            fitSize()
            repaint()
            return nil
        default: break
        }
        if screen == .keys {
            screen = keysFrom
            repaint()
            return nil
        }
        if key == .char("?") {
            keysFrom = screen
            screen = .keys
            repaint()
            return nil
        }
        if message != nil {
            message = nil
            emit(messageLine())
        }
        switch screen {
        case .grid: return handleGrid(key)
        case .photo: handlePhoto(key)
        case .keys: break
        }
        return nil
    }

    private func handleGrid(_ key: Terminal.Key) -> Outcome? {
        let g = grid
        let page = g.perRow * max(1, g.rows / g.tileRows)
        switch key {
        case .left: select(selected - 1)
        case .right: select(selected + 1)
        case .up: if selected >= g.perRow { select(selected - g.perRow) }
        case .down:
            // From the row above a short last row, down goes to its end.
            if selected + g.perRow < items.count { select(selected + g.perRow) }
            else if selected / g.perRow < (items.count - 1) / g.perRow { select(items.count - 1) }
        case .pageDown: select(selected + page)
        case .pageUp: select(selected - page)
        case .home: select(0)
        case .end: select(items.count - 1)
        case .enter, .char(" "): open()
        case .char("+"), .char("="): resize(1)
        case .char("-"): resize(-1)
        case .char("0"): resize(to: Self.usualSize)
        // Two text rows a tick: a swipe glides, and a wheel still gets somewhere.
        case .scroll(let ticks) where ticks != 0:
            emit(scrolled(by: ticks * 2) + header())
            wantThumbs()
        case .click(let row, let col):
            guard let index = g.index(row: row - gridTop, col: col - gridLeft, top: top) else { break }
            if index == selected { open() } else { select(index) }
        case .char("o"): reveal()
        case .escape, .backspace: return .back
        default: break
        }
        return nil
    }

    private func handlePhoto(_ key: Terminal.Key) {
        switch key {
        case .scroll, .drag: live = true
        default: live = false
        }
        let before = (selected, zoom, center)
        let aspect = aspect(selected), box = boxAspect
        switch key {
        // Zoomed in, the arrows move around the photo; n and p still change it.
        case .left where zoom > 1: center = Zoom.panned(center, dx: -0.25, dy: 0, zoom: zoom, aspect: aspect, boxAspect: box)
        case .right where zoom > 1: center = Zoom.panned(center, dx: 0.25, dy: 0, zoom: zoom, aspect: aspect, boxAspect: box)
        case .up where zoom > 1: center = Zoom.panned(center, dx: 0, dy: -0.25, zoom: zoom, aspect: aspect, boxAspect: box)
        case .down where zoom > 1: center = Zoom.panned(center, dx: 0, dy: 0.25, zoom: zoom, aspect: aspect, boxAspect: box)
        case .click(let row, let col) where zoom > 1: dragFrom = (row, col)
        case .drag(let row, let col) where zoom > 1:
            if let from = dragFrom {
                center = Zoom.panned(center, dx: -Double(col - from.col) / Double(max(1, photoBox.cols)),
                                     dy: -Double(row - from.row) / Double(max(1, photoBox.rows)), zoom: zoom, aspect: aspect, boxAspect: box)
            }
            dragFrom = (row, col)
        case .char("+"), .char("="): setZoom(Zoom.stepped(zoom, 1), about: CGPoint(x: 0.5, y: 0.5))
        case .char("-"): setZoom(Zoom.stepped(zoom, -1), about: CGPoint(x: 0.5, y: 0.5))
        case .char("0"): resetZoom()
        case .scroll(let ticks) where ticks != 0: setZoom(Zoom.wheeled(zoom, ticks: ticks), about: pointer())
        case .left, .up, .char("p"): turn(to: selected - 1)
        case .right, .down, .char("n"): turn(to: selected + 1)
        case .home: turn(to: 0)
        case .end: turn(to: items.count - 1)
        case .char("o"): reveal()
        case .escape, .backspace, .enter, .char(" "), .click:
            close()
            return
        default: break
        }
        if before != (selected, zoom, center) { emit(photoFrame()) }
    }

    // MARK: - The grid

    private var grid: GalleryGrid {
        let cell = ui.cellSize
        // Square on screen: as many columns as are as wide as the rows are tall.
        let tileCols = max(2, Int((Double(tileRows) * cell.height / cell.width).rounded()))
        return GalleryGrid(count: items.count, cols: max(tileCols, ui.cols - 2), rows: max(1, ui.rows - 4),
                           tileCols: tileCols, tileRows: tileRows)
    }

    /// After the window changes: a tile no taller than the grid, and
    /// nothing scrolled past the end.
    private func fitSize() {
        let room = max(Self.sizes[0], ui.rows - 4)
        if tileRows > room { tileRows = Self.sizes.last { $0 <= room } ?? Self.sizes[0] }
        top = min(max(0, top), grid.maxTop)
    }

    /// + and −: the next size of tile, keeping the highlighted photo in view.
    private func resize(_ direction: Int) {
        let room = max(Self.sizes[0], ui.rows - 4)
        let allowed = Self.sizes.filter { $0 <= room }
        let here = allowed.firstIndex(of: tileRows) ?? allowed.firstIndex { $0 >= tileRows } ?? allowed.count - 1
        resize(to: allowed[min(max(0, here + direction), allowed.count - 1)])
    }

    private func resize(to size: Int) {
        guard size != tileRows, size <= max(Self.sizes[0], ui.rows - 4) else { return }
        // Keep the highlighted photo where it was on screen, as near as can be.
        let offset = grid.span(of: selected).lowerBound - top
        tileRows = size
        blockLines = [:]
        let g = grid
        top = min(max(0, g.span(of: selected).lowerBound - offset), g.maxTop)
        top = g.top(showing: selected, from: top)
        repaint()
    }

    /// Moves the highlight, scrolling it into view.
    private func select(_ index: Int) {
        let next = min(max(0, index), items.count - 1)
        guard next != selected else { return }
        let old = selected
        selected = next
        scroll(to: grid.top(showing: next, from: top))
        emit(tile(old) + tile(next) + header())
        wantThumbs()
    }

    /// Scrolls to `target`, gliding there a few rows a frame when it's
    /// near; straight there when it's far, or keys are already waiting.
    private func scroll(to target: Int) {
        var remaining = target - top
        guard remaining != 0 else { return }
        guard ui.scrollsPictures, abs(remaining) < grid.rows, !ui.term.keyPending else {
            emit(scrolled(by: remaining))
            return
        }
        while remaining != 0 {
            let started = Date.now
            let step = remaining > 0 ? max(1, (remaining + 2) / 3) : min(-1, (remaining - 2) / 3)
            emit(scrolled(by: step))
            remaining -= step
            let early = 1.0 / 60 - Date.now.timeIntervalSince(started)
            if remaining != 0, early > 0 { usleep(UInt32(early * 1_000_000)) }
        }
    }

    /// The drawing for scrolling by `delta` text rows (down the photos when
    /// positive). Where pictures move with the screen, the terminal shifts
    /// what's there and only the rows that come into view are drawn.
    private func scrolled(by delta: Int) -> String {
        let g = grid
        let target = min(max(0, top + delta), g.maxTop), moved = target - top
        guard moved != 0 else { return "" }
        top = target
        guard ui.scrollsPictures, abs(moved) < g.rows else { return gridDrawing() }
        pieced = true
        let shift = moved > 0 ? "\u{1B}[\(moved)S" : "\u{1B}[\(-moved)T"
        let shown = moved > 0 ? (top + g.rows - moved)..<(top + g.rows) : top..<(top - moved)
        return "\u{1B}[0m\u{1B}[\(gridTop);\(gridTop + g.rows - 1)r" + shift + "\u{1B}[r" + tiles(in: shown)
    }

    /// Every tile in view, drawn over what's there.
    private func gridDrawing() -> String {
        let g = grid
        pieced = false
        // kitty's pictures stay where they were put: take them away first.
        return (ui.graphics == .kitty ? TerminalImage.kittyClear : "") + tiles(in: top..<(top + g.rows))
    }

    /// The parts, within the text rows `span`, of every tile that has any
    /// there; a slot with no photo (or none loaded yet) is emptied.
    private func tiles(in span: Range<Int>) -> String {
        let g = grid
        let span = span.clamped(to: top..<(top + g.rows))
        guard !span.isEmpty else { return "" }
        var out = "\u{1B}[0m"
        for tileRow in (span.lowerBound / g.tileRows)...((span.upperBound - 1) / g.tileRows) {
            for slot in 0..<g.perRow {
                out += tile(tileRow * g.perRow + slot, in: span)
            }
        }
        return out
    }

    /// One photo's tile, or as much of it as is in view (and in `span`).
    private func tile(_ index: Int, in span: Range<Int>? = nil) -> String {
        let g = grid
        let whole = g.span(of: index)
        let part = whole.clamped(to: (span ?? whole).clamped(to: top..<(top + g.rows)))
        guard !part.isEmpty else { return "" }
        let rows = (part.lowerBound - whole.lowerBound)..<(part.upperBound - whole.lowerBound)
        let row = gridTop + part.lowerBound - top, col = gridLeft + g.margin + index % g.perRow * g.tileCols
        guard index < items.count, let thumb = thumbs[index] else {
            return (0..<rows.count).map { ui.at(row + $0, col) + String(repeating: " ", count: g.tileCols) }.joined()
        }
        if ui.sharp {
            let size = ui.pixels(cols: g.tileCols, rows: g.tileRows)
            // A point and a half between tiles; twice that for the border of the one highlighted.
            let inset = max(1, Int((1.5 * Double(size.height) / (Double(g.tileRows) * ui.cellSize.height)).rounded()))
            let background: Theme.RGB? = ui.graphics == .kitty ? nil : Theme.background ?? (Theme.light ? (255, 255, 255) : (0, 0, 0))
            guard let picture = TerminalImage.tile(thumb, width: size.width, height: size.height, inset: inset, background: background,
                                                   outline: index == selected ? Theme.accent : nil) else { return "" }
            return ui.tile(picture, rows: rows, of: g.tileRows, row: row, col: col, cols: g.tileCols)
        }
        if blockLines[index] == nil, let picture = TerminalImage.tile(thumb, width: g.tileCols, height: g.tileRows * 2, inset: 0,
                                                                     background: nil, outline: nil) {
            blockLines[index] = TerminalImage.blocks(picture, cols: g.tileCols, rows: g.tileRows)
        }
        guard let lines = blockLines[index], lines.count == g.tileRows else { return "" }
        var out = rows.enumerated().map { ui.at(row + $0.offset, col) + lines[$0.element] }.joined()
        if index == selected, rows.count == g.tileRows {
            out += ui.box(row: row, col: col, width: g.tileCols, height: g.tileRows, paint: ui.blue, heavy: true)
        }
        return out
    }

    /// The size the small copies on hand were loaded for; they're loaded
    /// again when tiles get bigger than that.
    private var thumbsAreFor: Int?

    /// Asks for the small copies of what's in view first, then a screen
    /// either side, and lets go of the ones far away.
    private func wantThumbs() {
        let g = grid
        if let size = thumbsAreFor, size < tileRows {
            thumbs = [:]
            blockLines = [:]
            failed = []
        }
        thumbsAreFor = max(thumbsAreFor ?? 0, tileRows)
        let visible = g.indices(in: top..<(top + g.rows))
        let near = g.indices(in: max(0, top - g.rows)..<min(g.contentRows, top + 2 * g.rows))
        let size = tileRows
        loader.drop { key in
            let parts = key.split(separator: "|")
            guard parts.first == "t" else { return true }
            return parts.count == 3 && Int(parts[1]) == size && Int(parts[2]).map(near.contains) == true
        }
        let pixels = ui.sharp ? ui.pixels(cols: g.tileCols, rows: g.tileRows) : (g.tileCols * 4, g.tileRows * 8)
        let side = Double(max(pixels.0, pixels.1))
        for index in Array(visible) + near.filter({ !visible.contains($0) }) where thumbs[index] == nil && !failed.contains(index) {
            let item = items[index]
            // Enough to fill the square once the long side is cropped.
            let shape = item.width > 0 && item.height > 0 ? Double(max(item.width, item.height)) / Double(min(item.width, item.height)) : 1.5
            let wanted = CGFloat(side * min(3, shape))
            loader.want("t|\(size)|\(index)") { await item.image(maxSide: wanted, fetch: .localOnly) }
        }
        let kept = g.indices(in: max(0, top - 4 * g.rows)..<(top + 5 * g.rows))
        if thumbs.count > kept.count + g.perRow {
            thumbs = thumbs.filter { kept.contains($0.key) || $0.key == selected }
            blockLines = blockLines.filter { kept.contains($0.key) }
        }
    }

    /// Takes in what has loaded, and gives the drawing for whatever of it is on screen.
    private func arrivals() -> String {
        var out = ""
        var photoChanged = false
        for (key, image) in loader.collect() {
            let parts = key.split(separator: "|")
            switch parts.first {
            case "t":
                guard parts.count == 3, Int(parts[1]) == tileRows, let index = Int(parts[2]) else { continue }
                guard let image else {
                    failed.insert(index)
                    continue
                }
                thumbs[index] = image
                blockLines[index] = nil
                if screen == .grid { out += tile(index) }
                if screen == .photo, index == selected, pictures[index] == nil { photoChanged = true }
            case "p", "f":
                guard parts.count == 2, let index = Int(parts[1]), let image else { continue }
                let level = parts.first == "f" ? 2 : 1
                // Never a smaller copy over a bigger one.
                if let have = pictures[index], have.level >= level || max(have.image.width, have.image.height) >= max(image.width, image.height) {
                    continue
                }
                guard abs(index - selected) <= 2 else { continue }
                pictures[index] = (image, level)
                if screen == .photo, index == selected { photoChanged = true }
            default: continue
            }
        }
        if photoChanged { out += photoFrame() }
        return out
    }

    private func header() -> String {
        let g = grid
        let view = g.indices(in: top..<(top + g.rows))
        let left = ui.bold(ui.fit(title, 40)) + ui.dim(" · " + App.photos(items.count))
        let right = view.isEmpty ? "" : ui.dim(GalleryDates.range(items[view.lowerBound].date, items[view.upperBound - 1].date)
            + "  ·  \((view.lowerBound + 1).formatted())–\(view.upperBound.formatted()) of \(items.count.formatted())")
        return ui.at(1, 2) + ui.spread(left, right, width: ui.cols - 2) + "\u{1B}[K"
    }

    private func messageLine() -> String {
        ui.at(ui.rows - 1, 1) + "\u{1B}[2K" + (message.map { " " + ui.center($0, width: ui.cols - 2) } ?? "")
    }

    // MARK: - The open photo

    private var photoBox: (cols: Int, rows: Int) { (ui.cols - 2, max(4, ui.rows - 5)) }
    private var boxAspect: Double { Double(photoBox.cols) * ui.term.cellAspect / Double(max(1, photoBox.rows)) }

    /// The best copy on hand of a photo: full size, a preview, or its small one.
    private func best(_ index: Int) -> CGImage? { pictures[index]?.image ?? thumbs[index] }

    private func aspect(_ index: Int) -> Double {
        if let image = best(index) { return Double(image.width) / Double(max(1, image.height)) }
        let item = items[index]
        return item.width > 0 && item.height > 0 ? Double(item.width) / Double(item.height) : 1.5
    }

    private func open() {
        screen = .photo
        resetZoom()
        wantPhotos()
        repaint()
    }

    private func close() {
        screen = .grid
        resetZoom()
        rough = false
        live = false
        // Full-size copies are big: keep them only while the photo is open.
        pictures = [:]
        fullAsked = []
        top = grid.top(showing: selected, from: top)
        repaint()
    }

    /// Shows another photo, whole, where the last one was.
    private func turn(to index: Int) {
        let next = min(max(0, index), items.count - 1)
        guard next != selected else { return }
        selected = next
        resetZoom()
        wantPhotos()
    }

    private func resetZoom() {
        zoom = 1
        center = CGPoint(x: 0.5, y: 0.5)
        dragFrom = nil
    }

    /// Where the pointer is over the photo's box (0 … 1 across and down),
    /// or its middle when it's somewhere else.
    private func pointer() -> CGPoint {
        guard let at = ui.term.pointer, (photoRow..<(photoRow + photoBox.rows)).contains(at.row),
              (photoCol..<(photoCol + photoBox.cols)).contains(at.col) else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: (Double(at.col - photoCol) + 0.5) / Double(photoBox.cols), y: (Double(at.row - photoRow) + 0.5) / Double(photoBox.rows))
    }

    /// Zooms to `next`, keeping the spot of the photo under `point` where it is.
    private func setZoom(_ next: Double, about point: CGPoint) {
        guard next != zoom else { return }
        guard next > 1 else { return resetZoom() }
        center = Zoom.center(zoomingTo: next, from: zoom, center: center, about: point, aspect: aspect(selected), boxAspect: boxAspect)
        zoom = next
    }

    /// Asks for a screen-sized copy of the open photo, ahead of everything
    /// else, then of the ones either side, so turning to them is instant.
    private func wantPhotos() {
        pictures = pictures.filter { abs($0.key - selected) <= 2 }
        fullAsked = fullAsked.filter { $0 == selected }
        // A full-size copy is only kept for the photo that's open.
        for (index, picture) in pictures where index != selected && picture.level == 2 { pictures[index] = nil }
        loader.drop { key in
            let parts = key.split(separator: "|")
            guard parts.first == "p" || parts.first == "f" else { return true }
            return parts.count == 2 && Int(parts[1]).map { abs($0 - selected) <= 1 } == true
        }
        for (offset, first) in [(0, true), (1, false), (-1, false)] {
            let index = selected + offset
            guard items.indices.contains(index), pictures[index] == nil else { continue }
            let item = items[index]
            loader.want("p|\(index)", first: first) { await item.image(maxSide: 2048, fetch: .localOnly) }
            if offset == 0, thumbs[index] == nil {
                // Something to show at once, while that loads.
                loader.want("t|\(tileRows)|\(index)", first: true) { await item.image(maxSide: 320, fetch: .localOnly) }
            }
        }
    }

    /// The photo as big as it comes, for looking closely: a folder's file,
    /// or the library's original, from iCloud if need be (unless Settings
    /// say stay offline).
    private func wantFullSize(_ index: Int) {
        fullAsked.insert(index)
        let item = items[index], offline = settings.bool(.offline)
        loader.want("f|\(index)", first: true) {
            if case .photo(let asset) = item.backing { return await Library.fullSize(asset, maxSide: 4096, download: !offline) }
            return await item.image(maxSide: 4096, fetch: offline ? .localOnly : .download(timeout: 30))
        }
    }

    /// The whole photo screen, drawn over what's there: zooming, moving
    /// around and turning to the next photo never blank it.
    private func photoFrame() -> String {
        let (cols, rows) = (ui.cols, ui.rows)
        let item = items[selected]
        let zoomNote = zoom > 1 ? ui.dim("  · ") + ui.blue(Zoom.label(zoom)) + ui.dim(" · 0 whole photo") : ""
        let header = ui.dim(ui.fit(title, 30) + " › ") + ui.bold("Photo \((selected + 1).formatted()) of \(items.count.formatted())")
            + ui.dim(" · ") + Format.day.string(from: item.date) + zoomNote
        var out = ui.at(1, 2) + ui.clip(header, cols - 2) + "\u{1B}[K"
        if let source = best(selected) {
            let crop = Zoom.crop(zoom: zoom, center: center, aspect: Double(source.width) / Double(max(1, source.height)), boxAspect: boxAspect)
            out += ui.zoomed(source, crop: crop, row: photoRow, col: photoCol, cols: photoBox.cols, rows: photoBox.rows, quick: live)
        }
        out += ui.at(rows - 2, 1) + "\u{1B}[2K" + ui.at(rows - 2, 2) + ui.center(ui.dim(ui.fit(about(item), cols - 2)), width: cols - 2)
        out += messageLine()
        rough = live && ui.sharp
        if zoom > 1 {
            return out + ui.actionBar(hints: "← → ↑ ↓ move around · n p photos · + − zoom · 0 whole photo · esc back",
                                      short: "←→↑↓ move · n p · + − · 0 all")
        }
        return out + ui.actionBar(hints: "← → photos · + zoom · o show in \(showsIn(item)) · space back · ? keys",
                                  short: "← → photos · + zoom · space back")
    }

    /// "IMG_1234.jpg · 4032 × 3024 · 2.1 MB".
    private func about(_ item: Item) -> String {
        var parts: [String] = []
        if let url = item.fileURL { parts.append(url.lastPathComponent) }
        if item.width > 0, item.height > 0 { parts.append("\(item.width) × \(item.height)") }
        if item.fileURL != nil, let bytes = item.bytes {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }

    private func showsIn(_ item: Item) -> String { item.fileURL == nil ? "Photos" : "Finder" }

    /// o: the highlighted or open photo, shown in Finder or in Photos.
    private func reveal() {
        let item = items[selected]
        let process = Process()
        if let url = item.fileURL {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-R", url.path]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", "on run argv", "-e", "tell application \"Photos\"", "-e", "activate",
                                 "-e", "spotlight media item id (item 1 of argv)", "-e", "end tell", "-e", "end run", item.id]
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        message = (try? process.run()) != nil ? ui.green("✓") + " Shown in \(showsIn(item))" : ui.red("Couldn't show it in \(showsIn(item))")
        emit(messageLine())
    }

    // MARK: - Drawing a whole screen

    private func repaint() {
        if ui.tooSmall {
            ui.term.write(ui.tooSmallScreen())
            return
        }
        switch screen {
        case .grid:
            top = min(max(0, top), grid.maxTop)
            wantThumbs()
            emit(ui.clear() + header() + gridDrawing() + messageLine() + ui.actionBar(
                hints: "← → ↑ ↓ choose · space open · + − size · o show in \(showsIn(items[selected])) · esc back · ? keys",
                short: "space open · + − size · esc back", action: ui.button("Open")))
        case .photo:
            emit(ui.clear() + photoFrame())
        case .keys:
            emit(ui.keysPage("Keys", [
                ("Browsing", [("← → ↑ ↓", "choose a photo · home, end: the oldest, the newest"), ("wheel", "scroll through them"),
                              ("+  −", "bigger or smaller tiles · 0: the usual size"), ("space enter", "open the photo · click it twice")]),
                ("A photo", [("← →", "the photo before, the next one · n p too"), ("+  −", "zoom in or out · the wheel zooms smoothly"),
                             ("← → ↑ ↓", "zoomed: move around · or drag"), ("0", "the whole photo again"),
                             ("space esc", "back to the photos")]),
                ("Elsewhere", [("o", "show the photo in Finder or Photos"), ("esc", "back · nothing here changes your photos"),
                               ("q", "quit")]),
            ]) + ui.barLine(ui.rows, ui.hints("any key back")))
        }
    }
}
