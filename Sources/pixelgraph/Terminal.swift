import ArgumentParser
import CoreGraphics
import Darwin
import Foundation
import ImageIO

/// Raw-mode terminal: full-screen alternate buffer, keys and mouse clicks.
final class Terminal: @unchecked Sendable {
    enum Key: Equatable {
        case left, right, up, down, escape, enter, backspace, quit, resize
        case pageUp, pageDown, home, end, tab
        /// Mouse wheel: positive is down, in wheel ticks.
        case scroll(Int)
        case char(Character)
        /// 1-based screen position of a left click.
        case click(row: Int, col: Int)
        /// Where the mouse is while the left button is held down, to drag.
        case drag(row: Int, col: Int)
    }

    private var original = termios()
    private var lastSize = (cols: 0, rows: 0)

    /// A character cell's width ÷ height. iTerm2 reports its pixel size;
    /// otherwise assume the usual 1:2.
    var cellAspect: Double {
        var ws = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_xpixel > 0, ws.ws_ypixel > 0, ws.ws_col > 0, ws.ws_row > 0
        else { return 0.5 }
        return (Double(ws.ws_xpixel) / Double(ws.ws_col)) / (Double(ws.ws_ypixel) / Double(ws.ws_row))
    }

    /// The window's size in pixels, or zeros when the terminal doesn't say.
    var pixelSize: (width: Int, height: Int) {
        var ws = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 else { return (0, 0) }
        return (Int(ws.ws_xpixel), Int(ws.ws_ypixel))
    }

    /// True when a key was pressed; what's waiting is read and dropped.
    func keyWaiting() -> Bool {
        guard wait(0) else { return false }
        drainInput()
        return true
    }

    /// True when a key is waiting, which is left to be read.
    var keyPending: Bool { pending != nil || wait(0) }

    /// Drops any keys waiting to be read.
    func drainInput() {
        while wait(0), readByte() != nil {}
    }

    var size: (cols: Int, rows: Int) {
        var ws = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0 else { return (80, 24) }
        return (Int(ws.ws_col), Int(ws.ws_row))
    }

