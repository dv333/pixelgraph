import ArgumentParser
import CoreGraphics
import Foundation

/// One thing you can change on the Settings screen, with its default.
struct Setting: Sendable {
    enum Kind: Sendable {
        case toggle
        case choice([String])
        /// A number in `range`; ← → change it by `step`.
        case number(ClosedRange<Double>, step: Double, decimals: Int, unit: String)
        /// Free text; ← → go through the suggestions.
        case text(suggestions: [String])
        /// A time of day, HH:MM.
        case time
    }

    let key: Settings.Key
    let section: String
    let title: String
    let help: String
    let kind: Kind
    let standard: String

    /// How a stored value reads on screen.
    func display(_ value: String) -> String {
        switch kind {
        case .toggle: return value == "on" ? "On" : "Off"
        case .number(_, _, let decimals, let unit):
            let number = Double(value) ?? 0
            return String(format: "%.\(decimals)f", number) + (unit.isEmpty ? "" : " " + unit)
        default: return value
        }
    }

    /// A typed or stepped value, cleaned up; nil when it can't be used.
    func normalized(_ text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .toggle: return ["on", "off"].contains(text) ? text : nil
        case .choice(let options): return options.first { $0.lowercased() == text.lowercased() }
        case .number(let range, _, let decimals, _):
            guard let number = Double(text.replacingOccurrences(of: ",", with: ".")) else { return nil }
            return String(format: "%.\(decimals)f", min(max(number, range.lowerBound), range.upperBound))
        case .text: return text.isEmpty ? standard : text
        case .time: return Nightly.parse(text).map { String(format: "%02d:%02d", $0.hour, $0.minute) }
        }
    }

    /// The value one step left (-1) or right (+1) of `value`.
    func step(_ value: String, by direction: Int) -> String {
        switch kind {
        case .toggle: return value == "on" ? "off" : "on"
        case .choice(let options), .text(let options):
            guard !options.isEmpty else { return value }
            let index = options.firstIndex(of: value) ?? (direction > 0 ? -1 : 0)
            return options[(index + direction + options.count) % options.count]
        case .number(let range, let increment, _, _):
            let number = (Double(value) ?? range.lowerBound) + Double(direction) * increment
            return normalized(String(min(max(number, range.lowerBound), range.upperBound))) ?? value
        case .time:
            guard let t = Nightly.parse(value) else { return standard }
            let minutes = ((t.hour * 60 + t.minute + direction * 30) % 1_440 + 1_440) % 1_440
            return String(format: "%02d:%02d", minutes / 60, minutes % 60)
        }
    }
}

/// Your settings: what you've changed, saved in pixelgraph.db, over the
/// defaults. A flag on the command line wins for that one run.
struct Settings: Sendable {
    enum Key: String, CaseIterable, Sendable {
        case moment = "similar.moment", window = "similar.window", scene = "similar.scene"
        case farApart = "similar.far-apart", pixelCheck = "similar.pixel-check"
        case model = "pick.model", offline = "pick.offline"
        case documents = "sort.documents", describe = "sort.describe"
        case junk = "junk.on", blurry = "junk.blurry", tilt = "junk.tilt", screenshotDays = "junk.screenshot-days"
        case findAccidental = "junk.find.accidental", findBlurry = "junk.find.blurry", findCrooked = "junk.find.crooked"
        case findExposure = "junk.find.exposure", findSmudged = "junk.find.smudged", findScreenshots = "junk.find.screenshots"
        case findForwarded = "junk.find.forwarded", findLowQuality = "junk.find.low-quality"
        case moveDescribe = "move.describe"
        case graphics = "display.graphics", intro = "display.intro", theme = "display.theme", font = "display.font"
        case nightly = "nightly.on", nightlyTime = "nightly.time", nightlyDays = "nightly.days"
        case nightlyLimit = "nightly.limit", assistant = "nightly.assistant", emptyDays = "nightly.empty-days"
        case judgeModel = "ai.model", judgeConfidence = "ai.confidence", ollamaHost = "ai.host"
    }

