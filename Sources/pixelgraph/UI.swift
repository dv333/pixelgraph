import CoreGraphics
import ImageIO
import Foundation

/// The look shared by every PixelGraph screen: one calm palette, text that
/// always fits its line, frames, the bottom action bar, and photos drawn as
/// real images (iTerm2, WezTerm, kitty, Ghostty) or colour blocks elsewhere.
final class UI: @unchecked Sendable {
    let term = Terminal()
    /// How this terminal shows real images; nil for colour blocks.
    var graphics: TerminalImage.Graphics?
    var sharp: Bool { graphics != nil }
    private(set) var active = false

    private var images: [String: CGImage] = [:]

    /// Drops every photo kept in memory; call after a scan rewrites the previews.
    func forgetImages() {
        images = [:]
        blocks = [:]
        encoded = [:]
        sizes = [:]
        placed = [:]
    }
    private var blocks: [String: [String]] = [:]
    /// Pictures ready to send: JPEG for iTerm2's protocol, PNG for kitty's.
    private var encoded: [String: Data] = [:]

    init(graphics: TerminalImage.Mode = .auto) {
        self.graphics = graphics.resolved
    }

    func enter() {
        guard !active else { return }
        Theme.detect(background: sharp)
        term.enter()
        // Keep the window's own title to put back, and name it PixelGraph meanwhile.
        term.write("\u{1B}[22;0t" + title("PixelGraph"))
        active = true
    }

    func leave() {
        guard active else { return }
        if graphics == .kitty { term.write(TerminalImage.kittyClear) }
        term.write("\u{1B}[23;0t")
        term.leave()
        active = false
    }

    var cols: Int { term.size.cols }
    var rows: Int { term.size.rows }

    /// The window's title, e.g. "PixelGraph · Japan 2025 · 12/40 reviewed".
    func title(_ text: String) -> String { "\u{1B}]2;\(text)\u{07}" }

    /// Too small to lay a screen out well.
    var tooSmall: Bool { cols < 60 || rows < 16 }

    /// Said instead of a squashed screen, until the window is bigger.
    func tooSmallScreen() -> String {
        clear() + at(max(1, rows / 2 - 1), 1) + center(bold("Make the window bigger"), width: cols)
            + at(max(2, rows / 2), 1) + center(dim("PixelGraph needs at least 60 × 16; this is \(cols) × \(rows)"), width: cols)
    }

    /// Key hints with the keys in the accent colour and the words dim:
    /// "k keep · x move · esc back".
    func hints(_ text: String) -> String {
        let names: Set<String> = ["space", "enter", "esc", "tab", "home", "end"]
        return text.components(separatedBy: " · ").map { segment in
            var words = segment.split(separator: " ").map(String.init)
            var keys: [String] = []
            while words.count > 1, let word = words.first, word.count == 1 || names.contains(word) || word.allSatisfy({ "←→↑↓".contains($0) }) {
                keys.append(words.removeFirst())
            }
            guard !keys.isEmpty else { return dim(segment) }
            return blue(keys.joined(separator: " ")) + dim(" " + words.joined(separator: " "))
        }.joined(separator: dim(" · "))
    }

    /// Clears the screen, kitty's images included (clearing the text alone leaves them).
    func clear() -> String {
        placed = [:]
        return "\u{1B}[0m\u{1B}[2J" + (graphics == .kitty ? TerminalImage.kittyClear : "")
    }

    /// One frame of a screen, for the terminal to show all at once rather
    /// than as it arrives (synchronized output; terminals without it
    /// ignore the request).
    func frame(_ drawing: String) -> String {
        drawing.isEmpty ? drawing : "\u{1B}[?2026h" + drawing + "\u{1B}[?2026l"
    }

    // MARK: Text