    func enter() {
        tcgetattr(STDIN_FILENO, &original)
        var raw = original
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON | ISIG | IEXTEN)
        raw.c_iflag &= ~tcflag_t(IXON | ICRNL)
        raw.c_cc.16 = 1  // VMIN
        raw.c_cc.17 = 0  // VTIME
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        lastSize = size
        // Alternate screen, hide cursor, report mouse clicks and drags (SGR encoding).
        write("\u{1B}[?1049h\u{1B}[?25l\u{1B}[?1000h\u{1B}[?1002h\u{1B}[?1006h")
    }

    /// Lets ctrl-c stop the program (during a scan) or arrive as a key (the rest of the time).
    func allowInterrupt(_ allowed: Bool) {
        var current = termios()
        tcgetattr(STDIN_FILENO, &current)
        if allowed { current.c_lflag |= tcflag_t(ISIG) } else { current.c_lflag &= ~tcflag_t(ISIG) }
        tcsetattr(STDIN_FILENO, TCSANOW, &current)
    }

    func leave() {
        write("\u{1B}[?1000l\u{1B}[?1002l\u{1B}[?1006l\u{1B}[0m\u{1B}[?25h\u{1B}[?1049l")
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
    }

    func write(_ text: String) {
        var data = Data(text.utf8)
        data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(STDOUT_FILENO, buffer.baseAddress! + offset, buffer.count - offset)
                if n <= 0 { break }
                offset += n
            }
        }
    }

    private var pending: Key?

    /// The last letter as typed, capitals kept: keys arrive lower-case, but
    /// text being typed (a folder path, a model name) needs what was typed.
    private(set) var typed: Character?

    /// Where the mouse was at its last click, drag or wheel movement
    /// (1-based), so zooming can keep the spot under it where it is.
    private(set) var pointer: (row: Int, col: Int)?

    /// Blocks until a key, click, wheel movement or window resize. Wheel
    /// events that are already waiting are folded into one, so a trackpad
    /// flick can't queue up scrolling that carries on after it stops; drag
    /// events likewise come down to where the mouse is now.
    func nextKey() -> Key {
        folded(first(), dragWait: 10, scrollWait: 15)
    }

    /// For a screen that follows the fingers (zooming, dragging a photo).
    /// Only the wheel and drag events that have already arrived are folded,
    /// so each frame catches up with the gesture instead of waiting for it
    /// to pause; and with `milliseconds`, nil comes back when nothing has
    /// happened for that long: the fingers are at rest.
    func nextKey(live milliseconds: Int32?) -> Key? {
        if let milliseconds, pending == nil, size == lastSize, !wait(milliseconds) { return nil }
        return folded(first(), dragWait: 0, scrollWait: 0)
    }

    private func first() -> Key {
        guard let waiting = pending else { return readKey() }
        pending = nil
        return waiting
    }

    private func folded(_ key: Key, dragWait: Int32, scrollWait: Int32) -> Key {
        if case .drag = key {
            var latest = key
            while wait(dragWait) {
                let next = readKey()
                guard case .drag = next else { pending = next; break }
                latest = next
            }
            return latest
        }
        guard case .scroll(var ticks) = key else { return key }
        while wait(scrollWait) {
            let next = readKey()
            if case .scroll(let more) = next {
                ticks += more
            } else {
                pending = next
                break
            }
        }
        return .scroll(ticks)
    }

    private func readKey() -> Key {
        while true {
            if size != lastSize {
                lastSize = size
                return .resize
            }
            guard wait(200), let byte = readByte() else { continue }
            switch byte {
            case 0x1B:
                if let key = escapeSequence() { return key }
            case 0x03, 0x04: return .quit  // Ctrl-C, Ctrl-D
            case 0x0D, 0x0A: return .enter
            case 0x09: return .tab
            case 0x7F, 0x08: return .backspace
            // Letters arrive lower-case, so Caps Lock never changes what a key does.
            case 0x41...0x5A:
                typed = Character(UnicodeScalar(byte))
                return .char(Character(UnicodeScalar(byte + 32)))
            case 0x20...0x7E:
                typed = Character(UnicodeScalar(byte))
                return .char(Character(UnicodeScalar(byte)))
            default: continue
            }
        }
    }

    private func escapeSequence() -> Key? {
        guard wait(30), let next = readByte() else { return .escape }
        guard next == UInt8(ascii: "[") || next == UInt8(ascii: "O") else { return .escape }
        var params: [UInt8] = []
        while wait(30), let byte = readByte() {
            guard !(0x40...0x7E).contains(byte) else { return csi(params, final: byte) }
            params.append(byte)
        }
        return .escape
    }

    private func csi(_ params: [UInt8], final: UInt8) -> Key? {
        if params.first == UInt8(ascii: "<") {
            // Mouse: ESC [ < button ; col ; row M (press) or m (release)
            let parts = String(decoding: params.dropFirst(), as: UTF8.self).split(separator: ";").compactMap { Int($0) }
            guard final == UInt8(ascii: "M"), parts.count == 3 else { return nil }
            pointer = (parts[2], parts[1])
            switch parts[0] {
            case 0: return .click(row: parts[2], col: parts[1])
            case 32: return .drag(row: parts[2], col: parts[1])
            case 64: return .scroll(-1)
            case 65: return .scroll(1)
            default: return nil
            }
        }
        switch final {
        case UInt8(ascii: "~"):
            switch String(decoding: params, as: UTF8.self) {
            case "5": return .pageUp
            case "6": return .pageDown
            case "1", "7": return .home
            case "4", "8": return .end
            default: return nil
            }
        case UInt8(ascii: "C"): return .right
        case UInt8(ascii: "D"): return .left
        case UInt8(ascii: "A"): return .up
        case UInt8(ascii: "B"): return .down
        case UInt8(ascii: "H"): return .home
        case UInt8(ascii: "F"): return .end
        default: return nil
        }
    }

    private func wait(_ milliseconds: Int32) -> Bool {
        var fd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        return poll(&fd, 1, milliseconds) > 0
    }

    private func readByte() -> UInt8? {
        var byte: UInt8 = 0
        return read(STDIN_FILENO, &byte, 1) == 1 ? byte : nil
    }
}

/// Draws photos into terminal cells.
enum TerminalImage {
    /// How a terminal shows real images: iTerm2's way (iTerm2, WezTerm) or
    /// kitty's (kitty, Ghostty).
    enum Graphics: Sendable { case iTerm, kitty }

    enum Mode: String, CaseIterable, ExpressibleByArgument {
        case auto, iterm, kitty, blocks

