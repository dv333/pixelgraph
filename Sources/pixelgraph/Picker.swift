import CoreGraphics
import Foundation
import FoundationModels

/// What happens to each photo in a group. Every photo is either kept or
/// moved to Duplicates; by default everything but cull's pick is moved.
struct Pick: Codable, Sendable {
    /// PixelGraph's pick, or the first photo marked best.
    var best: String
    /// "vision" when the scores were clear, "apple-model" when the
    /// on-device model broke a close call, "you" after `pixelgraph review`.
    var decidedBy: String
    /// PixelGraph's note on every photo ("sharpest", "blurrier"…).
    var notes: [String: String]
    /// ★ Best: kept, and the reason the group exists.
    var keepers: [String]
    /// Also kept, though not the best.
    var kept: [String]
    /// Reasons chosen for photos being moved (eyes closed, blurry…).
    var reasons: [String: String]
    /// Problems PixelGraph spotted; those photos start out selected to move.
    var suggestions: [String: String]
    /// Already in the Duplicates album or folder.
    var moved: [String]

    init(best: String, decidedBy: String, notes: [String: String], suggestions: [String: String] = [:]) {
        self.best = best
        self.decidedBy = decidedBy
        self.notes = notes
        self.keepers = [best]
        self.kept = []
        self.reasons = [:]
        self.suggestions = suggestions
        self.moved = []
    }

    func isKept(_ id: String) -> Bool { keepers.contains(id) || kept.contains(id) }
    func willMove(_ id: String) -> Bool { !isKept(id) && !moved.contains(id) }

    /// Why a photo is moving: your reason, else PixelGraph's suggestion, else its note.
    func reason(_ id: String) -> String? { reasons[id] ?? suggestions[id] ?? notes[id] }

    private enum CodingKeys: String, CodingKey {
        case best, decidedBy, notes, keepers, kept, reasons, suggestions, moved
        case rejects  // older scans
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        best = try c.decode(String.self, forKey: .best)
        decidedBy = try c.decode(String.self, forKey: .decidedBy)
        notes = try c.decode([String: String].self, forKey: .notes)
        keepers = try c.decodeIfPresent([String].self, forKey: .keepers) ?? [best]
        kept = try c.decodeIfPresent([String].self, forKey: .kept) ?? []
        reasons = try c.decodeIfPresent([String: String].self, forKey: .reasons)
            ?? c.decodeIfPresent([String: String].self, forKey: .rejects) ?? [:]
        suggestions = try c.decodeIfPresent([String: String].self, forKey: .suggestions) ?? [:]
        moved = try c.decodeIfPresent([String].self, forKey: .moved) ?? []
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(best, forKey: .best)
        try c.encode(decidedBy, forKey: .decidedBy)
        try c.encode(notes, forKey: .notes)
        try c.encode(keepers, forKey: .keepers)
        try c.encode(kept, forKey: .kept)
        try c.encode(reasons, forKey: .reasons)
        try c.encode(suggestions, forKey: .suggestions)
        try c.encode(moved, forKey: .moved)
    }
}

enum Picker {
    /// Scores closer than this count as a tie and go to the model.
    static let tieMargin: Double = 0.04

    /// `problems` are suggested rejects by photo id; a flagged photo is only
    /// picked when every photo in the group is flagged.
    static func pick(_ group: [Photo], useModel: Bool, problems: [String: String] = [:],
                     load: @Sendable (String) async -> CGImage? = { _ in nil }) async -> Pick {
        let scored = score(group)
        let ranked = group.indices.sorted {
            let (a, b) = (problems[group[$0].id] == nil, problems[group[$1].id] == nil)
            return a != b ? a : scored[$0].total > scored[$1].total
        }
        var best = ranked[0]
        var decidedBy = "vision"
        var modelReason: String?

        let contenders = ranked.prefix(4).filter {
            scored[ranked[0]].total - scored[$0].total < tieMargin
                && (problems[group[$0].id] == nil) == (problems[group[ranked[0]].id] == nil)
        }
        if useModel, contenders.count > 1, let images = await images(contenders.map { group[$0].id }, load),
           let verdict = await askModel(images) {
            best = contenders[verdict.index]
            decidedBy = "apple-model"
            modelReason = verdict.reason
        }

        var notes: [String: String] = [:]
        for i in group.indices {
            notes[group[i].id] = i == best
                ? modelReason ?? strengths(of: i, in: scored)
                : weakness(of: i, against: best, in: scored, group: group)
        }
        return Pick(best: group[best].id, decidedBy: decidedBy, notes: notes,
                    suggestions: problems.filter { id, _ in group.contains { $0.id == id } })
    }

    // MARK: - Vision scores

