import CoreGraphics
import ImageIO
import Foundation

/// The look shared by every PixelGraph screen: one calm palette, text that
/// always fits its line, frames, the bottom action bar, and photos drawn as
/// real images in iTerm2 or colour blocks elsewhere.
final class UI: @unchecked Sendable {
    let term = Terminal()
    let sharp: Bool
    private(set) var active = false

    private var images: [String: CGImage] = [:]

    /// Drops every photo kept in memory; call after a scan rewrites the previews.
    func forgetImages() {
        images = [:]
        blocks = [:]
        jpegs = [:]
        sizes = [:]
    }
    private var blocks: [String: [String]] = [:]
    private var jpegs: [String: Data] = [:]

    init(graphics: TerminalImage.Mode = .auto) {
        sharp = graphics.sharp
    }

    func enter() {
        guard !active else { return }
        Theme.detect()
        term.enter()
        active = true
    }

    func leave() {
        guard active else { return }
        term.leave()
        active = false
    }

    var cols: Int { term.size.cols }
    var rows: Int { term.size.rows }

    func clear() -> String { "\u{1B}[0m\u{1B}[2J" }

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
    func button(_ s: String) -> String { Theme.bg(Theme.accent) + "\u{1B}[38;2;255;255;255m \(plain(s)) \u{1B}[0m" }

    /// The selected row in a list: white text on a solid blue bar, so it reads
    /// the same on light and dark terminals.
    func highlight(_ s: String, width: Int) -> String {
        let text = plain(s)
        return Theme.bg(Theme.accent) + "\u{1B}[38;2;255;255;255m" + text
            + String(repeating: " ", count: max(0, width - text.count)) + "\u{1B}[0m"
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
        return at(rows, 2) + "\u{1B}[2K" + spread(dim(clip(left, max(0, room))), action, width: width)
    }

    /// A centred panel over the current screen, for confirmations and choices.
    func sheet(_ lines: [String], width preferred: Int = 60) -> String {
        let width = min(cols - 2, preferred)
        let panel = Theme.bg(Theme.panel) + Theme.fg(Theme.panelText)
        let top = max(2, (rows - lines.count) / 2), left = (cols - width) / 2 + 1
        var out = ""
        for (y, text) in ([""] + lines + [""]).enumerated() {
            let body = clip(text, width - 4).replacingOccurrences(of: "\u{1B}[0m", with: "\u{1B}[0m" + panel)
                .replacingOccurrences(of: "\u{1B}[22m", with: "\u{1B}[22m" + panel)
                .replacingOccurrences(of: "\u{1B}[39m", with: "\u{1B}[39m" + panel)
            out += at(top + y, left) + panel + "  " + body
                + String(repeating: " ", count: max(0, width - 2 - visibleWidth(body))) + "\u{1B}[0m"
        }
        return out
    }

    // MARK: Photos

    /// A photo file drawn into `cols` × `rows` cells, letterboxed, optionally darkened.
    func image(_ url: URL, row: Int, col: Int, cols: Int, rows: Int, dim: Bool, large: Bool = false) -> String {
        guard cols > 0, rows > 0 else { return "" }
        let key = url.path + (dim ? "|dim" : "")
        if sharp {
            // iTerm2 draws an image from the left/top of its box; work out the
            // photo's size in cells and centre the box on it instead.
            var (row, col, cols, rows) = (row, col, cols, rows)
            if let size = pixelSize(url) {
                let aspect = Double(size.width) / Double(size.height)
                let cell = term.cellAspect
                let boxAspect = Double(cols) * cell / Double(rows)
                if aspect < boxAspect {
                    let fitted = max(1, min(cols, Int((Double(rows) * aspect / cell).rounded())))
                    col += (cols - fitted) / 2
                    cols = fitted
                } else {
                    let fitted = max(1, min(rows, Int((Double(cols) * cell / aspect).rounded())))
                    row += (rows - fitted) / 2
                    rows = fitted
                }
            }
            // As many pixels as the box really has on screen (Retina included),
            // so iTerm2 never has to stretch a small picture up.
            let side = boxPixels(cols: cols, rows: rows)
            let sized = key + "|\(side)"
            if jpegs[sized] == nil {
                let file = side > 720 ? larger(url) : url
                if !dim, large, let data = try? Data(contentsOf: file) {
                    jpegs[sized] = data
                } else if let source = picture(file, maxSide: side) {
                    jpegs[sized] = TerminalImage.jpeg(dim ? TerminalImage.darkened(source) ?? source : source)
                }
            }
            guard let data = jpegs[sized] else { return at(row, col) + self.dim("no preview") }
            return TerminalImage.iTerm(data, row: row, col: col, cols: cols, rows: rows)
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
    private func boxPixels(cols: Int, rows: Int) -> Int {
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