        /// How photos are shown here; nil for colour blocks, which any
        /// true-colour terminal can show.
        var resolved: Graphics? {
            switch self {
            case .iterm: return .iTerm
            case .kitty: return .kitty
            case .blocks: return nil
            case .auto:
                let env = ProcessInfo.processInfo.environment
                if env["LC_TERMINAL"] == "iTerm2" || env["TERM_PROGRAM"] == "iTerm.app" || env["TERM_PROGRAM"] == "WezTerm" {
                    return .iTerm
                }
                // Inside tmux or screen, kitty's images don't get through.
                guard env["TMUX"] == nil, env["STY"] == nil else { return nil }
                if env["TERM"] == "xterm-kitty" || env["KITTY_WINDOW_ID"] != nil || env["TERM_PROGRAM"] == "ghostty" { return .kitty }
                return nil
            }
        }
    }

    /// The same picture, muted: how photos selected to move look. Mostly
    /// grey and a little darker, so it reads as "going" while staying clear
    /// enough to judge, since these are the photos you're deciding about.
    static func darkened(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.draw(image, in: rect)
        context.setBlendMode(.saturation)
        context.setFillColor(CGColor(gray: 0.5, alpha: 0.75))
        context.fill(rect)
        context.setBlendMode(.normal)
        context.setFillColor(CGColor(gray: 0, alpha: 0.25))
        context.fill(rect)
        return context.makeImage()
    }

    /// iTerm2 inline image placed at a cell, scaled to fit `cols` × `rows`;
    /// with `stretch`, to cover them exactly (for a picture made that shape).
    static func iTerm(_ data: Data, row: Int, col: Int, cols: Int, rows: Int, stretch: Bool = false) -> String {
        "\u{1B}[\(row);\(col)H\u{1B}]1337;File=inline=1;width=\(cols);height=\(rows);preserveAspectRatio=\(stretch ? 0 : 1);size=\(data.count):\(data.base64EncodedString())\u{07}"
    }

    /// A kitty graphics image (PNG) placed at a cell and scaled to `cols` ×
    /// `rows`. `id` stands for the spot on screen: whatever was drawn there
    /// before is deleted first. It sits under text that has a background, so
    /// sheets cover it, and never moves the cursor or answers back.
    static func kitty(_ png: Data, id: Int, row: Int, col: Int, cols: Int, rows: Int) -> String {
        var out = "\u{1B}_Ga=d,d=I,i=\(id),q=2\u{1B}\\\u{1B}[\(row);\(col)H"
        var rest = Substring(png.base64EncodedString()), first = true
        repeat {
            let chunk = rest.prefix(4096)
            rest = rest.dropFirst(4096)
            let more = rest.isEmpty ? 0 : 1
            let keys = first ? "a=T,f=100,i=\(id),q=2,C=1,c=\(cols),r=\(rows),z=-1073741825,m=\(more)" : "m=\(more)"
            out += "\u{1B}_G\(keys);\(chunk)\u{1B}\\"
            first = false
        } while !rest.isEmpty
        return out
    }

    /// Deletes every kitty image, for when the screen is cleared.
    static let kittyClear = "\u{1B}_Ga=d,d=A,q=2\u{1B}\\"

    /// A PNG, for kitty's protocol, which doesn't take JPEG.
    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// The same picture with its long side `maxSide`: smaller, or, with
    /// `enlarge`, bigger too, smoothly (a terminal stretching a small
    /// picture itself shows blocks).
    static func scaled(_ image: CGImage, maxSide: Int, enlarge: Bool = false) -> CGImage? {
        let ratio = Double(maxSide) / Double(max(image.width, image.height))
        let scale = enlarge ? ratio : min(1, ratio)
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }

    /// The part of `image` inside `rect` (0 … 1, top-left origin).
    static func crop(_ image: CGImage, to rect: CGRect) -> CGImage? {
        let w = Double(image.width), h = Double(image.height)
        return image.cropping(to: CGRect(x: rect.minX * w, y: rect.minY * h, width: rect.width * w, height: rect.height * h).integral)
    }

    /// Colour blocks: each cell shows two pixels with "▀" (top in the
    /// foreground colour, bottom in the background colour). Letterboxed
    /// cells keep the terminal's own background.
    /// `dim` mutes the picture the same way, for photos selected to move.
    static func blocks(_ image: CGImage, cols: Int, rows: Int, dim: Bool = false) -> [String] {
        let w = max(1, cols), h = max(2, rows * 2)
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let scale = min(Double(w) / Double(image.width), Double(h) / Double(image.height))
        let size = CGSize(width: Double(image.width) * scale, height: Double(image.height) * scale)
        let rect = CGRect(x: (Double(w) - size.width) / 2, y: (Double(h) - size.height) / 2,
                          width: size.width, height: size.height).integral
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.interpolationQuality = .high
            context.draw(image, in: rect)
        }

