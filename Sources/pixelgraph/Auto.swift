import ArgumentParser
import Foundation

/// `pixelgraph auto`: the nightly clean-up. Scans recent photos into the
/// nightly workspace, moves only the clear cases to PGDuplicates (never
/// deletes), leaves close calls for you or an assistant, and says what it did.
struct Auto: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Nightly clean-up: move clear duplicates to PGDuplicates and leave the close calls.")

    @Option(help: "Look at photos taken in the last this many days.")
    var days = 30

    @Option(help: "Move at most this many photos in one run.")
    var limit = 300

    @Flag(help: "Show what would move without moving anything.")
    var dryRun = false

    @Option(help: "Then let an assistant settle the close calls: claude, codex or opencode.")
    var assistant: String?

    @Option(help: "Ask a local vision model through Ollama about the close calls and junk, e.g. qwen2.5vl:32b.")
    var judgeModel: String?

    @Option(help: "How sure the local model must be (0–1) before its agreement moves anything.")
    var judgeConfidence = 0.85

    @Option(help: "Scan this folder instead of the Photos library.")
    var folder: String?

    func validate() throws {
        if let assistant, !Self.assistants.contains(assistant) { throw ValidationError("--assistant is claude, codex or opencode.") }
        guard (0...1).contains(judgeConfidence) else { throw ValidationError("--judge-confidence is between 0 and 1.") }
    }

    static let assistants = ["claude", "codex", "opencode"]

    func run() async throws {
        let started = Date.now
        let source: Source
        if let folder {
            source = .folder(URL(fileURLWithPath: (folder as NSString).expandingTildeInPath))
        } else {
            try await Library.requestAccess()
            source = .dates(from: Calendar.current.date(byAdding: .day, value: -days, to: .now), to: nil)
        }
        let run = try await Agent.scan(source, into: .nightly, quiet: isatty(STDOUT_FILENO) == 0)
        let moved = try await Agent.move(.nightly, groups: nil, to: .duplicates, dryRun: dryRun, clearOnly: true, limit: limit)
        var judged: Agent.Judged?
        if let judgeModel {
            judged = try await Agent.judgeAndMove(.nightly, judge: Judge(model: judgeModel), threshold: judgeConfidence,
                                                  limit: max(0, limit - moved.photos), dryRun: dryRun)
        }
        let after = (try? Run.load(from: Agent.Workspace.nightly.runFile)) ?? run
        let closeCalls = Agent.places(after, pendingOnly: true).filter { !$0.junk }.count
        let junk = (after.junkGroups ?? []).count

        var summary = dryRun ? "Would move \(moved.photos) clear duplicates" : "Moved \(moved.photos) clear duplicates to PGDuplicates"
        if let judged {
            summary += " · the local model agreed on \(judged.agreed) of \(judged.asked) close calls"
                + " (\(judged.photos) more to PGDuplicates, \(judged.junk) to PGJunk)"
            if let problem = judged.problems.first { summary += " · model problem: \(problem)" }
        }
        summary += closeCalls > 0 ? " · \(closeCalls) close call\(closeCalls == 1 ? "" : "s") to look at" : " · nothing else to decide"
        if junk > 0 { summary += " · \(junk) junk group\(junk == 1 ? "" : "s")" }
        print(summary)
        print("Review them with `pixelgraph review --nightly`, or ask your assistant.")

        var entry: [String: Any] = [
            "date": started.formatted(.iso8601), "scope": run.scope, "scanned": run.scanned,
            "moved": moved.photos, "dry_run": dryRun, "close_calls": closeCalls, "junk_groups": junk, "summary": summary,
        ]
        if let judged { entry["judge"] = ["asked": judged.asked, "agreed": judged.agreed, "photos": judged.photos, "junk": judged.junk] }
        if let assistant, closeCalls > 0, !dryRun {
            entry["assistant"] = assistant
            entry["assistant_exit"] = Int(ask(assistant, closeCalls: closeCalls))
        }
        Agent.writeNightlyLog(entry)
        notify(summary)
        remindToEmpty()
    }

    /// Once a month, when photos have sat in PGDuplicates or PGJunk for 30
    /// days, a notification suggests `pixelgraph empty`. Nothing is deleted
    /// until you say so there.
    private func remindToEmpty() {
        let marker = Paths.nightly.appendingPathComponent("last-reminder")
        let last = (try? String(contentsOf: marker, encoding: .utf8)).flatMap { try? Date($0, strategy: .iso8601) } ?? .distantPast
        guard Date.now.timeIntervalSince(last) >= 30 * 86_400 else { return }
        let waiting = Staged.older(than: 30).count
        guard waiting > 0 else { return }
        notify("\(waiting) photos have waited 30 days in PGDuplicates or PGJunk. Run pixelgraph empty to clear them out.")
        try? Date.now.formatted(.iso8601).write(to: marker, atomically: true, encoding: .utf8)
    }

    /// Hands the close calls to Claude Code or Codex, running here with
    /// PixelGraph's tools (deleting switched off). Through a login shell, so
    /// the assistant is found on the same PATH as in Terminal.
    private func ask(_ assistant: String, closeCalls: Int) -> Int32 {
        let me = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        let prompt = """
            PixelGraph's nightly run left \(closeCalls) groups of near-identical photos that need a judgement call. \
            Use the pixelgraph tools with workspace "nightly": list_groups, then show_photos for each group, \
            set_pick where the best shot should change or where two photos are genuinely different moments worth keeping, \
            then move with destination "duplicates" and dry_run false. Never delete. Finish with a two-line summary.
            """
        let server: JSON = ["command": me, "args": ["mcp", "--no-trash"]]
        let config = Agent.json(["mcpServers": ["pixelgraph": server]])
        let tools = ["list_groups", "show_photos", "set_pick", "move"].map { "mcp__pixelgraph__\($0)" }.joined(separator: ",")
        let command: String
        var extra: [String: String] = [:]
        switch assistant {
        case "claude":
            command = #"claude -p "$PG_PROMPT" --mcp-config "$PG_MCP" --allowedTools "$PG_TOOLS""#
        case "opencode":
            // OpenCode reads an extra config file named by OPENCODE_CONFIG, on top of
            // your own (which says which model, e.g. a local one through Ollama).
            let config = Paths.nightly.appendingPathComponent("opencode.json")
            let local: JSON = ["type": "local", "command": [me, "mcp", "--no-trash"], "enabled": true]
            try? Agent.json(["mcp": ["pixelgraph": local]]).write(to: config, atomically: true, encoding: .utf8)
            extra["OPENCODE_CONFIG"] = config.path
            command = #"opencode run "$PG_PROMPT""#
        default:
            command = #"codex exec -c "mcp_servers.pixelgraph.command=\"$PG_ME\"" -c 'mcp_servers.pixelgraph.args=["mcp","--no-trash"]' "$PG_PROMPT""#
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        var environment = ProcessInfo.processInfo.environment
        environment["PG_PROMPT"] = prompt
        environment["PG_MCP"] = config
        environment["PG_TOOLS"] = tools
        environment["PG_ME"] = me
        environment.merge(extra) { _, new in new }
        process.environment = environment
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            print("Couldn't start \(assistant): \(error.localizedDescription)")
            return -1
        }
    }

    private func notify(_ message: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "on run argv", "-e", "display notification (item 1 of argv) with title \"PixelGraph\"",
                             "-e", "end run", message]
        try? process.run()
        process.waitUntilExit()
    }
}