    static let all: [Setting] = [
        Setting(key: .moment, section: "Lookalikes", title: "Shots taken together",
                help: "How different shots taken moments apart may look and still be lookalikes. Higher finds more; lower is stricter.",
                kind: .number(0.2...0.8, step: 0.05, decimals: 2, unit: ""), standard: "0.50"),
        Setting(key: .window, section: "Lookalikes", title: "Easing over",
                help: "Over this many minutes apart, the limit above eases to the stricter one below.",
                kind: .number(1...120, step: 1, decimals: 0, unit: "min"), standard: "10"),
        Setting(key: .scene, section: "Lookalikes", title: "Shots any time apart",
                help: "For copies, edits and the same scene revisited. Stricter, so a year of couch photos doesn't become one group.",
                kind: .number(0.1...0.5, step: 0.05, decimals: 2, unit: ""), standard: "0.30"),
        Setting(key: .farApart, section: "Lookalikes", title: "Different places",
                help: "Photos taken further apart than this are never lookalikes, unless they're copies. 0 turns it off.",
                kind: .number(0...50, step: 0.5, decimals: 1, unit: "km"), standard: "2.0"),
        Setting(key: .pixelCheck, section: "Lookalikes", title: "Pixel check",
                help: "Close calls taken apart in time are lined up pixel by pixel; less alike than this, they stay apart. Higher is stricter.",
                kind: .number(0.3...0.8, step: 0.05, decimals: 2, unit: ""), standard: "0.50"),

        Setting(key: .model, section: "Picking the best", title: "Apple Intelligence",
                help: "Apple's on-device model settles close calls, checks eyes and faces, and gives borderline junk a second look.",
                kind: .toggle, standard: "on"),
        Setting(key: .offline, section: "Picking the best", title: "Stay offline",
                help: "Never download from iCloud; judge photos from the previews on this Mac. Faster, a little less exact.",
                kind: .toggle, standard: "off"),

        Setting(key: .documents, section: "Sorting", title: "Sort documents",
                help: "Receipts, forms and screenshots go to their own tab, to file in PGDocuments.",
                kind: .toggle, standard: "on"),
        Setting(key: .describe, section: "Sorting", title: "Tag scenes",
                help: "Tag what's in each grouped photo: beach, dog, sunset.",
                kind: .toggle, standard: "on"),

        Setting(key: .junk, section: "Junk", title: "Look for junk",
                help: "Photos with no lookalike that look like rejects get their own groups, one per reason, to move to PGJunk.",
                kind: .toggle, standard: "on"),
        Setting(key: .blurry, section: "Junk", title: "Blurry means the blurriest",
                help: "The blurriest this share of each scan can count as blurry: alone in its third of that, or with another sign.",
                kind: .number(5...30, step: 1, decimals: 0, unit: "%"), standard: "15"),
        Setting(key: .tilt, section: "Junk", title: "Crooked from",
                help: "A horizon tilted this much or more counts as crooked (up to 35°; beyond that it was on purpose).",
                kind: .number(3...20, step: 1, decimals: 0, unit: "°"), standard: "6"),
        Setting(key: .screenshotDays, section: "Junk", title: "Old screenshots after",
                help: "Screenshots older than this count as junk.",
                kind: .number(1...365, step: 1, decimals: 0, unit: "days"), standard: "30"),
        Setting(key: .findAccidental, section: "Junk", title: "Find accidental shots",
                help: "Pocket, floor or ceiling shots with nothing in them. A face always means it was meant.",
                kind: .toggle, standard: "on"),
        Setting(key: .findBlurry, section: "Junk", title: "Find blurry shots", help: "Out of focus or motion blur.",
                kind: .toggle, standard: "on"),
        Setting(key: .findCrooked, section: "Junk", title: "Find crooked shots", help: "Tilted horizons, as set above.",
                kind: .toggle, standard: "on"),
        Setting(key: .findExposure, section: "Junk", title: "Find bad exposure", help: "Nearly black, or blown out.",
                kind: .toggle, standard: "on"),
        Setting(key: .findSmudged, section: "Junk", title: "Find smudged lens", help: "A smear across the whole picture.",
                kind: .toggle, standard: "on"),
        Setting(key: .findScreenshots, section: "Junk", title: "Find old screenshots", help: "Screenshots older than set above.",
                kind: .toggle, standard: "on"),
        Setting(key: .findForwarded, section: "Junk", title: "Find forwarded images",
                help: "Small images saved by WhatsApp, Telegram, Messenger and the like.",
                kind: .toggle, standard: "on"),
        Setting(key: .findLowQuality, section: "Junk", title: "Find low quality",
                help: "Photos Apple rates poorly, when another sign agrees.",
                kind: .toggle, standard: "on"),

        Setting(key: .moveDescribe, section: "Moving", title: "Describe kept photos",
                help: "When you move, the photos you keep get a caption, title and keywords after what's there, so Photos search finds them. Undo puts the old ones back.",
                kind: .toggle, standard: "on"),

        Setting(key: .graphics, section: "Display", title: "Photos",
                help: "auto: sharp photos in iTerm2, WezTerm, kitty and Ghostty, colour blocks elsewhere. iterm or kitty forces that way; blocks works in any true-colour terminal.",
                kind: .choice(["auto", "iterm", "kitty", "blocks"]), standard: "auto"),
        Setting(key: .theme, section: "Display", title: "Theme",
                help: "auto follows your terminal's background; light or dark picks one. PIXELGRAPH_THEME still wins when set.",
                kind: .choice(["auto", "light", "dark"]), standard: "auto"),
        Setting(key: .intro, section: "Display", title: "Opening title",
                help: "The rack-focus title when PixelGraph starts (in terminals that can show images).",
                kind: .toggle, standard: "on"),
        Setting(key: .font, section: "Display", title: "Font",
                help: "For the opening title and the headings of the web report. Text on these screens is your terminal's own font, set in the terminal's settings.",
                kind: .choice(Typeface.allCases.map(\.rawValue)), standard: Typeface.sfMono.rawValue),

        Setting(key: .nightly, section: "Nightly clean-up", title: "Run every night",
                help: "Moves clear duplicates from recent photos to PGDuplicates at the time below; never deletes. Close calls wait for you.",
                kind: .toggle, standard: "off"),
        Setting(key: .nightlyTime, section: "Nightly clean-up", title: "At",
                help: "Time of day, 24-hour. ← → by half an hour, enter to type.",
                kind: .time, standard: "02:00"),
        Setting(key: .nightlyDays, section: "Nightly clean-up", title: "Photos from the last",
                help: "Each night looks at photos taken in this many days.",
                kind: .number(1...365, step: 1, decimals: 0, unit: "days"), standard: "30"),
        Setting(key: .nightlyLimit, section: "Nightly clean-up", title: "Move at most",
                help: "Photos moved in one night, at most.",
                kind: .number(10...5_000, step: 50, decimals: 0, unit: "photos"), standard: "300"),
        Setting(key: .assistant, section: "Nightly clean-up", title: "Then ask",
                help: "An assistant on this Mac that settles the close calls with PixelGraph's tools; deleting is switched off for it.",
                kind: .choice(["none", "claude", "codex", "opencode"]), standard: "none"),
        Setting(key: .emptyDays, section: "Nightly clean-up", title: "Remind to empty after",
                help: "After this long in PGDuplicates or PGJunk, a reminder suggests pixelgraph empty, which asks before deleting.",
                kind: .number(7...365, step: 1, decimals: 0, unit: "days"), standard: "30"),

        Setting(key: .judgeModel, section: "Local AI (Ollama)", title: "Vision model",
                help: "A vision model in Ollama that double-checks close calls and junk each night. 32b needs 48 GB of memory; 8b runs on 16 GB. Enter to type another.",
                kind: .text(suggestions: ["off", "qwen3-vl:8b", "qwen3-vl:32b", "qwen2.5vl:7b", "qwen2.5vl:32b"]), standard: "off"),
        Setting(key: .judgeConfidence, section: "Local AI (Ollama)", title: "Must be this sure",
                help: "The model's agreement moves photos only when it's at least this sure (0–1).",
                kind: .number(0.5...0.99, step: 0.05, decimals: 2, unit: ""), standard: "0.85"),
        Setting(key: .ollamaHost, section: "Local AI (Ollama)", title: "Ollama at",
                help: "Where Ollama listens. Enter to type another address.",
                kind: .text(suggestions: ["http://localhost:11434"]), standard: "http://localhost:11434"),
    ]

