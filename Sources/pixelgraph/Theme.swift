import AppKit
import Darwin
import Foundation

/// The typeface for what PixelGraph draws itself: the opening title and the
/// web report's headings. Text on the screens is the terminal's own font.
/// All five come with macOS, so nothing has to be installed.
enum Typeface: String, CaseIterable, Sendable {
    /// Matches the terminal: each letter of the title gets its own column of lights.
    case sfMono = "SF Mono"
    case sfPro = "SF Pro"
    case avenirNext = "Avenir Next"
    case futura = "Futura"
    case newYork = "New York"

    /// The typeface at `size` and `weight`, or the nearest weight it has
    /// (Futura's lightest is Medium).
    func font(size: Double, weight: NSFont.Weight) -> NSFont {
        let system = NSFont.systemFont(ofSize: size, weight: weight)
        switch self {
        case .sfMono: return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        case .sfPro: return system
        case .newYork:
            return system.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? system
        case .avenirNext, .futura:
            let descriptor = NSFontDescriptor(fontAttributes: [.family: rawValue, .traits: [NSFontDescriptor.TraitKey.weight: weight]])
            return NSFont(descriptor: descriptor, size: size) ?? system
        }
    }

    /// The same typeface for the report, with fallbacks for browsers that don't know it.
    var css: String {
        switch self {
        case .sfMono: #"ui-monospace, "SF Mono", Menlo, monospace"#
        case .sfPro: #"-apple-system, BlinkMacSystemFont, "SF Pro Display", system-ui, sans-serif"#
        case .avenirNext: #""Avenir Next", Avenir, -apple-system, system-ui, sans-serif"#
        case .futura: #"Futura, "Avenir Next", -apple-system, system-ui, sans-serif"#
        case .newYork: #"ui-serif, "New York", Charter, Georgia, serif"#
        }
    }
}

/// Colours that stay readable on both light and dark terminals, in the
/// style of OpenCode: a purple accent on light backgrounds and a blue one on
/// dark, soft grey panels, and a thin accent bar on the left of the selected
/// row, sheets and the bottom bar.
enum Theme {
    nonisolated(unsafe) static var light = false

    typealias RGB = (r: Int, g: Int, b: Int)

    static var green: RGB { light ? (26, 127, 55) : (48, 209, 88) }
    static var red: RGB { light ? (200, 30, 30) : (255, 105, 97) }
    static var amber: RGB { light ? (168, 82, 0) : (255, 179, 64) }
    /// The accent: keys, the cursor, bars and buttons.
    static var accent: RGB { light ? (124, 88, 200) : (92, 156, 245) }
    static var blue: RGB { accent }
    /// Frames and quiet lines.
    static var line: RGB { light ? (196, 196, 200) : (72, 72, 76) }
    /// The empty part of a progress bar.
    static var track: RGB { light ? (226, 226, 230) : (48, 48, 52) }
    /// Sheets and the bottom bar.
    static var panel: RGB { light ? (243, 243, 243) : (30, 30, 30) }
    static var panelText: RGB { light ? (26, 26, 26) : (238, 238, 238) }
    /// The selected row.
    static var selection: RGB { light ? (234, 234, 236) : (42, 42, 44) }
    /// Text on the accent: white on purple, near-black on blue (both above 5:1).
    static var onAccent: RGB { light ? (255, 255, 255) : (12, 12, 12) }
    /// Text on red, for the delete button: white on light, near-black on dark (both above 5:1).
    static var onRed: RGB { light ? (255, 255, 255) : (12, 12, 12) }

    static func fg(_ c: RGB) -> String { "\u{1B}[38;2;\(c.r);\(c.g);\(c.b)m" }
    static func bg(_ c: RGB) -> String { "\u{1B}[48;2;\(c.r);\(c.g);\(c.b)m" }

    /// Works out whether the terminal is light or dark: PIXELGRAPH_THEME if
    /// set, else Settings → Theme, else ask the terminal for its background
    /// colour, else COLORFGBG.
    static func detect() {
        let env = ProcessInfo.processInfo.environment
        switch env["PIXELGRAPH_THEME"]?.lowercased() ?? Settings.load()[.theme] {
        case "light": light = true; return
        case "dark": light = false; return
        default: break
        }
        if let luminance = queryBackground() {
            light = luminance > 0.5
        } else if let colors = env["COLORFGBG"], let bgIndex = colors.split(separator: ";").last.flatMap({ Int($0) }) {
            light = bgIndex == 7 || bgIndex == 15
        }
    }

    /// Sends OSC 11 ("what's your background colour?") and reads the reply,
    /// e.g. `ESC ] 11 ; rgb:ffff/ffff/ffff BEL`. Nil if the terminal doesn't answer.
    private static func queryBackground() -> Double? {
        guard isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0 else { return nil }
        var original = termios()
        tcgetattr(STDIN_FILENO, &original)
        var raw = original
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON)
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        defer { tcsetattr(STDIN_FILENO, TCSAFLUSH, &original) }

        let query = "\u{1B}]11;?\u{1B}\\"
        _ = query.withCString { write(STDOUT_FILENO, $0, strlen($0)) }

        var reply = [UInt8]()
        let deadline = Date.now.addingTimeInterval(0.2)
        while Date.now < deadline {
            var fd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            guard poll(&fd, 1, 50) > 0 else { continue }
            var byte: UInt8 = 0
            guard read(STDIN_FILENO, &byte, 1) == 1 else { break }
            reply.append(byte)
            if byte == 0x07 || (byte == UInt8(ascii: "\\") && reply.dropLast().last == 0x1B) { break }
        }
        let text = String(decoding: reply, as: UTF8.self)
        guard let range = text.range(of: "rgb:") else { return nil }
        let parts = text[range.upperBound...].split(separator: "/").prefix(3).map {
            String($0.prefix { $0.isHexDigit })
        }
        guard parts.count == 3 else { return nil }
        let channels = parts.compactMap { part -> Double? in
            guard let value = Int(part, radix: 16), !part.isEmpty else { return nil }
            return Double(value) / Double((1 << (4 * part.count)) - 1)
        }
        guard channels.count == 3 else { return nil }
        return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
    }
}
