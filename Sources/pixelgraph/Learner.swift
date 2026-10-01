import ArgumentParser
import Foundation

/// What you decided in review, kept across scans: which shot you made ★,
/// what you kept and what you moved. PixelGraph measures itself against it
/// (`pixelgraph eval`) and learns which measures matter to you.
enum Decisions {
    struct Entry: Codable {
        var date: Date
        var kind: Run.Group.Kind
        var members: [Run.Member]
        /// PixelGraph's own pick; nil for Junk and older scans.
        var suggested: String?
        /// Your ★ shots.
        var chosen: [String]
        /// Everything you kept, ★ included.
        var kept: [String]
        /// Moved, or selected to move when you left the review.
        var moving: [String]
        /// PixelGraph's reject flags, and the reasons you gave.
        var suggestions: [String: String]
        var reasons: [String: String]
    }

    static var file: URL { Paths.root.appendingPathComponent("decisions.json") }

    static func load() -> [String: Entry] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: Entry].self, from: data)) ?? [:]
    }

    /// Saves the groups you've opened, replacing what was saved for the same photos.
    static func record(_ run: Run) {
        var entries = load()
        for group in run.groups + (run.junkGroups ?? []) where group.reviewed == true {
            let ids = group.photos.map(\.id)
            entries[ids.sorted().joined(separator: "|")] = Entry(
                date: run.date, kind: group.kind, members: group.photos, suggested: group.pick.suggested,
                chosen: group.pick.keepers, kept: ids.filter { group.pick.isKept($0) },
                moving: ids.filter { !group.pick.isKept($0) }, suggestions: group.pick.suggestions, reasons: group.pick.reasons)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(entries).write(to: file, options: .atomic)
    }
}

/// Shifts the pick's weights toward the shots you choose: every reviewed
/// group says "this ★ beats each photo I moved", and a logistic fit on those
/// differences finds weights that agree with you, held near the standard
/// ones so a few odd choices can't take over.
enum Learner {
    /// Reviewed groups needed before learned weights are used.
    static let minimumGroups = 10

    /// Fits weights to your decisions and saves them; the standard weights
    /// until there's enough to learn from.
    static func refresh() -> Picker.Weights {
        let entries = Array(Decisions.load().values)
        let diffs = differences(entries)
        guard entries.filter({ !$0.chosen.isEmpty && !$0.moving.isEmpty && $0.kind != .junk }).count >= minimumGroups
        else { return .standard }
        let weights = fit(diffs)
        try? weights.save()
        return weights
    }

    /// The measures of a reviewed group, as the pick sees them.
    static func scores(_ entry: Decisions.Entry, weights: Picker.Weights) -> [Picker.Score] {
        Picker.score(Picker.raws(entry.members), weights: weights)
    }

    /// Feature differences, ★ minus each moved photo.
    static func differences(_ entries: [Decisions.Entry]) -> [[Double]] {
        entries.filter { $0.kind != .junk }.flatMap { entry -> [[Double]] in
            let scored = scores(entry, weights: .standard)
            let index = Dictionary(uniqueKeysWithValues: entry.members.enumerated().map { ($1.id, $0) })
            return entry.chosen.compactMap { index[$0] }.flatMap { best in
                entry.moving.compactMap { index[$0] }.map { other in
                    zip(Picker.features(scored[best]), Picker.features(scored[other])).map { $0 - $1 }
                }
            }
        }
    }

    static func fit(_ diffs: [[Double]], from start: Picker.Weights = .standard) -> Picker.Weights {
        guard !diffs.isEmpty else { return start }
        let w0 = start.vector
        var w = w0
        let sharpness = 10.0, rate = 0.5, pull = 0.05
        for _ in 0..<300 {
            var gradient = w.indices.map { pull * (w[$0] - w0[$0]) }
            for x in diffs {
                let z = sharpness * zip(w, x).map(*).reduce(0, +)
                let miss = 1 / (1 + exp(z))  // how wrong: 0 when the ★ clearly wins
                for k in w.indices { gradient[k] -= sharpness * miss * x[k] / Double(diffs.count) }
            }
            w = w.indices.map { max(0.01, w[$0] - rate * gradient[$0]) }
        }
        let scale = w0.reduce(0, +) / w.reduce(0, +)
        return Picker.Weights(w.map { $0 * scale })
    }
}