    func at(_ row: Int, _ col: Int) -> String { "\u{1B}[\(row);\(col)H" }
    func bold(_ s: String) -> String { "\u{1B}[1m\(s)\u{1B}[22m" }
    func dim(_ s: String) -> String { "\u{1B}[2m\(s)\u{1B}[22m" }
    func green(_ s: String) -> String { Theme.fg(Theme.green) + s + "\u{1B}[39m" }
    func red(_ s: String) -> String { Theme.fg(Theme.red) + s + "\u{1B}[39m" }
    func amber(_ s: String) -> String { Theme.fg(Theme.amber) + s + "\u{1B}[39m" }
    func blue(_ s: String) -> String { Theme.fg(Theme.blue) + s + "\u{1B}[39m" }
    func teal(_ s: String) -> String { Theme.fg(Theme.teal) + s + "\u{1B}[39m" }
    func gray(_ s: String) -> String { Theme.fg(Theme.line) + s + "\u{1B}[39m" }

    /// A filled button, like the one primary action on a screen.
    func button(_ s: String) -> String { Theme.bg(Theme.accent) + Theme.fg(Theme.onAccent) + " \(plain(s)) \u{1B}[0m" }

    /// A filled red button, for an action that can't be undone here (deleting).
    func dangerButton(_ s: String) -> String { Theme.bg(Theme.red) + Theme.fg(Theme.onRed) + " \(plain(s)) \u{1B}[0m" }

    /// The accent bar that marks the selected row, sheets and the bottom bar.
    func bar() -> String { Theme.fg(Theme.accent) + "▌" + "\u{1B}[39m" }

    /// Styled text kept on a background: every reset puts it back.
    func on(_ background: Theme.RGB, _ styled: String) -> String {
        let restore = Theme.bg(background) + Theme.fg(Theme.panelText)
        return styled.replacingOccurrences(of: "\u{1B}[0m", with: "\u{1B}[0m" + restore)
            .replacingOccurrences(of: "\u{1B}[39m", with: "\u{1B}[39m" + Theme.fg(Theme.panelText))
    }

    /// The selected row in a list, on a soft grey; draw `bar()` just left of it.
    func highlight(_ s: String, width: Int) -> String {
        let text = on(Theme.selection, clip(s, width))
        return Theme.bg(Theme.selection) + Theme.fg(Theme.panelText) + text
            + String(repeating: " ", count: max(0, width - visibleWidth(text))) + "\u{1B}[0m"
    }

    /// A full-width line on the panel grey with the accent bar on the left,
    /// like OpenCode's input box. `content` starts at column 3.
    func barLine(_ row: Int, _ content: String) -> String {
        // The last column stays empty, so the bottom row can't scroll the screen.
        let width = max(4, cols - 1)
        let body = on(Theme.panel, clip(content, width - 2))
        return at(row, 1) + "\u{1B}[2K" + Theme.bg(Theme.panel) + bar() + Theme.fg(Theme.panelText) + " " + body
            + String(repeating: " ", count: max(0, width - 2 - visibleWidth(body))) + "\u{1B}[0m"
    }

    /// Text without colour or weight codes.
    func plain(_ styled: String) -> String {
        var out = "", inEscape = false
        for ch in styled {
            if inEscape { if ch.isLetter { inEscape = false }; continue }
            if ch == "\u{1B}" { inEscape = true; continue }
            out.append(ch)
        }
        return out
    }

    /// Cuts styled text to `width` visible characters, keeping its colour codes.
    func clip(_ styled: String, _ width: Int) -> String {
        guard width > 0 else { return "" }
        guard visibleWidth(styled) > width else { return styled }
        var out = "", visible = 0, inEscape = false
        for ch in styled {
            if inEscape { out.append(ch); if ch.isLetter { inEscape = false }; continue }
            if ch == "\u{1B}" { inEscape = true; out.append(ch); continue }
            guard visible < width - 1 else { break }
            out.append(ch)
            visible += 1
        }
        return out + "…\u{1B}[0m"
    }

    func visibleWidth(_ styled: String) -> Int {
        var count = 0, inEscape = false
        for ch in styled {
            if inEscape { if ch.isLetter { inEscape = false }; continue }
            if ch == "\u{1B}" { inEscape = true; continue }
            count += 1
        }
        return count
    }

    func fit(_ s: String, _ width: Int) -> String {
        s.count <= width ? s : String(s.prefix(max(0, width - 1))) + "…"
    }