    struct Score {
        var aesthetic: Double   // 0 … 1
        var sharpness: Double   // 0 … 1, relative to the sharpest in the group
        var faces: Double?      // 0 … 1, nil when the group has no faces
        var resolution: Double  // 0 … 1, relative to the largest in the group
        var total: Double
    }

    static func score(_ group: [Photo]) -> [Score] {
        let maxSharp = Double(group.map(\.analysis.sharpness).max() ?? 0)
        let maxPixels = Double(group.map(\.pixels).max() ?? 0)
        let hasFaces = group.contains { $0.analysis.faceCount > 0 }
        return group.map { photo in
            let a = photo.analysis
            let aesthetic = (Double(a.aesthetic) + 1) / 2
            let sharpness = maxSharp > 0 ? (Double(a.sharpness) / maxSharp).squareRoot() : 1
            let resolution = maxPixels > 0 ? Double(photo.pixels) / maxPixels : 1
            let faces: Double? = hasFaces ? Double(max(0, a.faceQuality)) : nil
            let total = faces.map { 0.35 * aesthetic + 0.25 * sharpness + 0.3 * $0 + 0.1 * resolution }
                ?? 0.55 * aesthetic + 0.35 * sharpness + 0.1 * resolution
            return Score(aesthetic: aesthetic, sharpness: sharpness, faces: faces, resolution: resolution, total: total)
        }
    }

    private static func strengths(of i: Int, in scores: [Score]) -> String {
        func isTop(_ value: (Score) -> Double?) -> Bool {
            guard let mine = value(scores[i]) else { return false }
            // Top, and actually ahead of someone: a tie for first isn't a reason.
            return scores.allSatisfy { (value($0) ?? 0) <= mine + 0.001 }
                && scores.contains { (value($0) ?? 0) < mine - 0.01 }
        }
        var parts: [String] = []
        if isTop(\.faces) { parts.append("best faces") }
        if isTop(\.sharpness) { parts.append("sharpest") }
        if isTop(\.aesthetic) { parts.append("best overall look") }
        if parts.isEmpty, isTop(\.resolution) { parts.append("highest resolution") }
        return parts.isEmpty ? "best balance of sharpness and look" : parts.joined(separator: ", ")
    }

    private static func weakness(of i: Int, against best: Int, in scores: [Score], group: [Photo]) -> String {
        if Grouper.distance(group[i], group[best]) < 0.06 {
            return scores[i].resolution < scores[best].resolution - 0.01 ? "smaller copy" : "near-exact copy"
        }
        let gaps: [(String, Double)] = [
            ("weaker faces (eyes, expression or focus)", (scores[best].faces ?? 0) - (scores[i].faces ?? 0)),
            ("blurrier", scores[best].sharpness - scores[i].sharpness),
            ("weaker overall look", scores[best].aesthetic - scores[i].aesthetic),
            ("lower resolution", (scores[best].resolution - scores[i].resolution) / 2),
        ]
        guard let worst = gaps.max(by: { $0.1 < $1.1 }), worst.1 > 0.02 else { return "nearly as good" }
        return worst.0
    }

    // MARK: - Apple on-device model

    @Generable
    struct Verdict {
        @Guide(description: "Label of the best photo, exactly as given, for example B")
        var best: String
        @Guide(description: "Why it is best, under 12 words, for example: sharpest, both people smiling with eyes open")
        var reason: String
    }

    static var modelAvailable: Bool {
        let model = SystemLanguageModel.default
        return model.availability == .available && model.capabilities.contains(.vision)
    }

    /// Renders for the model; nil if any can't be loaded.
    private static func images(_ ids: [String], _ load: (String) async -> CGImage?) async -> [CGImage]? {
        var images: [CGImage] = []
        for id in ids {
            guard let image = await load(id) else { return nil }
            images.append(image)
        }
        return images
    }

    /// Asks the on-device model which image is best. Returns its index and reason,
    /// or nil when the model declines or answers with an unknown label.
    static func askModel(_ images: [CGImage]) async -> (index: Int, reason: String)? {
        let labels = Array(["A", "B", "C", "D"].prefix(images.count))
        let attachments = zip(labels, images).map { Attachment($1).label($0) }

        let session = LanguageModelSession(instructions: """
            You pick the best keeper from near-identical photos. Prefer: in focus, \
            everyone's eyes open, natural expressions, nobody turned away or cut off, \
            good framing and light. Ignore tiny differences.
            """)
        do {
            let response = try await session.respond(generating: Verdict.self) {
                "These \(images.count) photos, labelled \(labels.joined(separator: ", ")), are near-identical. Which is the best one to keep?"
                attachments
            }
            let answer = response.content.best.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard let index = labels.firstIndex(where: { answer.hasPrefix($0) }) else { return nil }
            return (index, response.content.reason)
        } catch {
            // Guardrails or model errors: keep the Vision pick.
            return nil
        }
    }
}
