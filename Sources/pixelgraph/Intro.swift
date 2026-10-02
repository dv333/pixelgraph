import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// The opening title, "rack focus": a field of out-of-focus lights; the lens
/// pulls focus, overshoots a touch and settles, and the nearest lights turn
/// out to be the name while the ones behind stay soft.
///
/// Drawn as real pixels in terminals that can show images (iTerm2's inline
/// images; the kitty graphics protocol in kitty, Ghostty and WezTerm) and
/// skipped everywhere else. Any key skips it; `--no-intro` or
/// PIXELGRAPH_NO_INTRO=1 turns it off.
enum Intro {
    enum Graphics { case iTerm, kitty }

    /// How this terminal can show the intro, or nil when it can't (or shouldn't).
    static var graphics: Graphics? {
        let env = ProcessInfo.processInfo.environment
        if let off = env["PIXELGRAPH_NO_INTRO"], !off.isEmpty, off != "0" { return nil }
        // Inside tmux or screen, image escapes don't reach the terminal intact.
        if env["TMUX"] != nil || env["STY"] != nil { return nil }
        if env["LC_TERMINAL"] == "iTerm2" || env["TERM_PROGRAM"] == "iTerm.app" { return .iTerm }
        if env["TERM"] == "xterm-kitty" || env["KITTY_WINDOW_ID"] != nil
            || env["TERM_PROGRAM"] == "ghostty" || env["TERM_PROGRAM"] == "WezTerm" { return .kitty }
        return nil
    }

    /// Plays once over the whole screen, then clears it.
    static func play(on term: Terminal) async {
        guard let graphics else { return }
        let (cols, rows) = term.size
        guard cols >= 40, rows >= 12 else { return }
        // The last row stays free so a full-height image can't scroll the screen.
        let used = rows - 1
        let pixels = term.pixelSize
        var width = pixels.width > 0 ? pixels.width : cols * 9
        var height = pixels.height > 0 ? pixels.height * used / rows : used * 18
        // Big enough to look sharp, small enough to send 24 times a second.
        let widest = graphics == .iTerm ? 1280.0 : 900.0
        let scale = min(1, widest / Double(width))
        width = max(320, Int(Double(width) * scale))
        height = max(120, Int(Double(height) * scale))
        guard let scene = RackFocus(width: width, height: height, typeface: Settings.load().typeface) else { return }

        term.write("\u{1B}[2J")
        let start = Date.now, fps = 24.0
        var frame = 0
        while true {
            let t = Date.now.timeIntervalSince(start)
            if t >= RackFocus.duration || term.keyWaiting() { break }
            guard let image = scene.frame(at: t), let data = encode(image, graphics) else { break }
            term.write(show(data, graphics, cols: cols, rows: used))
            frame += 1
            let wait = Double(frame) / fps - Date.now.timeIntervalSince(start)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        }
        term.drainInput()
        if graphics == .kitty { term.write("\u{1B}_Ga=d,d=A,q=2\u{1B}\\") }
        term.write("\u{1B}[0m\u{1B}[2J")
    }

    /// The title as it looks once it has settled, for the preview in Settings.
    static func still(width: Int, height: Int, typeface: Typeface) -> CGImage? {
        RackFocus(width: width, height: height, typeface: typeface)?.frame(at: 2.3)
    }