    /// `left` and `right` on one line, `right` flush with the edge.
    func spread(_ left: String, _ right: String, width: Int) -> String {
        let gap = width - visibleWidth(left) - visibleWidth(right)
        guard gap >= 2 else { return clip(left, max(0, width - visibleWidth(right) - 2)) + "  " + right }
        return left + String(repeating: " ", count: gap) + right
    }

    func center(_ styled: String, width: Int) -> String {
        String(repeating: " ", count: max(0, (width - visibleWidth(styled)) / 2)) + styled
    }

    func wrap(_ text: String, width: Int, lines: Int) -> [String] {
        guard lines > 0 else { return [] }
        var result: [String] = []
        var current = ""
        for word in text.split(separator: " ") {
            if current.isEmpty { current = String(word) }
            else if current.count + 1 + word.count <= width { current += " " + word }
            else { result.append(current); current = String(word) }
        }
        if !current.isEmpty { result.append(current) }
        if result.count > lines {
            result = Array(result.prefix(lines))
            result[lines - 1] = fit(result[lines - 1] + " …", width)
        }
        return result.map { fit($0, width) }
    }

    /// A frame of `width` × `height` cells with an optional label in the top edge.
    func box(row: Int, col: Int, width: Int, height: Int, label: String? = nil,
             paint: (String) -> String, heavy: Bool = false) -> String {
        let (h, v, tl, tr, bl, br) = heavy ? ("━", "┃", "┏", "┓", "┗", "┛") : ("─", "│", "╭", "╮", "╰", "╯")
        let inner = width - 2
        let text = label.map { clip($0, max(0, inner - 1)) } ?? ""
        let rest = max(0, inner - visibleWidth(text) - (text.isEmpty ? 0 : 1))
        var out = at(row, col) + paint(tl + (text.isEmpty ? "" : h)) + text + paint(String(repeating: h, count: rest) + tr)
        for y in 1..<(height - 1) {
            out += at(row + y, col) + paint(v) + at(row + y, col + width - 1) + paint(v)
        }
        return out + at(row + height - 1, col) + paint(bl + String(repeating: h, count: inner) + br)
    }

    /// The bottom row: key hints on the left, the screen's main action on the right.
    func actionBar(hints: String, short: String, action: String = "") -> String {
        let width = cols - 2
        let room = width - visibleWidth(action) - 2
        let left = visibleWidth(hints) <= room ? hints : short
        return barLine(rows, spread(clip(self.hints(left), max(0, room)), action, width: width - 1))
    }

    /// A question asked in place, never in a box over the screen: the
    /// bottom two rows become one panel, with `note` (styled; what will
    /// happen, in a sentence) above and the question, its keys and its
    /// buttons on the bar. A click on a button is the same as its key; anywhere else, esc.
    func prompt(_ question: String, note: String = "", keys: String = "esc cancel", buttons: String = "") -> String {
        let width = cols - 3
        let left = bold(question) + (keys.isEmpty ? "" : "   " + hints(keys))
        let line = spread(clip(left, max(0, width - visibleWidth(buttons) - 3)), buttons, width: width - 1)
        promptRows = (rows - 1)...rows
        // The bar's text starts in column 3, after the accent bar and a space.
        promptButtons = buttonColumns(line).map { (rows, ($0.range.lowerBound + 3)...($0.range.upperBound + 3), $0.danger) }
        return barLine(rows - 1, clip(note, width - 2)) + barLine(rows, line)
    }

    /// Progress in the bottom bar while something runs: what, and how far
    /// when that's known.
    func progress(_ detail: String, fraction: Double? = nil) -> String {
        guard let fraction else { return barLine(rows - 1, "") + barLine(rows, clip(bold(detail), cols - 4)) }
        let percent = "\(Int((max(0, min(1, fraction)) * 100).rounded()))%"
        let barWidth = max(8, min(40, cols / 3))
        return barLine(rows - 1, "") + barLine(rows, spread(clip(bold(detail), max(0, cols - barWidth - 14)),
                                                             ProgressBoard.bar(fraction, width: barWidth) + "  " + dim(percent), width: cols - 4))
    }

