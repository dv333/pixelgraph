import Darwin
import Foundation

/// Colours that stay readable on both light and dark terminals. Dark
/// backgrounds get the bright system colours; light backgrounds get darker
/// ones, and selection is always white text on a solid blue bar (like a
/// selected row in Finder), at a contrast that passes WCAG AA either way.
enum Theme {
    nonisolated(unsafe) static var light = false

    typealias RGB = (r: Int, g: Int, b: Int)

    static var green: RGB { light ? (26, 127, 55) : (48, 209, 88) }
    static var red: RGB { light ? (200, 30, 30) : (255, 105, 97) }
    static var amber: RGB { light ? (168, 82, 0) : (255, 179, 64) }
    static var blue: RGB { light ? (0, 88, 208) : (100, 168, 255) }
    /// Frames and quiet lines.
    static var line: RGB { light ? (174, 174, 180) : (99, 99, 102) }
    /// The empty part of a progress bar.
    static var track: RGB { light ? (214, 214, 220) : (58, 58, 62) }
    /// Sheets drawn over the screen.
    static var panel: RGB { light ? (236, 236, 240) : (36, 36, 40) }
    static var panelText: RGB { light ? (29, 29, 31) : (235, 235, 240) }
    /// Selected rows and buttons: white on this blue is 5.6:1.
    static let accent: RGB = (0, 96, 223)

    static func fg(_ c: RGB) -> String { "\u{1B}[38;2;\(c.r);\(c.g);\(c.b)m" }
    static func bg(_ c: RGB) -> String { "\u{1B}[48;2;\(c.r);\(c.g);\(c.b)m" }

    /// Works out whether the terminal is light or dark: PIXELGRAPH_THEME if
    /// set, else ask the terminal for its background colour, else COLORFGBG.
    static func detect() {
        let env = ProcessInfo.processInfo.environment
        switch env["PIXELGRAPH_THEME"]?.lowercased() {
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