    static let specs: [Key: Setting] = Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0) })

    /// What you've changed, by key.
    private(set) var saved: [String: String]

    static func load() -> Settings {
        var saved = Database.open()?.settings() ?? [:]
        // The nightly job is what launchd has, wherever it was set up.
        saved[Key.nightly.rawValue] = Nightly.isOn ? "on" : nil
        if let time = Nightly.installedTime() { saved[Key.nightlyTime.rawValue] = time }
        return Settings(saved: saved)
    }

    /// Saves a value; nil (or the default) puts the default back.
    static func save(_ key: Key, _ value: String?) {
        let standard = specs[key]?.standard
        Database.open()?.setSetting(key.rawValue, value == standard ? nil : value)
    }

    subscript(key: Key) -> String {
        guard let spec = Self.specs[key] else { return "" }
        guard let value = saved[key.rawValue], let clean = spec.normalized(value) else { return spec.standard }
        return clean
    }

    func isDefault(_ key: Key) -> Bool { self[key] == Self.specs[key]?.standard }
    var changed: Int { Key.allCases.filter { !isDefault($0) }.count }

    func bool(_ key: Key) -> Bool { self[key] == "on" }
    func number(_ key: Key) -> Double { Double(self[key]) ?? 0 }
    func int(_ key: Key) -> Int { Int(number(key).rounded()) }
    /// nil for "off" or "none".
    func optional(_ key: Key) -> String? { ["off", "none", ""].contains(self[key]) ? nil : self[key] }

    // MARK: What they mean

    var rules: GroupingRules {
        GroupingRules(momentThreshold: Float(number(.moment)), momentWindow: number(.window) * 60,
                      sceneThreshold: Float(number(.scene)), farApartMetres: number(.farApart) * 1_000)
    }

    var junkRules: Junk.Rules {
        let reasons: [(Key, [String])] = [
            (.findAccidental, ["accidental shot"]), (.findBlurry, ["blurry", "motion blur"]), (.findCrooked, ["crooked"]),
            (.findExposure, ["bad exposure"]), (.findSmudged, ["smudged lens"]), (.findScreenshots, ["old screenshot"]),
            (.findForwarded, ["forwarded image"]), (.findLowQuality, ["low quality"]),
        ]
        return Junk.Rules(screenshotDays: int(.screenshotDays), blurShare: Float(number(.blurry)) / 100,
                          minTilt: Float(number(.tilt)), reasons: Set(reasons.filter { bool($0.0) }.flatMap { $0.1 }))
    }

    var scanner: Scanner.Options {
        var options = Scanner.Options()
        options.rules = rules
        options.pixelCheck = Float(number(.pixelCheck))
        options.useModel = bool(.model)
        options.offline = bool(.offline)
        options.documents = bool(.documents)
        options.describe = bool(.describe)
        options.junk = bool(.junk)
        options.junkRules = junkRules
        return options
    }

    var graphics: TerminalImage.Mode { TerminalImage.Mode(rawValue: self[.graphics]) ?? .auto }
    var typeface: Typeface { Typeface(rawValue: self[.font]) ?? .sfMono }

    /// Ollama's address when you've set one; otherwise OLLAMA_HOST or the usual.
    var ollamaHost: String? { isDefault(.ollamaHost) ? nil : self[.ollamaHost] }

    func judge(model: String? = nil) -> Judge? {
        (model ?? optional(.judgeModel)).map { Judge(model: $0, host: ollamaHost) }
    }
}