    /// The keys of a screen as a page of its own, in sections, two columns
    /// when the window is wide enough and one column won't fit.
    func keysPage(_ title: String, _ sections: [(name: String, keys: [(key: String, does: String)])]) -> String {
        let width = max(20, min(cols - 4, 96)), left = max(3, (cols - width) / 2 + 1)
        func block(_ section: (name: String, keys: [(key: String, does: String)])) -> [String] {
            [dim(section.name.uppercased())] + section.keys.map { blue($0.key.padding(toLength: 13, withPad: " ", startingAt: 0)) + $0.does }
        }
        let blocks = sections.map(block)
        let room = rows - 6
        let oneColumn = blocks.flatMap { $0 + [""] }.dropLast()
        var out = clear() + at(2, left) + bold(title)
        if oneColumn.count <= room || width < 80 {
            for (n, line) in oneColumn.prefix(room).enumerated() { out += at(4 + n, left) + clip(line, width) }
        } else {
            // Sections in order down the first column, then the second.
            let half = (oneColumn.count + 1) / 2
            var columns: [[String]] = [[], []]
            for b in blocks { let c = columns[0].count < half ? 0 : 1; columns[c] += (columns[c].isEmpty ? [] : [""]) + b }
            let columnWidth = (width - 4) / 2
            for (c, lines) in columns.enumerated() {
                for (n, line) in lines.prefix(room).enumerated() { out += at(4 + n, left + c * (columnWidth + 4)) + clip(line, columnWidth) }
            }
        }
        return out + barLine(rows, String(repeating: " ", count: max(0, left - 3)) + hints("any key back"))
    }

    /// Where the question in the bottom bar is, and its buttons.
    private var promptRows: ClosedRange<Int>?
    private var promptButtons: [(row: Int, cols: ClosedRange<Int>, danger: Bool)] = []

    enum PromptClick: Equatable { case button(danger: Bool), inside, outside }

    /// What a click hit while a question is in the bar: a button (the red one
    /// deletes, the other is the same as enter), the rest of the bar
    /// (nothing), or the screen above it (the same as esc).
    func promptClick(row: Int, col: Int) -> PromptClick {
        if let hit = promptButtons.first(where: { $0.row == row && $0.cols.contains(col) }) { return .button(danger: hit.danger) }
        return promptRows?.contains(row) == true ? .inside : .outside
    }

    /// The same for a key; nil when it isn't a click.
    func promptClick(_ key: Terminal.Key) -> PromptClick? {
        guard case .click(let row, let col) = key else { return nil }
        return promptClick(row: row, col: col)
    }

    /// The visible columns of the filled buttons in a line of styled text, and which are red.
    private func buttonColumns(_ styled: String) -> [(range: ClosedRange<Int>, danger: Bool)] {
        let accent = Theme.bg(Theme.accent), red = Theme.bg(Theme.red)
        var ranges: [(range: ClosedRange<Int>, danger: Bool)] = [], start: (column: Int, danger: Bool)?, column = 0, escape = ""
        for ch in styled {
            if ch == "\u{1B}" || !escape.isEmpty {
                escape.append(ch)
                guard ch.isLetter else { continue }
                if escape == accent || escape == red {
                    start = (column, escape == red)
                } else if escape == "\u{1B}[0m", let first = start {
                    if column > first.column { ranges.append((first.column...(column - 1), first.danger)) }
                    start = nil
                }
                escape = ""
                continue
            }
            column += 1
        }
        return ranges
    }

    // MARK: Photos

    private typealias Box = (row: Int, col: Int, cols: Int, rows: Int)

