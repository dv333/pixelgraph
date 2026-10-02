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
    }
    private var blocks: [String: [String]] = [:]
    /// Pictures ready to send: JPEG for iTerm2's protocol, PNG for kitty's.
    private var encoded: [String: Data] = [:]

    init(graphics: TerminalImage.Mode = .auto) {
        self.graphics = graphics.resolved
    }

    func enter() {
        guard !active else { return }
        Theme.detect()
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
    func clear() -> String { "\u{1B}[0m\u{1B}[2J" + (graphics == .kitty ? TerminalImage.kittyClear : "") }

    // MARK: Text

    func at(_ row: Int, _ col: Int) -> String { "\u{1B}[\(row);\(col)H" }
    func bold(_ s: String) -> String { "\u{1B}[1m\(s)\u{1B}[22m" }
    func dim(_ s: String) -> String { "\u{1B}[2m\(s)\u{1B}[22m" }
    func green(_ s: String) -> String { Theme.fg(Theme.green) + s + "\u{1B}[39m" }
    func red(_ s: String) -> String { Theme.fg(Theme.red) + s + "\u{1B}[39m" }
    func amber(_ s: String) -> String { Theme.fg(Theme.amber) + s + "\u{1B}[39m" }
    func blue(_ s: String) -> String { Theme.fg(Theme.blue) + s + "\u{1B}[39m" }
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

    /// A centred panel over the current screen, for confirmations and choices.
    /// One too tall for the window is cut short with "…", so it never covers
    /// the bottom bar.
    func sheet(_ lines: [String], width preferred: Int = 60) -> String {
        let width = min(cols - 2, preferred)
        let panel = Theme.bg(Theme.panel) + Theme.fg(Theme.panelText)
        let room = max(2, rows - 4)
        let lines = lines.count > room ? Array(lines.prefix(room - 1)) + [dim("…")] : lines
        let top = max(2, (rows - lines.count) / 2), left = (cols - width) / 2 + 1
        sheetFrame = (top...(top + lines.count + 1), left...(left + width - 1))
        sheetButtons = []
        var out = ""
        for (y, text) in ([""] + lines + [""]).enumerated() {
            let body = on(Theme.panel, clip(text, width - 4))
            for columns in buttonColumns(body) {
                sheetButtons.append((top + y, (left + 2 + columns.range.lowerBound)...(left + 2 + columns.range.upperBound),
                                     columns.danger))
            }
            out += at(top + y, left) + panel + bar() + Theme.fg(Theme.panelText) + " " + body
                + String(repeating: " ", count: max(0, width - 2 - visibleWidth(body))) + "\u{1B}[0m"
        }
        return out
    }

    /// Where the last sheet was drawn, and its buttons.
    private var sheetFrame: (rows: ClosedRange<Int>, cols: ClosedRange<Int>)?
    private var sheetButtons: [(row: Int, cols: ClosedRange<Int>, danger: Bool)] = []

    enum SheetClick: Equatable { case button(danger: Bool), inside, outside }

    /// What a click hit on the sheet showing: a button (the red one deletes,
    /// the other is the same as enter), somewhere else on it (nothing), or
    /// outside it (the same as esc).
    func sheetClick(row: Int, col: Int) -> SheetClick {
        if let hit = sheetButtons.first(where: { $0.row == row && $0.cols.contains(col) }) { return .button(danger: hit.danger) }
        if let frame = sheetFrame, frame.rows.contains(row), frame.cols.contains(col) { return .inside }
        return .outside
    }

    /// The same for a key; nil when it isn't a click.
    func sheetClick(_ key: Terminal.Key) -> SheetClick? {
        guard case .click(let row, let col) = key else { return nil }
        return sheetClick(row: row, col: col)
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
    /// muted. `crop` (0 … 1, top-left origin) shows just that part, cut from
    /// the biggest preview so it stays sharp: how z zooms in on faces.
    func image(_ url: URL, row: Int, col: Int, cols: Int, rows: Int, dim: Bool, large: Bool = false, crop: CGRect? = nil) -> String {
        guard cols > 0, rows > 0 else { return "" }
        let key = url.path + (dim ? "|dim" : "") + (crop.map { "|\($0.minX),\($0.minY),\($0.width),\($0.height)" } ?? "")
        if let graphics {
            var box: Box = (row, col, cols, rows)
            if let size = pixelSize(url) {
                let shown = crop.map { (width: max(1, Int(Double(size.width) * $0.width)), height: max(1, Int(Double(size.height) * $0.height))) } ?? size
                box = fit(shown, in: box)
            }
            // As many pixels as the box really has on screen (Retina included),
            // so the terminal never has to stretch a small picture up.
            let side = boxPixels(cols: box.cols, rows: box.rows)
            let sized = key + "|\(side)|\(graphics)"
            if encoded[sized] == nil {
                let file = side > 720 || crop != nil ? larger(url) : url
                if graphics == .iTerm, !dim, large, crop == nil, let data = try? Data(contentsOf: file) {
                    encoded[sized] = data
                } else if var source = picture(file, maxSide: crop == nil ? side : 2048) {
                    if let crop, let cut = TerminalImage.crop(source, to: crop) { source = cut }
                    if dim { source = TerminalImage.darkened(source) ?? source }
                    encoded[sized] = graphics == .kitty ? TerminalImage.png(source) : TerminalImage.jpeg(source)
                }
            }
            guard let data = encoded[sized] else { return at(row, col) + self.dim("no preview") }
            return place(data, box)
        }
        let blockKey = key + "|\(cols)x\(rows)"
        if blocks[blockKey] == nil {
            let file = crop == nil ? url : larger(url)
            guard var source = picture(file, maxSide: crop != nil ? 2048 : large ? max(cols, rows * 2) * 2 : 480) else {
                return at(row, col) + self.dim("no preview")
            }
            if let crop, let cut = TerminalImage.crop(source, to: crop) { source = cut }
            blocks[blockKey] = TerminalImage.blocks(source, cols: cols, rows: rows, dim: dim)
        }
        return blocks[blockKey]!.enumerated().map { at(row + $0.offset, col) + $0.element }.joined()
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

    /// Puts encoded picture data on screen, the way this terminal takes it.
    private func place(_ data: Data, _ box: Box) -> String {
        switch graphics {
        case .kitty:
            // One id per spot on screen, so a redrawn tile replaces its picture.
            TerminalImage.kitty(data, id: box.row * 1000 + box.col, row: box.row, col: box.col, cols: box.cols, rows: box.rows)
        default:
            TerminalImage.iTerm(data, row: box.row, col: box.col, cols: box.cols, rows: box.rows)
        }
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