    private static func encode(_ image: CGImage, _ graphics: Graphics) -> Data? {
        let data = NSMutableData()
        // iTerm2 takes JPEG, a fraction of the size; kitty's protocol takes PNG.
        let type = (graphics == .iTerm ? "public.jpeg" : "public.png") as CFString
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else { return nil }
        let options = graphics == .iTerm ? [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary : nil
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// One frame covering `cols` × `rows` from the top-left, drawn in one
    /// synchronized update so it doesn't tear.
    private static func show(_ data: Data, _ graphics: Graphics, cols: Int, rows: Int) -> String {
        let payload = data.base64EncodedString()
        var out = "\u{1B}[?2026h\u{1B}[H"
        switch graphics {
        case .iTerm:
            out += "\u{1B}]1337;File=inline=1;width=\(cols);height=\(rows);preserveAspectRatio=0;doNotMoveCursor=1;"
                + "size=\(data.count):\(payload)\u{07}"
        case .kitty:
            // Sent in 4 KB chunks; the same id replaces the previous frame.
            var chunks: [Substring] = []
            var rest = Substring(payload)
            while !rest.isEmpty { chunks.append(rest.prefix(4096)); rest = rest.dropFirst(4096) }
            for (i, chunk) in chunks.enumerated() {
                let more = i < chunks.count - 1 ? 1 : 0
                let keys = i == 0 ? "a=T,f=100,i=7,q=2,C=1,c=\(cols),r=\(rows),m=\(more)" : "m=\(more)"
                out += "\u{1B}_G\(keys);\(chunk)\u{1B}\\"
            }
        }
        return out + "\u{1B}[?2026l"
    }
}

/// The rack-focus frames, drawn with Core Graphics. The lights are drawn at
/// half resolution (they're soft anyway, and it keeps the frame rate up);
/// the sharp name and tagline at full resolution.
private final class RackFocus {
    static let duration = 2.9

    private let width: Int, height: Int
    private let main: CGContext
    private let bokeh: CGContext
    private let word: CGImage
    private let glow: CGImage
    private let tagline: CGImage
    private let vignette: CGImage
    private let sprites: [CGImage]
    private let round: CGImage
    private var dots: [(x: Double, y: Double, depth: Double)] = []
    private var lights: [(x: Double, y: Double, base: Double, speed: Double, phase: Double, depth: Double, sprite: Int)] = []
    private let dotRadius: Double
    /// How far out of focus something gets per unit of depth.
    private let blur: Double

    typealias Colour = (Double, Double, Double)

    /// The colours, following the theme like OpenCode: blue lights on near-black
    /// for dark terminals, purple lights on off-white for light ones.
    private struct Look {
        /// The lights: mostly the accent (0), a lighter (1) and a deeper (2)
        /// shade, a few pale ones (3); 4 is the lights that become the name.
        let palette: [Colour]
        let backdrop: Colour
        let name: Colour
        let glow: Colour
        let tagline: Colour
        /// Lights add up on dark, and tint on light.
        let blend: CGBlendMode
        /// The edges fade toward black on dark and white on light.
        let edge: Double

        static let dark = Look(
            palette: [(0.36, 0.61, 0.96), (0.62, 0.78, 1), (0.22, 0.38, 0.88), (0.92, 0.94, 1), (0.72, 0.84, 1)],
            backdrop: (0.035, 0.035, 0.04), name: (0.96, 0.97, 1), glow: (0.36, 0.61, 0.96),
            tagline: (0.85, 0.86, 0.9), blend: .plusLighter, edge: 0)
        static let light = Look(
            palette: [(0.49, 0.35, 0.78), (0.70, 0.58, 0.92), (0.34, 0.20, 0.62), (0.80, 0.78, 0.86), (0.42, 0.28, 0.72)],
            backdrop: (0.98, 0.98, 0.98), name: (0.1, 0.1, 0.12), glow: (0.49, 0.35, 0.78),
            tagline: (0.3, 0.3, 0.34), blend: .multiply, edge: 1)
    }

    private let look: Look

    private static func cg(_ c: Colour, _ alpha: Double = 1) -> CGColor {
        CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: alpha)
    }

    init?(width: Int, height: Int, typeface: Typeface) {
        self.width = width
        self.height = height
        guard let main = Self.makeContext(width, height), let bokeh = Self.makeContext(width / 2, height / 2) else { return nil }
        self.main = main
        self.bokeh = bokeh
        let W = Double(width), H = Double(height)
        let size = min(W * 0.1, H * 0.3)

        let look = Theme.light ? Look.light : Look.dark
        self.look = look
        guard let word = Self.text("pixelgraph", typeface: typeface, width: width, height: height, size: size, weight: .light,
                                   color: Self.cg(look.name), y: H / 2),
              let tinted = Self.text("pixelgraph", typeface: typeface, width: width, height: height, size: size, weight: .light,
                                     color: Self.cg(look.glow), y: H / 2),
              let glow = Self.soften(tinted, 0.07),
              let tagline = Self.text("EVERY MOMENT, ONCE", typeface: typeface, width: width, height: height, size: max(10, W * 0.0105),
                                      weight: .regular, color: Self.cg(look.tagline, 0.8),
                                      y: H * 0.2, tracking: 0.32),
              let vignette = Self.vignette(width, height, edge: look.edge),
              let round = Self.roundSprite(look.palette[4])
        else { return nil }
        self.word = word
        self.glow = glow
        self.tagline = tagline
        self.vignette = vignette
        self.round = round
        sprites = look.palette.compactMap(Self.hexagon)
        guard sprites.count == look.palette.count else { return nil }

        // The lights that become the name: a grid sampled from it, set in heavier type so strokes aren't missed.
        let step = max(3.2, size / 15)
        dotRadius = step * 0.42
        blur = H * 0.085
        var random = SplitMix(seed: 17)
        for (x, y) in Self.sample("pixelgraph", typeface: typeface, width: width, height: height, size: size, step: step) {
            dots.append((x + (random.next() - 0.5) * step * 0.3, y + (random.next() - 0.5) * step * 0.3,
                         0.5 + (random.next() - 0.5) * 0.05))
        }
        // The lights behind: mostly the accent, some lighter, deeper and pale.
        let scale = W / 1100
        let choices = [0, 0, 0, 1, 2, 3]
        for _ in 0..<70 {
            lights.append((x: random.next() * W * 1.2 - W * 0.1, y: H * (0.12 + random.next() * 0.76),
                           base: (1.6 + random.next() * 2.4) * scale, speed: (random.next() - 0.5) * W * 0.012,
                           phase: random.next() * 6, depth: 0.95 + random.next() * 0.35,
                           sprite: choices[Int(random.next() * Double(choices.count)) % choices.count]))
        }
    }

    func frame(at t: Double) -> CGImage? {
        let W = Double(width), H = Double(height)
        let focus: Double
        if t < 0.15 { focus = -0.7 }
        else if t < 1.3 { focus = lerp(-0.7, 0.57, easeInOut((t - 0.15) / 1.15)) }
        else { focus = lerp(0.57, 0.5, easeOut(clamp((t - 1.3) / 0.3))) }
        let settled = clamp((focus + 0.7) / 1.2)
        let fadeIn = smooth(clamp(t / 0.35))
        let crisp = smooth(clamp((t - 1.45) / 0.4))

        // Lights, at half resolution, with a little focus breathing.
        bokeh.setBlendMode(.normal)
        bokeh.setAlpha(1)
        bokeh.setFillColor(Self.cg(look.backdrop))
        bokeh.fill(CGRect(x: 0, y: 0, width: W / 2, height: H / 2))
        bokeh.saveGState()
        let breathe = 1 + 0.045 * (1 - settled)
        bokeh.scaleBy(x: 0.5, y: 0.5)
        bokeh.translateBy(x: W / 2, y: H / 2)
        bokeh.scaleBy(x: breathe, y: breathe)
        bokeh.translateBy(x: -W / 2, y: -H / 2)
        bokeh.setBlendMode(look.blend)
        for light in lights {
            let r = light.base + blur * abs(light.depth - focus) * 1.3
            let alpha = clamp(pow(light.base / r, 2) * 9, 0.03, 0.9) * fadeIn * (0.85 + 0.15 * sin(t * 2 + light.phase))
            bokeh.setAlpha(alpha)
            let x = light.x + light.speed * t
            bokeh.draw(r < 3 ? round : sprites[light.sprite], in: CGRect(x: x - r * 1.19, y: light.y - r * 1.19, width: r * 2.38, height: r * 2.38))
        }
        for dot in dots {
            let spread = blur * 1.7 * abs(dot.depth - focus), r = dotRadius + spread
            let alpha = clamp(pow(dotRadius / r, 2) * 2.4, 0.012, 1) * fadeIn * (1 - 0.75 * crisp)
            guard alpha >= 0.005 else { continue }
            bokeh.setAlpha(alpha)
            if spread < 1.5 {
                bokeh.draw(round, in: CGRect(x: dot.x - r * 1.6, y: dot.y - r * 1.6, width: r * 3.2, height: r * 3.2))
            } else {
                bokeh.draw(sprites[4], in: CGRect(x: dot.x - r * 1.19, y: dot.y - r * 1.19, width: r * 2.38, height: r * 2.38))
            }
        }
        bokeh.restoreGState()

        // Full resolution: the lights scaled up, then the sharp name, tagline and vignette.
        let full = CGRect(x: 0, y: 0, width: W, height: H)
        main.setBlendMode(.normal)
        main.setAlpha(1)
        main.interpolationQuality = .high
        if let lights = bokeh.makeImage() { main.draw(lights, in: full) }
        if crisp > 0 {
            main.setBlendMode(look.blend)
            main.setAlpha(0.55 * crisp)
            main.draw(glow, in: full)
            main.setBlendMode(.normal)
            main.setAlpha(crisp)
            main.draw(word, in: full)
        }
        let words = smooth(clamp((t - 1.8) / 0.4))
        if words > 0 {
            main.setAlpha(words)
            main.draw(tagline, in: full)
        }
        main.setAlpha(1)
        main.draw(vignette, in: full)
        let out = clamp((t - (Self.duration - 0.3)) / 0.3)
        if out > 0 {
            main.setFillColor(Self.cg(look.backdrop, out))
            main.fill(full)
        }
        return main.makeImage()
    }

    // MARK: - Pieces

    private static func makeContext(_ width: Int, _ height: Int) -> CGContext? {
        CGContext(data: nil, width: max(1, width), height: max(1, height), bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private static func textLine(_ string: String, typeface: Typeface, size: Double, weight: NSFont.Weight, color: CGColor,
                                 tracking: Double) -> CTLine {
        let font = typeface.font(size: size, weight: weight)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTKernAttributeName as String): size * tracking,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
    }

    /// Draws `string` centred on the vertical position `y` (from the bottom).
    private static func draw(_ string: String, typeface: Typeface, in context: CGContext, width: Int, size: Double,
                             weight: NSFont.Weight, color: CGColor, y: Double, tracking: Double) {
        let ctLine = textLine(string, typeface: typeface, size: size, weight: weight, color: color, tracking: tracking)
        let bounds = CTLineGetImageBounds(ctLine, context)
        context.textPosition = CGPoint(x: (Double(width) - bounds.width) / 2 - bounds.minX, y: y - bounds.height / 2 - bounds.minY)
        CTLineDraw(ctLine, context)
    }

    private static func text(_ string: String, typeface: Typeface, width: Int, height: Int, size: Double, weight: NSFont.Weight,
                             color: CGColor, y: Double, tracking: Double = 0.05) -> CGImage? {
        guard let context = makeContext(width, height) else { return nil }
        draw(string, typeface: typeface, in: context, width: width, size: size, weight: weight, color: color, y: y, tracking: tracking)
        return context.makeImage()
    }

    /// Points on a grid that fall on the letters, bottom-left origin.
    private static func sample(_ string: String, typeface: Typeface, width: Int, height: Int, size: Double,
                               step: Double) -> [(Double, Double)] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            draw(string, typeface: typeface, in: context, width: width, size: size, weight: .medium, color: CGColor(gray: 1, alpha: 1),
                 y: Double(height) / 2, tracking: 0.05)
            return true
        }
        guard drawn else { return [] }
        var points: [(Double, Double)] = []
        // Memory rows run top to bottom; drawing coordinates bottom to top.
        for y in stride(from: Double(height) / 2 - size, to: Double(height) / 2 + size, by: step) {
            for x in stride(from: 0, to: Double(width), by: step) {
                let row = height - 1 - Int(y), col = Int(x)
                guard row >= 0, row < height, col < width else { continue }
                if pixels[(row * width + col) * 4 + 3] > 110 { points.append((x, y)) }
            }
        }
        return points
    }