    /// A photo file drawn into `cols` × `rows` cells, letterboxed, optionally
    /// muted. Zooming in is `zoomed`; `replacing` is for a box that's also
    /// drawn that way, so what the zoomed photo covered is tidied up.
    func image(_ url: URL, row: Int, col: Int, cols: Int, rows: Int, dim: Bool, large: Bool = false,
               replacing: Bool = false) -> String {
        guard cols > 0, rows > 0 else { return "" }
        let key = url.path + (dim ? "|dim" : "")
        if let graphics {
            var box: Box = (row, col, cols, rows)
            if let size = pixelSize(url) { box = fit(size, in: box) }
            // As many pixels as the box really has on screen (Retina included),
            // so the terminal never has to stretch a small picture up.
            let side = boxPixels(cols: box.cols, rows: box.rows)
            let sized = key + "|\(side)|\(graphics)"
            if encoded[sized] == nil {
                let file = side > 720 ? larger(url) : url
                if graphics == .iTerm, !dim, large, let data = try? Data(contentsOf: file) {
                    encoded[sized] = data
                } else if var source = picture(file, maxSide: side) {
                    if dim { source = TerminalImage.darkened(source) ?? source }
                    encoded[sized] = graphics == .kitty ? TerminalImage.png(source) : TerminalImage.jpeg(source)
                }
            }
            guard let data = encoded[sized] else { return at(row, col) + self.dim("no preview") }
            return place(data, box, replacing: replacing ? (row, col, cols, rows) : nil)
        }
        let blockKey = key + "|\(cols)x\(rows)"
        if blocks[blockKey] == nil {
            guard let source = picture(url, maxSide: large ? max(cols, rows * 2) * 2 : 480) else {
                return at(row, col) + self.dim("no preview")
            }
            blocks[blockKey] = TerminalImage.blocks(source, cols: cols, rows: rows, dim: dim)
        }
        return blocks[blockKey]!.enumerated().map { at(row + $0.offset, col) + $0.element }.joined()
    }

    /// Part of a big picture, cut out and drawn to fill the box: how the
    /// review zooms in. Drawn fresh each time, since every step and move
    /// shows something different, and over what was there, so zooming
    /// never blanks the screen. `quick` is for the frames of a gesture:
    /// half the pixels, to keep up with the fingers.
    func zoomed(_ source: CGImage, crop: CGRect, row: Int, col: Int, cols: Int, rows: Int, quick: Bool = false) -> String {
        guard cols > 0, rows > 0 else { return "" }
        guard let graphics else {
            guard let cut = TerminalImage.crop(source, to: crop) else { return "" }
            return TerminalImage.blocks(cut, cols: cols, rows: rows).enumerated().map { at(row + $0.offset, col) + $0.element }.joined()
        }
        // Where the shown part sits in the box, to the pixel: centred, and
        // all of the box once the photo is bigger than it.
        let cell = cellSize
        let boxWidth = Double(cols) * cell.width, boxHeight = Double(rows) * cell.height
        let shown = Double(source.width) * crop.width / max(1, Double(source.height) * crop.height)
        let width = min(boxWidth, boxHeight * shown), height = min(boxHeight, boxWidth / shown)
        let x = (boxWidth - width) / 2, y = (boxHeight - height) / 2
        // A picture takes whole cells: the ones this touches. It's drawn
        // where it belongs inside them, so it grows smoothly instead of a
        // cell at a time, and what's left of them is the background.
        let left = Int((x / cell.width + 0.001).rounded(.down)), right = min(cols, Int(((x + width) / cell.width - 0.001).rounded(.up)))
        let top = Int((y / cell.height + 0.001).rounded(.down)), bottom = min(rows, Int(((y + height) / cell.height - 0.001).rounded(.up)))
        let box: Box = (row + top, col + left, max(1, right - left), max(1, bottom - top))
        let scale = pixelScale(cols: box.cols, rows: box.rows) * (quick ? 0.5 : 1)
        let rect = CGRect(x: (x - Double(left) * cell.width) * scale, y: (y - Double(top) * cell.height) * scale,
                          width: width * scale, height: height * scale)
        // kitty's pictures can be see-through; iTerm2's JPEGs can't.
        let background: Theme.RGB? = graphics == .kitty ? nil : Theme.background ?? (Theme.light ? (255, 255, 255) : (0, 0, 0))
        guard let picture = TerminalImage.canvas(source, crop: crop, into: rect,
                                                 width: max(1, Int((Double(box.cols) * cell.width * scale).rounded())),
                                                 height: max(1, Int((Double(box.rows) * cell.height * scale).rounded())),
                                                 background: background, quick: quick),
              let data = graphics == .kitty ? TerminalImage.png(picture) : TerminalImage.jpeg(picture, quality: quick ? 0.6 : 0.9)
        else { return "" }
        // Made the shape of its cells, so it covers every bit of them.
        return place(data, box, replacing: (row, col, cols, rows), stretch: true)
    }