// MARK: - The screen

/// Settings: every setting, grouped, with what it does and its default.
/// ← → change the highlighted one, enter types a value, d sets its default.
/// Changes are a draft, marked as unsaved, until s saves them; leaving with
/// unsaved changes asks first.
final class SettingsScreen {
    private let ui: UI
    private var settings = Settings.load()
    /// Changes not saved yet.
    private var pending: [Settings.Key: String] = [:]
    private var selected = 0
    private var scroll = 0
    /// Text being typed for the highlighted setting.
    private var typing: String?
    private var toast: String?
    /// Esc with unsaved changes: "Save your changes?" is showing.
    private var confirmingLeave = false
    /// ? was pressed: the keys are showing; any key closes them.
    private var showingKeys = false
    /// The opening title in each font, as drawn for the preview, by font, size and theme.
    private var previews: [String: CGImage] = [:]

    /// A section heading, a setting, or the last row that sets them all back.
    private enum Line { case heading(String), setting(Setting), resetAll }
    private let lines: [Line] = {
        var lines: [Line] = []
        var section = ""
        for setting in Settings.all {
            if setting.section != section {
                if !lines.isEmpty { lines.append(.heading("")) }
                lines.append(.heading(setting.section.uppercased()))
                section = setting.section
            }
            lines.append(.setting(setting))
        }
        return lines + [.heading(""), .resetAll]
    }()