        func color(_ x: Int, _ y: Int) -> (Int, Int, Int)? {
            let i = (y * w + x) * 4
            guard pixels[i + 3] >= 128 else { return nil }
            let (r, g, b) = (Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2]))
            guard dim else { return (Int(r), Int(g), Int(b)) }
            // A quarter of the colour left, three quarters darker.
            let grey = 0.2126 * r + 0.7152 * g + 0.0722 * b
            func muted(_ c: Double) -> Int { Int((grey + (c - grey) * 0.25) * 0.75) }
            return (muted(r), muted(g), muted(b))
        }

        var lines: [String] = []
        for row in 0..<rows {
            var line = ""
            var fg: (Int, Int, Int)?, bg: (Int, Int, Int)?, bgDefault = true
            func setFG(_ c: (Int, Int, Int)) {
                if fg == nil || fg! != c { line += "\u{1B}[38;2;\(c.0);\(c.1);\(c.2)m"; fg = c }
            }
            func setBG(_ c: (Int, Int, Int)?) {
                if let c {
                    if bgDefault || bg! != c { line += "\u{1B}[48;2;\(c.0);\(c.1);\(c.2)m"; bg = c; bgDefault = false }
                } else if !bgDefault {
                    line += "\u{1B}[49m"; bgDefault = true; bg = nil
                }
            }
            for x in 0..<w {
                switch (color(x, row * 2), color(x, row * 2 + 1)) {
                case (nil, nil): setBG(nil); line += " "
                case let (top?, nil): setBG(nil); setFG(top); line += "▀"
                case let (nil, bottom?): setBG(nil); setFG(bottom); line += "▄"
                case let (top?, bottom?): setBG(bottom); setFG(top); line += "▀"
                }
            }
            lines.append(line + "\u{1B}[0m")
        }
        return lines
    }

    /// A small JPEG for iTerm2 so redrawing a screen of thumbnails stays quick.
    static func jpeg(_ image: CGImage, quality: Double = 0.9) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// A tile of a grid of photos: `image` cropped to fill a picture `width`
    /// × `height` pixels, as Photos' grid does, with `inset` pixels of
    /// `background` (or nothing) around it for the gap between tiles, and a
    /// border in `outline` when it's the one selected.
    static func tile(_ image: CGImage, width: Int, height: Int, inset: Int,
                     background: (r: Int, g: Int, b: Int)?, outline: (r: Int, g: Int, b: Int)?) -> CGImage? {
        func color(_ c: (r: Int, g: Int, b: Int)) -> CGColor {
            CGColor(srgbRed: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255, alpha: 1)
        }
        let alpha = background == nil ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: alpha.rawValue)
        else { return nil }
        if let background {
            context.setFillColor(color(background))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        let inner = CGRect(x: inset, y: inset, width: max(1, width - 2 * inset), height: max(1, height - 2 * inset))
        let scale = max(inner.width / Double(image.width), inner.height / Double(image.height))
        let w = Double(image.width) * scale, h = Double(image.height) * scale
        context.saveGState()
        context.clip(to: inner)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: inner.midX - w / 2, y: inner.midY - h / 2, width: w, height: h))
        context.restoreGState()
        if let outline {
            let line = Double(max(2, inset * 2))
            context.setStrokeColor(color(outline))
            context.setLineWidth(line)
            context.stroke(inner.insetBy(dx: line / 2, dy: line / 2))
        }
        return context.makeImage()
    }

    /// A new picture `width` × `height` pixels with the part of `image`
    /// inside `crop` (0 … 1, top-left origin) drawn into `rect` of it. The
    /// rest is `background`, or see-through without one. `quick` gives up
    /// some sharpness for speed, for frames that only last a moment.
    static func canvas(_ image: CGImage, crop: CGRect, into rect: CGRect, width: Int, height: Int,
                       background: (r: Int, g: Int, b: Int)?, quick: Bool) -> CGImage? {
        let alpha = background == nil ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast
        guard let cut = self.crop(image, to: crop),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: alpha.rawValue)
        else { return nil }
        if let background {
            context.setFillColor(CGColor(srgbRed: Double(background.r) / 255, green: Double(background.g) / 255,
                                         blue: Double(background.b) / 255, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        context.interpolationQuality = quick ? .medium : .high
        // Core Graphics counts rows from the bottom.
        context.draw(cut, in: CGRect(x: rect.minX, y: Double(height) - rect.maxY, width: rect.width, height: rect.height))
        return context.makeImage()
    }

    static func load(_ url: URL, maxSide: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
    }
}