    /// A picture made on the fly (the font preview in Settings), drawn like a
    /// photo; `key` names it so it's encoded once.
    func image(_ picture: CGImage, key: String, row: Int, col: Int, cols: Int, rows: Int) -> String {
        guard let graphics, cols > 0, rows > 0 else { return "" }
        let box = fit((picture.width, picture.height), in: (row, col, cols, rows))
        let sized = key + "|\(graphics)"
        if encoded[sized] == nil { encoded[sized] = graphics == .kitty ? TerminalImage.png(picture) : TerminalImage.jpeg(picture) }
        guard let data = encoded[sized] else { return "" }
        return place(data, box)
    }

    /// The part of a box a picture of this size fills, centred, in whole
    /// cells: the terminal draws from the box's top-left, so the box is
    /// shrunk to the picture instead.
    private func fit(_ size: (width: Int, height: Int), in box: Box) -> Box {
        var box = box
        let aspect = Double(size.width) / Double(max(1, size.height))
        let cell = term.cellAspect
        let boxAspect = Double(box.cols) * cell / Double(box.rows)
        if aspect < boxAspect {
            let fitted = max(1, min(box.cols, Int((Double(box.rows) * aspect / cell).rounded())))
            box.col += (box.cols - fitted) / 2
            box.cols = fitted
        } else {
            let fitted = max(1, min(box.rows, Int((Double(box.cols) * cell / aspect).rounded())))
            box.row += (box.rows - fitted) / 2
            box.rows = fitted
        }
        return box
    }

    /// Where the last picture went in each box that's redrawn in place.
    private var placed: [String: Box] = [:]

    /// Puts encoded picture data on screen, the way this terminal takes it.
    /// In a box that's redrawn in place (`full`, while zooming), whatever
    /// the last picture covered and this one doesn't is cleared too.
    private func place(_ data: Data, _ box: Box, replacing full: Box? = nil, stretch: Bool = false) -> String {
        var tidy = ""
        if let full {
            let key = "\(full.row);\(full.col);\(full.cols);\(full.rows)"
            if let old = placed[key], old != box {
                if graphics == .kitty {
                    // A picture somewhere else has another id: take the old one away.
                    if old.row != box.row || old.col != box.col { tidy = "\u{1B}_Ga=d,d=I,i=\(old.row * 1000 + old.col),q=2\u{1B}\\" }
                } else {
                    tidy = blank(full, around: box)
                }
            }
            placed[key] = box
        }
        switch graphics {
        case .kitty:
            // One id per spot on screen, so a redrawn tile replaces its picture.
            return tidy + TerminalImage.kitty(data, id: box.row * 1000 + box.col, row: box.row, col: box.col, cols: box.cols, rows: box.rows)
        default:
            return tidy + TerminalImage.iTerm(data, row: box.row, col: box.col, cols: box.cols, rows: box.rows, stretch: stretch)
        }
    }

    /// Empties the cells of `full` outside `box`: iTerm2's pictures live in
    /// cells, and go when the cells are written over.
    private func blank(_ full: Box, around box: Box) -> String {
        var out = "\u{1B}[0m"
        for r in full.row..<(full.row + full.rows) {
            guard r >= box.row, r < box.row + box.rows else {
                out += at(r, full.col) + String(repeating: " ", count: full.cols)
                continue
            }
            let before = box.col - full.col, after = full.col + full.cols - (box.col + box.cols)
            if before > 0 { out += at(r, full.col) + String(repeating: " ", count: before) }
            if after > 0 { out += at(r, box.col + box.cols) + String(repeating: " ", count: after) }
        }
        return out
    }

    /// Pictures here live in cells, so they move when the screen is scrolled
    /// and only the rows that come into view need drawing. kitty's don't.
    var scrollsPictures: Bool { graphics != .kitty }

    /// How many pixels a picture covering this many cells should have.
    func pixels(cols: Int, rows: Int) -> (width: Int, height: Int) {
        let cell = cellSize, scale = pixelScale(cols: cols, rows: rows)
        return (max(1, Int((Double(cols) * cell.width * scale).rounded())), max(1, Int((Double(rows) * cell.height * scale).rounded())))
    }