    private func isSelectable(_ line: Line) -> Bool {
        if case .heading = line { return false }
        return true
    }

    private var onResetAll: Bool {
        guard lines.indices.contains(selected), case .resetAll = lines[selected] else { return false }
        return true
    }

    init(ui: UI) {
        self.ui = ui
        selected = lines.firstIndex { if case .setting = $0 { return true } else { return false } } ?? 0
    }

    /// Runs until esc; returns the settings as they now are.
    @discardableResult
    func show() -> Settings {
        let ownsTerminal = !ui.active
        ui.enter()
        defer { if ownsTerminal { ui.leave() } }
        draw()
        while true {
            let key = ui.term.nextKey()
            if handle(key) { break }
            draw()
        }
        return Settings.load()
    }

    private var current: Setting? {
        guard lines.indices.contains(selected), case .setting(let setting) = lines[selected] else { return nil }
        return setting
    }

    /// A setting's value as shown: the unsaved one if there is one.
    private func value(_ key: Settings.Key) -> String { pending[key] ?? settings[key] }

    /// True to leave.
    private func handle(_ key: Terminal.Key) -> Bool {
        if key == .resize { return false }
        toast = nil
        if showingKeys {
            showingKeys = false
            return false
        }
        if confirmingLeave {
            switch key {
            case .enter, .char("s"), .char("y"):
                save()
                return true
            case .char("d"), .char("n"):
                return true
            case .click(let row, let col):
                switch ui.sheetClick(row: row, col: col) {
                case .button:
                    save()
                    return true
                case .outside: confirmingLeave = false
                case .inside: break
                }
            case .escape, .backspace: confirmingLeave = false
            default: break
            }
            return false
        }
        if typing != nil { typed(key); return false }
        switch key {
        case .escape, .quit, .char("q"), .backspace:
            if pending.isEmpty { return true }
            confirmingLeave = true
        case .up: move(-1)
        case .down: move(1)
        case .home: selected = 0; move(1)
        case .end: selected = lines.count; move(-1)
        case .char("?"): showingKeys = true
        case .scroll(let ticks): if ticks != 0 { move(ticks > 0 ? 1 : -1) }
        case _ where onResetAll && [.enter, .right, .char(" "), .char("d")].contains(key): resetAll()
        case .left: change(-1)
        case .right, .char(" "): change(1)
        case .enter:
            guard let setting = current else { break }
            switch setting.kind {
            case .toggle, .choice: change(1)
            default: typing = ""
            }
        case .char("s"):
            if pending.isEmpty {
                toast = ui.dim("Nothing to save.")
            } else {
                let count = pending.count
                save()
                if toast == nil { toast = ui.green("✓") + " Saved \(count) change\(count == 1 ? "" : "s")." }
            }
        case .char("d"):
            if let setting = current { set(setting, setting.standard) }
        case .click(let row, _):
            let index = row - top + scroll
            if row - top < listRows, lines.indices.contains(index), isSelectable(lines[index]) { selected = index }
        default: break
        }
        return false
    }

