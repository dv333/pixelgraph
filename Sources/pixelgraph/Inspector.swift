import CoreGraphics
import Foundation
import FoundationModels

/// Spots photos worth rejecting (closed eyes, a blocked face, a cut-off
/// head) so `pixelgraph review` can suggest them. Only suggestions: the user confirms.
enum Inspector {
    /// Bump when the inspection changes so cached results are redone.
    static let version = 1

    /// Reject reasons, in the order `pixelgraph review` offers them (keys 1–9).
    static let reasons = ["eyes closed", "looking away", "face blocked", "blurry", "motion blur",
                          "bad exposure", "smudged lens", "bad framing", "other"]

    @Generable
    enum Problem: Equatable {
        case none, eyesClosed, faceBlocked, blurry, cutOff

        var reason: String? {
            switch self {
            case .none: nil
            case .eyesClosed: "eyes closed"
            case .faceBlocked: "face blocked"
            case .blurry: "blurry"
            case .cutOff: "bad framing"
            }
        }
    }

    @Generable
    struct Finding {
        @Guide(description: """
            The most obvious problem, or none. eyesClosed: someone's eyes are shut or mid-blink. \
            faceBlocked: a face is hidden by a hand, object, hair or another person. \
            blurry: the people are out of focus or motion-blurred. \
            cutOff: a person's head or face is cut off by the edge of the frame. \
            Answer none unless the problem is clear.
            """)
        var problem: Problem
    }

    /// Suggested reject reason for a photo of people from Apple's on-device
    /// model, or nil when it looks fine or there's no model. Without the model,
    /// `compare` still catches closed eyes and turned heads.
    static func inspect(_ image: CGImage, analysis: Analysis, useModel: Bool) async -> String? {
        guard useModel, let problem = await askModel(image) else { return nil }
        return problem.reason
    }

    // MARK: - Against the rest of the group

    /// Problems that only show next to the other shots: someone's eyes shut
    /// when they're open in another frame, a head turned away when it faces
    /// the camera elsewhere, the subject much softer than in the sharpest
    /// shot, poor exposure, a smudged lens. One reason per photo, worst first.
    static func compare(_ group: [Photo]) -> [String: String] {
        guard group.count > 1 else { return [:] }
        var problems: [String: String] = [:]
        func flag(_ i: Int, _ reason: String) { if problems[group[i].id] == nil { problems[group[i].id] = reason } }

        // The same person across shots: faces matched by where they are,
        // starting from the shot with the most faces.
        if let reference = group.indices.max(by: { group[$0].analysis.faces.count < group[$1].analysis.faces.count }) {
            for face in group[reference].analysis.faces {
                let track: [(Int, FaceDetail)] = group.indices.compactMap { i in
                    let reach = max(face.width, face.height) * 0.75
                    let near = group[i].analysis.faces.min { distance($0, face) < distance($1, face) }
                    return near.flatMap { distance($0, face) < reach ? (i, $0) : nil }
                }
                guard track.count > 1 else { continue }
                let widest = track.map { $0.1.eyes }.max() ?? -1
                for (i, f) in track where widest >= 0.15 && f.eyes >= 0 && f.eyes < 0.6 * widest { flag(i, "eyes closed") }
                let facing = track.contains { abs($0.1.yaw) < 12 }
                for (i, f) in track where facing && abs(f.yaw) > 30 { flag(i, "looking away") }
            }
        }

        let raws = Picker.raws(group)
        let sharpest = raws.map(\.sharpness).max() ?? 0
        for i in group.indices where sharpest > 0 && raws[i].sharpness < 0.35 * sharpest {
            flag(i, (group[i].quality?.motion ?? 0) >= 0.5 ? "motion blur" : "blurry")
        }
        for i in group.indices {
            guard let q = group[i].quality else { continue }
            if badlyExposed(q) && !group.allSatisfy({ $0.quality.map(badlyExposed) ?? false }) { flag(i, "bad exposure") }
            if q.smudge >= 0.9 && group.contains(where: { ($0.quality?.smudge ?? 1) < 0.5 }) { flag(i, "smudged lens") }
        }
        return problems
    }

    private static func distance(_ a: FaceDetail, _ b: FaceDetail) -> Float {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }

    static func badlyExposed(_ q: Quality) -> Bool {
        (q.luma < 0.08 && q.dark > 0.5) || q.bright > 0.3
    }

    // MARK: - On their own

    /// Photos with no near-identical shot that still look like rejects:
    /// nearly black, blown out, shot through a smudged lens, or among the
    /// blurriest in this scan and poorly rated by Vision. `all` is every
    /// photo scanned, so "blurry" adapts to the library.
    static func rejects(_ photos: [Photo], among all: [Photo], blurShare: Float = 0.05) -> [String: String] {
        let focus = all.compactMap { $0.quality?.netFocus }.sorted()
        let blurFloor = focus.isEmpty ? 0 : focus[Int(Float(focus.count - 1) * min(max(blurShare, 0), 1))]
        var found: [String: String] = [:]
        for photo in photos where !photo.isScreenshot && !photo.analysis.isUtility {
            guard let q = photo.quality else { continue }
            if (q.luma < 0.06 && q.dark > 0.6) || q.bright > 0.5 {
                found[photo.id] = "bad exposure"
            } else if q.smudge >= 0.9 {
                found[photo.id] = "smudged lens"
            } else if q.netFocus <= blurFloor && photo.analysis.aesthetic < -0.2 {
                found[photo.id] = q.motion >= 0.5 ? "motion blur" : "blurry"
            }
        }
        return found
    }

    /// nil when the model declines or fails.
    private static func askModel(_ image: CGImage) async -> Problem? {
        let session = LanguageModelSession(instructions: """
            You check photos of people for problems that make a shot worse than \
            its near-identical alternatives. Be strict: report a problem only when it is clearly visible.
            """)
        do {
            let response = try await session.respond(generating: Finding.self) {
                "Does this photo have a clear problem?"
                Attachment(image).label("photo")
            }
            return response.content.problem
        } catch {
            return nil
        }
    }
}
