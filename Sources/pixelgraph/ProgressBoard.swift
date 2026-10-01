import Darwin
import Foundation

/// The scan's live checklist: one line per stage with a smooth bar for the
/// stage in progress, time left, and a running summary of what's been found.
/// Falls back to plain lines when output isn't a terminal.
final class ProgressBoard: @unchecked Sendable {
    enum State { case waiting, running, done, skipped }

    struct Stage {
        var title: String
        var state = State.waiting
        var done = 0
        var total = 0
        var detail = ""
        var started: Date?
        var elapsed: TimeInterval = 0
    }

    private let lock = NSLock()
    private var heading: String
    private var stages: [Stage]
    private var summary = ""
    private var drawnLines = 0
    private var finished = false
    private var lastDraw = Date.distantPast
    private let live: Bool
    /// Prints nothing at all: for the MCP server, whose output is the protocol.
    private let quiet: Bool
    /// Full-screen mode draws from the top of the screen instead of in place.
    private let fullScreen: Bool

    init(heading: String, stages: [String], fullScreen: Bool = false, quiet: Bool = false) {
        self.heading = heading
        self.stages = stages.map { Stage(title: $0) }
        self.fullScreen = fullScreen
        self.quiet = quiet
        live = !quiet && isatty(STDOUT_FILENO) != 0
    }

    func begin() {
        guard live else { if !quiet { print(heading) }; return }
        if !fullScreen { Theme.detect() }
        if !fullScreen { write("\u{1B}[?25l") }
        draw(force: true)
    }

    func start(_ i: Int, total: Int = 0, detail: String = "") {
        update {
            stages[i].state = .running
            stages[i].total = total
            stages[i].detail = detail
            stages[i].started = .now
        }
    }

    func advance(_ i: Int, done: Int, detail: String? = nil) {
        update {
            stages[i].done = done
            if let detail { stages[i].detail = detail }
        }
    }

    func finish(_ i: Int, detail: String) {
        update {
            stages[i].state = .done
            stages[i].detail = detail
            stages[i].done = stages[i].total
            stages[i].elapsed = stages[i].started.map { Date.now.timeIntervalSince($0) } ?? -1
        }
        if !live && !quiet { print("✓ \(stages[i].title): \(detail)") }
    }

    func skip(_ i: Int, detail: String) {
        update {
            stages[i].state = .skipped
            stages[i].detail = detail
        }
    }

    func setSummary(_ text: String) { update { summary = text } }

    /// Leaves the finished board on screen.
    func end() {
        guard live else { return }
        lock.lock()
        finished = true
        lock.unlock()
        draw(force: true)
        if !fullScreen { write("\u{1B}[?25h") }
    }

    /// Puts the cursor back if the scan is stopped half way.
    func abandon() {
        guard live else { return }
        write("\u{1B}[0m\n\u{1B}[?25h")
    }

    private func update(_ change: () -> Void) {
        lock.lock()
        change()
        lock.unlock()
        draw(force: false)
    }

    // MARK: - Drawing

    private func draw(force: Bool) {
        guard live else { return }
        lock.lock()
        defer { lock.unlock() }
        guard force || Date.now.timeIntervalSince(lastDraw) > 0.05 else { return }
        lastDraw = .now

        let (width, height) = terminalSize()
        var lines = ["", "  " + bold(heading), ""]
        for stage in stages { lines.append(line(stage, width: min(width, 110))) }
        lines.append("")
        lines.append("  " + (summary.isEmpty ? "" : dim(finished ? "Found: " : "So far: ") + summary))
        lines.append(finished ? "" : "  " + dim("ctrl-c to stop · progress is saved, run again to resume"))

        var out: String
        if fullScreen {
            // Full screen: the block sits in the middle, a third of the way
            // down, its lines still left-aligned so the columns line up. Its
            // width is fixed by the heading so it doesn't shift as details grow.
            let block = max(80, visibleWidth(heading) + 4)
            let left = String(repeating: " ", count: max(0, (width - block) / 2))
            let top = max(0, (height - lines.count) / 3)
            out = "\u{1B}[H" + String(repeating: "\u{1B}[K\n", count: top)
            lines = lines.map { left + $0 }
        } else {
            out = drawnLines > 0 ? "\u{1B}[\(drawnLines)F" : ""
        }
        out += lines.map { $0 + "\u{1B}[0m\u{1B}[K" }.joined(separator: "\n") + "\n"
        drawnLines = lines.count
        write(out)
    }