/// `pixelgraph schedule`: runs `pixelgraph auto` every night through launchd.
struct Schedule: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run the nightly clean-up automatically, or stop it.")

    @Option(help: "Time of day, 24-hour.")
    var at = "02:00"

    @Option(help: "Look at photos taken in the last this many days.")
    var days = 30

    @Option(help: "Let an assistant settle the close calls: claude, codex or opencode.")
    var assistant: String?

    @Option(help: "Ask a local vision model through Ollama about close calls and junk, e.g. qwen2.5vl:32b.")
    var judgeModel: String?

    @Flag(help: "Run it once right now as well, so macOS can ask for Photos access while you're here.")
    var now = false

    @Flag(help: "Stop running nightly.")
    var off = false

    static let label = "dev.pixelgraph.nightly"

    func validate() throws {
        if let assistant, !Auto.assistants.contains(assistant) { throw ValidationError("--assistant is claude, codex or opencode.") }
        guard parse(at) != nil else { throw ValidationError("Give the time as HH:MM, e.g. 02:00.") }
    }

    private func parse(_ time: String) -> (hour: Int, minute: Int)? {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
        return (parts[0], parts[1])
    }

    func run() throws {
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(Self.label).plist")
        let domain = "gui/\(getuid())"
        launchctl(["bootout", "\(domain)/\(Self.label)"])
        if off {
            try? FileManager.default.removeItem(at: plist)
            print("The nightly clean-up is off.")
            return
        }
        guard let time = parse(at), let me = Bundle.main.executableURL?.path else { return }
        try FileManager.default.createDirectory(at: Paths.nightly, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        var arguments = [me, "auto", "--days", String(days)]
        if let assistant { arguments += ["--assistant", assistant] }
        if let judgeModel { arguments += ["--judge-model", judgeModel] }
        let log = Paths.nightly.appendingPathComponent("auto.log").path
        let job: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": arguments,
            "StartCalendarInterval": ["Hour": time.hour, "Minute": time.minute],
            "StandardOutPath": log,
            "StandardErrorPath": log,
            "ProcessType": "Background",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
        try data.write(to: plist, options: .atomic)
        guard launchctl(["bootstrap", domain, plist.path]) == 0 else {
            throw ValidationError("launchctl couldn't load \(plist.path).")
        }
        if now { launchctl(["kickstart", "-k", "\(domain)/\(Self.label)"]) }
        print("""
            PixelGraph will tidy up every night at \(String(format: "%02d:%02d", time.hour, time.minute)): \
            clear duplicates from the last \(days) days go to PGDuplicates; nothing is deleted.
            Close calls wait in the nightly scan\(assistant.map { " for \($0)" } ?? ""). Log: \(log)
            The first run needs Photos access for pixelgraph itself: run with --now while you're at the Mac and allow it.
            Stop with `pixelgraph schedule --off`.
            """)
    }

    @discardableResult
    private func launchctl(_ arguments: [String]) -> Int32 {
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

/// `pixelgraph empty`: deletes what has waited in PGDuplicates and PGJunk for
/// a month, after asking. Photos go to Recently Deleted (recoverable for 30
/// days), files to the Trash. Anything you've taken back out of those albums
/// or folders since is left alone.
struct Empty: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Clear out PGDuplicates and PGJunk after they've waited a while (asks first).")

    @Option(help: "Only what has waited at least this many days.")
    var olderThan = 30

    @Flag(help: "Don't ask; for scripts.")
    var yes = false

    func run() async throws {
        let entries = Staged.older(than: olderThan)
        var photos: [String] = [], files: [URL] = [], gone: [String] = []
        let library = entries.filter { !$0.id.hasPrefix("file:") }
        if !library.isEmpty {
            try await Library.requestAccess()
            // Still in the album it was moved to? Then it's still meant to go.
            for (place, group) in Dictionary(grouping: library, by: \.place) {
                let members = Library.album(named: place).map { Set(Library.assetIDs(in: $0)) } ?? []
                for entry in group { if members.contains(entry.id) { photos.append(entry.id) } else { gone.append(entry.id) } }
            }
        }
        for entry in entries where entry.id.hasPrefix("file:") {
            let url = URL(fileURLWithPath: String(entry.id.dropFirst(5)))
            if FileManager.default.fileExists(atPath: url.path) { files.append(url) } else { gone.append(entry.id) }
        }
        Staged.remove(gone)
        guard !photos.isEmpty || !files.isEmpty else {
            print("Nothing has waited \(olderThan) days in PGDuplicates or PGJunk.")
            return
        }
        print("\(photos.count) photos (Photos library) and \(files.count) files have waited \(olderThan)+ days in PGDuplicates or PGJunk.")
        print("Photos go to Recently Deleted for 30 days; files go to the Trash.")
        if !yes {
            print("Delete them? [y/N] ", terminator: "")
            guard let answer = readLine()?.lowercased(), answer == "y" || answer == "yes" else {
                print("Nothing deleted.")
                return
            }
        }
        if !photos.isEmpty { try await Library.delete(photos) }
        var trashed: [String] = []
        for url in files where (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil {
            trashed.append("file:" + url.path)
        }
        Staged.remove(photos + trashed)
        print("Deleted \(photos.count) photos and \(trashed.count) files.")
    }
}