    private func move(_ step: Int) {
        var next = selected + step
        while lines.indices.contains(next) {
            if isSelectable(lines[next]) { selected = next; return }
            next += step
        }
    }

    /// The last row: every setting back to its default, as unsaved changes.
    private func resetAll() {
        for setting in Settings.all { set(setting, setting.standard) }
        toast = pending.isEmpty ? ui.dim("Everything is already at its default.")
            : ui.amber("Every setting set to its default · s to save, esc to drop")
    }

    private func change(_ direction: Int) {
        guard let setting = current else { return }
        set(setting, setting.step(value(setting.key), by: direction))
    }

    private func typed(_ key: Terminal.Key) {
        guard var text = typing, let setting = current else { return }
        switch key {
        case .escape, .quit: typing = nil; return
        case .backspace: if !text.isEmpty { text.removeLast() }
        case .char(let c): text.append(c)
        case .enter:
            guard let value = setting.normalized(text) else {
                toast = ui.red("That doesn't fit “\(setting.title)”.")
                return
            }
            typing = nil
            set(setting, value)
            return
        default: break
        }
        typing = text
    }

    /// Notes an unsaved change; back to the saved value drops it.
    private func set(_ setting: Setting, _ value: String) {
        pending[setting.key] = value == settings[setting.key] ? nil : value
    }

    /// Saves every unsaved change; the nightly job is set up or stopped here.
    private func save() {
        var problems: [String] = []
        for (key, newValue) in pending where key != .nightly { Settings.save(key, newValue) }
        if let nightly = pending[.nightly] {
            if nightly == "on" {
                do { try Nightly.install(at: value(.nightlyTime)) } catch { problems.append(error.localizedDescription) }
            } else {
                Nightly.remove()
            }
        } else if let time = pending[.nightlyTime], Nightly.isOn {
            // A new time for a nightly job that's on: set it up again.
            do { try Nightly.install(at: time) } catch { problems.append(error.localizedDescription) }
        }
        let themeChanged = pending[.theme] != nil
        pending = [:]
        settings = Settings.load()
        if themeChanged { Theme.detect() }
        if let problem = problems.first { toast = ui.red(problem) }
    }

    private func verb(_ setting: Setting) -> String {
        switch setting.kind {
        case .toggle: return "switch"
        case .choice: return "next"
        default: return "type"
        }
    }

    // MARK: Drawing

    private var width: Int { max(30, min(ui.cols - 4, 88)) }
    private var left: Int { max(3, (ui.cols - width) / 2 + 1) }
    private var top: Int { 4 }
    /// Rows for the list: the help underneath takes four, the bar one.
    private var visible: Int { max(3, ui.rows - top - 6) }
    /// Rows the font preview takes from the bottom of the list: a gap, then the picture.
    private let previewRows = 6
    /// Font is highlighted and the terminal shows real images: the list
    /// makes room for the opening title in that font.
    private var showsPreview: Bool { current?.key == .font && ui.sharp && visible - previewRows >= 3 }
    private var listRows: Int { showsPreview ? visible - previewRows : visible }