    /// A picture made the shape of `cols` × `total` cells, or just the rows
    /// `rows` of it, drawn with its first row shown at `row`: how a grid of
    /// photos shows a tile that's only partly in view.
    func tile(_ picture: CGImage, rows: Range<Int>, of total: Int, row: Int, col: Int, cols: Int) -> String {
        guard let graphics, !rows.isEmpty, total > 0 else { return "" }
        let height = Double(picture.height) / Double(total)
        let top = (Double(rows.lowerBound) * height).rounded(), bottom = (Double(rows.upperBound) * height).rounded()
        let cut = rows.count == total ? picture
            : picture.cropping(to: CGRect(x: 0, y: top, width: Double(picture.width), height: max(1, bottom - top)))
        guard let cut, let data = graphics == .kitty ? TerminalImage.png(cut) : TerminalImage.jpeg(cut, quality: 0.85) else { return "" }
        return place(data, (row, col, cols, rows.count), stretch: true)
    }

    /// A cell's size as the terminal reports it; the usual 8 × 16 when it doesn't say.
    var cellSize: (width: Double, height: Double) {
        let window = term.pixelSize, size = term.size
        guard window.width > 0, window.height > 0, size.cols > 0, size.rows > 0 else { return (8, 16) }
        return (Double(window.width) / Double(size.cols), Double(window.height) / Double(size.rows))
    }

    /// Picture pixels for each unit of that size, for a picture this many
    /// cells big: the display's scale (terminals may report points, not
    /// pixels), but never more than 2048 pixels on the long side.
    private func pixelScale(cols: Int, rows: Int) -> Double {
        let cell = cellSize
        let long = max(Double(cols) * cell.width, Double(rows) * cell.height)
        let display = CGDisplayCopyDisplayMode(CGMainDisplayID()).map { Double($0.pixelWidth) / Double(max(1, $0.width)) } ?? 1
        return min(max(1, display), 2048 / max(1, long))
    }

    private var sizes: [String: (width: Int, height: Int)] = [:]

    /// A photo file's pixel size, upright.
    private func pixelSize(_ url: URL) -> (width: Int, height: Int)? {
        if let known = sizes[url.path] { return known }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var w = props[kCGImagePropertyPixelWidth] as? Int, var h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return nil }
        if let orientation = props[kCGImagePropertyOrientation] as? Int, orientation >= 5 { swap(&w, &h) }
        sizes[url.path] = (w, h)
        return (w, h)
    }

    /// The long side, in screen pixels, of a box of cells, rounded up to a
    /// step of 128 so the cache isn't redone for every small resize. 480 when
    /// the terminal doesn't say how big its cells are.
    func boxPixels(cols: Int, rows: Int) -> Int {
        let window = term.pixelSize, size = term.size
        guard window.width > 0, window.height > 0, size.cols > 0, size.rows > 0 else { return 480 }
        let w = Double(cols) * Double(window.width) / Double(size.cols)
        let h = Double(rows) * Double(window.height) / Double(size.rows)
        // Terminals may report points rather than pixels; on a Retina display
        // ask for the display's scale too (at worst a little more than needed).
        let scale = CGDisplayCopyDisplayMode(CGMainDisplayID()).map { Double($0.pixelWidth) / Double(max(1, $0.width)) } ?? 1
        let long = Int((max(w, h) * max(1, scale)).rounded(.up))
        return min(2048, max(256, (long + 127) / 128 * 128))
    }

    /// The report keeps each photo twice: a 720px preview ("-s.jpg") and a
    /// 2048px one ("-l.jpg"). Big boxes use the big one.
    private func larger(_ url: URL) -> URL {
        let name = url.lastPathComponent
        guard name.hasSuffix("-s.jpg") else { return url }
        let big = url.deletingLastPathComponent().appendingPathComponent(String(name.dropLast(6)) + "-l.jpg")
        return FileManager.default.fileExists(atPath: big.path) ? big : url
    }

    private func picture(_ url: URL, maxSide: Int) -> CGImage? {
        let key = url.path + "|\(maxSide)"
        if images[key] == nil { images[key] = TerminalImage.load(url, maxSide: maxSide) }
        return images[key]
    }
}