    /// A soft hexagonal disc of light: a seven-blade aperture's bokeh, with a brighter rim.
    private static func hexagon(_ c: (Double, Double, Double)) -> CGImage? {
        let side = 128
        guard let context = makeContext(side, side) else { return nil }
        let centre = Double(side) / 2, radius = Double(side) * 0.42
        func hex(_ r: Double) -> CGPath {
            let path = CGMutablePath()
            for i in 0..<6 {
                let a = Double.pi / 3 * Double(i) + 0.18
                let point = CGPoint(x: centre + cos(a) * r, y: centre + sin(a) * r)
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
            return path
        }
        let color = { (a: Double) in CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: a) }
        for i in 0..<6 {
            context.addPath(hex(radius + Double(3 - i) * 1.4))
            context.setFillColor(color(0.06))
            context.fillPath()
        }
        context.addPath(hex(radius))
        context.setFillColor(color(0.3))
        context.fillPath()
        context.addPath(hex(radius - 2.5))
        context.setStrokeColor(color(0.5))
        context.setLineWidth(4)
        context.strokePath()
        return context.makeImage().flatMap { soften($0, 0.5) }
    }

    /// A small round point of light, for lights in focus.
    private static func roundSprite(_ c: (Double, Double, Double)) -> CGImage? {
        let side = 64
        guard let context = makeContext(side, side),
              let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [
                  CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1),
                  CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 0.55),
                  CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 0),
              ] as CFArray, locations: [0, 0.35, 1])
        else { return nil }
        let centre = CGPoint(x: Double(side) / 2, y: Double(side) / 2)
        context.drawRadialGradient(gradient, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: Double(side) / 2, options: [])
        return context.makeImage()
    }

    private static func vignette(_ width: Int, _ height: Int, edge: Double) -> CGImage? {
        guard let context = makeContext(width, height),
              let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        colors: [CGColor(gray: edge, alpha: 0), CGColor(gray: edge, alpha: 0.5)] as CFArray,
                                        locations: [0, 1])
        else { return nil }
        let centre = CGPoint(x: Double(width) / 2, y: Double(height) / 2)
        context.drawRadialGradient(gradient, startCenter: centre, startRadius: Double(height) * 0.35, endCenter: centre,
                                   endRadius: Double(width) * 0.72, options: [.drawsAfterEndLocation])
        return context.makeImage()
    }

    /// A cheap, smooth blur: shrink, then scale back up.
    private static func soften(_ image: CGImage, _ factor: Double) -> CGImage? {
        let w = max(1, Int(Double(image.width) * factor)), h = max(1, Int(Double(image.height) * factor))
        guard let small = makeContext(w, h), let big = makeContext(image.width, image.height) else { return nil }
        small.interpolationQuality = .high
        small.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let shrunk = small.makeImage() else { return nil }
        big.interpolationQuality = .high
        big.draw(shrunk, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return big.makeImage()
    }
}

private func clamp(_ v: Double, _ low: Double = 0, _ high: Double = 1) -> Double { max(low, min(high, v)) }
private func lerp(_ a: Double, _ b: Double, _ k: Double) -> Double { a + (b - a) * k }
private func smooth(_ k: Double) -> Double { k * k * (3 - 2 * k) }
private func easeOut(_ k: Double) -> Double { 1 - pow(1 - k, 3) }
private func easeInOut(_ k: Double) -> Double { k < 0.5 ? 4 * k * k * k : 1 - pow(-2 * k + 2, 3) / 2 }

/// A small seeded generator, so the lights fall the same way every time.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
}