    private func draw() {
        if ui.tooSmall { return ui.term.write(ui.tooSmallScreen()) }
        if selected < scroll { scroll = selected }
        if selected >= scroll + listRows { scroll = selected - listRows + 1 }
        var out = ui.clear()
        let changed = Settings.Key.allCases.filter { value($0) != Settings.specs[$0]?.standard }.count
        var heading = ui.dim("  ·  " + (changed == 0 ? "all defaults" : "\(changed) changed from the default"))
        if !pending.isEmpty { heading += ui.amber("  ·  \(pending.count) unsaved") }
        out += ui.at(2, left) + ui.clip(ui.bold("Settings") + heading, width)
        for (n, index) in lines.indices.dropFirst(scroll).prefix(listRows).enumerated() {
            let row = top + n
            switch lines[index] {
            case .heading(let text): out += ui.at(row, left) + ui.dim(text)
            case .setting(let setting):
                let isDefault = value(setting.key) == setting.standard
                var shown = setting.display(value(setting.key))
                if index == selected, typing != nil { shown = (typing ?? "") + "▏" }
                // Unsaved: amber with a star; changed from the default: a blue dot.
                let styled = pending[setting.key] != nil ? ui.amber("* " + shown)
                    : isDefault ? ui.dim(shown) : ui.blue("● ") + shown
                let line = ui.spread("  " + setting.title, styled, width: width - 2)
                out += index == selected
                    ? ui.at(row, left - 2) + ui.bar() + ui.highlight(" " + line, width: width)
                    : ui.at(row, left) + line
            case .resetAll:
                let line = ui.spread("  Set every setting back to its default…", ui.dim(changed == 0 ? "all defaults" : "\(changed) changed"),
                                     width: width - 2)
                out += index == selected
                    ? ui.at(row, left - 2) + ui.bar() + ui.highlight(" " + line, width: width)
                    : ui.at(row, left) + ui.dim(line)
            }
        }
        // Under the sheet the picture would show through, so it waits.
        if showsPreview, !confirmingLeave { out += preview(row: top + listRows + 1) }
        if let setting = current {
            let helpTop = top + visible + 1
            for (n, text) in ui.wrap(setting.help, width: width - 2, lines: 2).enumerated() {
                out += ui.at(helpTop + n, left) + ui.dim(text)
            }
            var note = value(setting.key) == setting.standard ? "default" : "default: \(setting.display(setting.standard)) · d sets it"
            if pending[setting.key] != nil { note += " · saved: \(setting.display(settings[setting.key]))" }
            out += ui.at(helpTop + 2, left) + ui.dim(note)
        } else if onResetAll {
            let help = "Marks every setting for its default. Nothing changes until you press s; esc drops it."
            for (n, text) in ui.wrap(help, width: width - 2, lines: 2).enumerated() {
                out += ui.at(top + visible + 1 + n, left) + ui.dim(text)
            }
        }
        if let toast { out += ui.at(ui.rows - 1, left) + ui.clip(toast, width) }
        let hints: String
        if typing != nil {
            hints = "type a value · enter set · esc cancel"
        } else {
            hints = onResetAll ? "↑↓ choose · enter set them all · esc back · ? keys"
                : "↑↓ choose · ←→ change · enter \(current.map(verb) ?? "change") · d default · esc back · ? keys"
        }
        let action = pending.isEmpty || typing != nil ? "" : ui.button("s Save \(pending.count) change\(pending.count == 1 ? "" : "s")")
        let room = width - ui.visibleWidth(action) - 2
        out += ui.barLine(ui.rows, String(repeating: " ", count: max(0, left - 3))
            + ui.spread(ui.clip(ui.hints(hints), max(0, room)), action, width: width))
        if showingKeys {
            func row(_ key: String, _ text: String) -> String { ui.blue(key.padding(toLength: 10, withPad: " ", startingAt: 0)) + text }
            out += ui.sheet([
                ui.bold("Keys"), "",
                row("↑ ↓", "choose a setting (home and end: first and last)"),
                row("← →", "change it"),
                row("enter", "switch, next, or type a value"),
                row("d", "set it back to its default"),
                row("s", "save your changes; until then they're amber with a *"),
                row("esc", "back (asks first if something isn't saved)"),
                "", ui.dim("any key to close"),
            ], width: 68)
        }
        if confirmingLeave {
            let w = min(ui.cols - 2, 60) - 4
            let names = pending.keys.compactMap { Settings.specs[$0]?.title }.sorted().joined(separator: ", ")
            out += ui.sheet([ui.bold("Save your changes?"), ""]
                + ui.wrap("\(pending.count) unsaved: \(names).", width: w, lines: 3).map { ui.dim($0) }
                + ["", ui.spread("", ui.dim("esc Keep editing   d Discard   ") + ui.button("enter Save"), width: w)], width: 64)
        }
        ui.term.write(out)
    }