/// `pixelgraph eval`: how PixelGraph's groups, picks and reject flags
/// compare with what you decided in review.
struct Eval: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Measure PixelGraph against your past review decisions.")

    @Option(help: "Also test a local vision model through Ollama against your decisions, e.g. qwen2.5vl:32b.")
    var judgeModel: String?

    @Option(help: "The confidence the nightly run would require (0–1).")
    var judgeConfidence = 0.85

    @Option(help: "Test on at most this many reviewed groups (each takes a few seconds).")
    var limit = 40

    func run() async throws {
        Swift.print(Self.report())
        if let judgeModel {
            Swift.print("\n" + (try await Self.judgeReport(Judge(model: judgeModel), threshold: judgeConfidence, limit: limit)))
        }
    }

    /// How the local model's picks compare with yours, and what the nightly
    /// rule (model and PixelGraph agree, confidently) would have done.
    static func judgeReport(_ judge: Judge, threshold: Double, limit: Int) async throws -> String {
        let entries = Decisions.load().values
            .filter { $0.kind != .junk && $0.suggested != nil && !$0.chosen.isEmpty && (2...6).contains($0.members.count) }
            .sorted { $0.date > $1.date }
        let junk = Decisions.load().values.filter { $0.kind == .junk }
        if entries.contains(where: { !$0.members[0].id.hasPrefix("file:") }) || junk.contains(where: { !$0.members[0].id.hasPrefix("file:") }) {
            try await Library.requestAccess()
        }
        var tested = 0, modelRight = 0, pixelgraphRight = 0, autoMoved = 0, autoRight = 0
        for entry in entries.prefix(limit) {
            guard let images = await Judge.images(entry.members) else { continue }
            let choice = try await judge.choose(images)
            guard let pick = try? Agent.photoIndexIn(entry.members, choice.best) else { continue }
            tested += 1
            let modelID = entry.members[pick].id
            if entry.chosen.contains(modelID) { modelRight += 1 }
            if entry.chosen.contains(entry.suggested!) { pixelgraphRight += 1 }
            if modelID == entry.suggested, choice.confidence >= threshold {
                autoMoved += 1
                if entry.chosen.contains(modelID) { autoRight += 1 }
            }
        }
        var junkTested = 0, junkCalled = 0, junkRight = 0
        for entry in junk {
            for member in entry.members where junkTested < limit {
                guard let image = await Judge.images([member])?.first else { continue }
                let verdict = try await judge.judgeJunk(image)
                junkTested += 1
                if verdict.junk, verdict.confidence >= threshold {
                    junkCalled += 1
                    if entry.moving.contains(member.id) { junkRight += 1 }
                }
            }
        }
        func percent(_ part: Int, _ whole: Int) -> String {
            whole == 0 ? "–" : String(format: "%3.0f%%  (%ld of %ld)", 100 * Double(part) / Double(whole), part, whole)
        }
        var lines = ["Local model: \(judge.model), needing \(Int(threshold * 100))% confidence"]
        guard tested + junkTested > 0 else {
            return (lines + ["  Nothing to test yet: review some groups first."]).joined(separator: "\n")
        }
        lines += [
            "  Groups tested                             \(tested)",
            "  model's pick was your ★                   " + percent(modelRight, tested),
            "  PixelGraph's pick was your ★              " + percent(pixelgraphRight, tested),
            "  nightly would settle on its own           " + percent(autoMoved, tested),
            "    …and matched you                        " + percent(autoRight, autoMoved),
        ]
        if junkTested > 0 {
            lines += [
                "  Junk photos tested                        \(junkTested)",
                "  model called junk (would move)            " + percent(junkCalled, junkTested),
                "    …and you moved it too                   " + percent(junkRight, junkCalled),
            ]
        }
        let ok = autoMoved == 0 || Double(autoRight) / Double(autoMoved) >= 0.95
        lines.append(ok ? "  Safe enough for the nightly run: pixelgraph schedule --judge-model \(judge.model)"
                        : "  Not yet trustworthy for the nightly run; try a larger model or a higher --judge-confidence.")
        return lines.joined(separator: "\n")
    }

    /// The whole evaluation as text, for the terminal and for assistants.
    static func report() -> String {
        var lines: [String] = []
        func print(_ line: String) { lines.append(line) }
        let entries = Array(Decisions.load().values)
        let groups = entries.filter { $0.kind != .junk }
        let junk = entries.filter { $0.kind == .junk }
        guard !entries.isEmpty else {
            return "No reviewed groups yet. Open some groups in `pixelgraph review`, then try again."
        }
        func percent(_ part: Int, _ whole: Int) -> String {
            whole == 0 ? "–" : String(format: "%3.0f%%  (%ld of %ld)", 100 * Double(part) / Double(whole), part, whole)
        }

        print("Groups you reviewed: \(groups.count)\n")
        print("Grouping")
        let keptAll = groups.filter { $0.moving.isEmpty }.count
        print("  kept every photo (not really duplicates)  " + percent(keptAll, groups.count))
        print("  kept more than one                        " + percent(groups.filter { $0.kept.count > 1 }.count, groups.count))

        print("\nBest shot")
        let judged = groups.filter { $0.suggested != nil && !$0.chosen.isEmpty }
        print("  PixelGraph's pick was your ★              " + percent(judged.filter { $0.chosen.contains($0.suggested!) }.count, judged.count))
        func replay(_ weights: Picker.Weights) -> Int {
            judged.filter { entry in
                let scores = Learner.scores(entry, weights: weights)
                guard let top = scores.indices.max(by: { scores[$0].total < scores[$1].total }) else { return false }
                return entry.chosen.contains(entry.members[top].id)
            }.count
        }
        print("  scores alone, standard weights            " + percent(replay(.standard), judged.count))
        let learned = Learner.fit(Learner.differences(entries))
        print("  scores alone, weights learned from you    " + percent(replay(learned), judged.count))
        print(String(format: "  learned weights: look %.2f · sharpness %.2f · faces %.2f · resolution %.2f · exposure %.2f",
                     learned.aesthetic, learned.sharpness, learned.faces, learned.resolution, learned.exposure))
        if judged.count < Learner.minimumGroups {
            print("  (used for picks after \(Learner.minimumGroups) reviewed groups)")
        }

        print("\nReject flags")
        let flagged = groups.flatMap { e in e.suggestions.keys.map { (e, $0) } }
        print("  flagged photos you moved                  " + percent(flagged.filter { $0.0.moving.contains($0.1) }.count, flagged.count))
        let moved = groups.flatMap { e in e.moving.map { (e, $0) } }
        print("  moved photos PixelGraph had flagged       " + percent(moved.filter { $0.0.suggestions[$0.1] != nil }.count, moved.count))
        var byReason: [String: (moved: Int, total: Int)] = [:]
        for (entry, id) in flagged {
            let reason = entry.suggestions[id]!
            byReason[reason, default: (0, 0)].total += 1
            if entry.moving.contains(id) { byReason[reason, default: (0, 0)].moved += 1 }
        }
        for (reason, counts) in byReason.sorted(by: { $0.key < $1.key }) {
            print("    " + reason.padding(toLength: 40, withPad: " ", startingAt: 0) + percent(counts.moved, counts.total))
        }

        if !junk.isEmpty {
            print("\nJunk")
            let photos = junk.flatMap(\.members).count
            print("  junk photos you moved                     " + percent(junk.flatMap(\.moving).count, photos))
        }
        print("\nMissed duplicates can't be measured from reviews: only groups PixelGraph found are here.")
        return lines.joined(separator: "\n")
    }
}