    private func line(_ stage: Stage, width: Int) -> String {
        let title = stage.title.padding(toLength: 24, withPad: " ", startingAt: 0)
        switch stage.state {
        case .waiting:
            return "  " + dim("○  " + title)
        case .skipped:
            return "  " + dim("–  " + title + stage.detail)
        case .done:
            let time = stage.elapsed >= 0 ? dim(Self.duration(stage.elapsed)) : ""
            return "  " + green("✓") + "  " + title + dim(stage.detail) + "  " + time
        case .running:
            let spinner = ["◐", "◓", "◑", "◒"][Int(Date.now.timeIntervalSince1970 * 6) % 4]
            var text = "  " + blue(spinner) + "  " + bold(title)
            if stage.total > 0 {
                let barWidth = max(10, min(40, width - 24 - 34))
                let fraction = Double(stage.done) / Double(stage.total)
                text += Self.bar(fraction, width: barWidth) + "  " + "\(stage.done)/\(stage.total)"
                if let left = remaining(stage) { text += dim("  " + left) }
            } else if !stage.detail.isEmpty {
                text += dim(stage.detail)
            }
            return text
        }
    }

    /// A rounded bar drawn with eighth-blocks so it moves smoothly, in a blue
    /// that brightens toward the leading edge.
    static func bar(_ fraction: Double, width: Int) -> String {
        let eighths = Int((max(0, min(1, fraction)) * Double(width * 8)).rounded())
        let full = eighths / 8, part = eighths % 8
        var out = ""
        for i in 0..<full {
            let t = Double(i) / Double(max(1, width - 1))
            let (r, g, b) = (Int(10 + 90 * t), Int(110 + 70 * t), 255)
            out += "\u{1B}[38;2;\(r);\(g);\(b)m█"
        }
        if part > 0 { out += Theme.fg(Theme.blue) + ["", "▏", "▎", "▍", "▌", "▋", "▊", "▉"][part] }
        let used = full + (part > 0 ? 1 : 0)
        out += Theme.fg(Theme.track) + String(repeating: "━", count: max(0, width - used))
        return out + "\u{1B}[0m"
    }

    private func remaining(_ stage: Stage) -> String? {
        guard let started = stage.started, stage.done > 2, stage.done < stage.total else { return nil }
        let left = Date.now.timeIntervalSince(started) / Double(stage.done) * Double(stage.total - stage.done)
        return left < 60 ? "~\(max(1, Int(left)))s left" : "~\(Int(left / 60) + 1) min left"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        seconds < 1 ? String(format: "%.1fs", seconds)
            : seconds < 60 ? "\(Int(seconds))s"
            : "\(Int(seconds) / 60)m \(Int(seconds) % 60)s"
    }

    private func terminalSize() -> (columns: Int, rows: Int) {
        var ws = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0 else { return (80, 24) }
        return (Int(ws.ws_col), Int(max(ws.ws_row, 1)))
    }

    /// Columns a styled string takes on screen, escape codes left out.
    private func visibleWidth(_ styled: String) -> Int {
        styled.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression).count
    }

    private func write(_ text: String) { FileHandle.standardOutput.write(Data(text.utf8)) }
    private func bold(_ s: String) -> String { "\u{1B}[1m\(s)\u{1B}[22m" }
    private func dim(_ s: String) -> String { "\u{1B}[2m\(s)\u{1B}[22m" }
    private func green(_ s: String) -> String { Theme.fg(Theme.green) + s + "\u{1B}[39m" }
    private func blue(_ s: String) -> String { Theme.fg(Theme.blue) + s + "\u{1B}[39m" }
}