    /// The opening title, settled, in the font shown (saved or not), across
    /// the column at the box's real pixel size so it stays sharp.
    private func preview(row: Int) -> String {
        let typeface = Typeface(rawValue: value(.font)) ?? .sfMono
        let rows = previewRows - 1
        let long = ui.boxPixels(cols: width, rows: rows)
        let aspect = Double(width) * ui.term.cellAspect / Double(rows)
        let size = (width: long, height: max(1, Int((Double(long) / aspect).rounded())))
        let key = "\(typeface.rawValue) \(size.width)x\(size.height) \(Theme.light)"
        if previews[key] == nil { previews[key] = Intro.still(width: size.width, height: size.height, typeface: typeface) }
        guard let picture = previews[key] else { return "" }
        return ui.image(picture, key: "font preview " + key, row: row, col: left, cols: width, rows: rows)
    }
}

// MARK: - Nightly job

/// The launchd job that runs `pixelgraph auto` each night.
enum Nightly {
    static let label = "dev.pixelgraph.nightly"
    static var plist: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var log: URL { Paths.nightly.appendingPathComponent("auto.log") }
    static var isOn: Bool { FileManager.default.fileExists(atPath: plist.path) }

    static func parse(_ time: String) -> (hour: Int, minute: Int)? {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
        return (parts[0], parts[1])
    }

    /// The time the installed job runs at, as HH:MM.
    static func installedTime() -> String? {
        guard let data = try? Data(contentsOf: plist),
              let job = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let interval = job["StartCalendarInterval"] as? [String: Any],
              let hour = interval["Hour"] as? Int, let minute = interval["Minute"] as? Int else { return nil }
        return String(format: "%02d:%02d", hour, minute)
    }

    /// Installs (or replaces) the job. With no extra arguments, each night
    /// uses your settings as they are then.
    static func install(at time: String, arguments extra: [String] = [], now: Bool = false) throws {
        guard let t = parse(time) else { throw Failure(message: "Give the time as HH:MM, e.g. 02:00.") }
        guard let me = Bundle.main.executableURL?.path else { throw Failure(message: "Can't tell where pixelgraph is installed.") }
        let domain = "gui/\(getuid())"
        launchctl(["bootout", "\(domain)/\(label)"])
        try FileManager.default.createDirectory(at: Paths.nightly, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        let job: [String: Any] = [
            "Label": label,
            "ProgramArguments": [me, "auto"] + extra,
            "StartCalendarInterval": ["Hour": t.hour, "Minute": t.minute],
            "StandardOutPath": log.path,
            "StandardErrorPath": log.path,
            "ProcessType": "Background",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
        try data.write(to: plist, options: .atomic)
        guard launchctl(["bootstrap", domain, plist.path]) == 0 else {
            throw Failure(message: "launchctl couldn't load \(plist.path).")
        }
        Settings.save(.nightlyTime, String(format: "%02d:%02d", t.hour, t.minute))
        if now { launchctl(["kickstart", "-k", "\(domain)/\(label)"]) }
    }

    static func remove() {
        launchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plist)
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @discardableResult
    private static func launchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}

// MARK: - Command

/// `pixelgraph settings`: the Settings screen, or every setting as text.
struct SettingsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "settings", abstract: "Change PixelGraph's settings (saved for every run), or list them.")

    @Flag(help: "Print every setting instead of opening the screen.")
    var list = false

    func run() throws {
        guard !list, isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0 else {
            let settings = Settings.load()
            var section = ""
            for setting in Settings.all {
                if setting.section != section {
                    print((section.isEmpty ? "" : "\n") + setting.section)
                    section = setting.section
                }
                let value = setting.display(settings[setting.key])
                let note = settings.isDefault(setting.key) ? "" : "   (default \(setting.display(setting.standard)))"
                print("  \(setting.title.padding(toLength: 28, withPad: " ", startingAt: 0)) \(value)\(note)")
            }
            print("\nSaved in \(Paths.database.path)")
            return
        }
        SettingsScreen(ui: UI(graphics: Settings.load().graphics)).show()
    }
}
