import CoreGraphics
import Foundation
import FoundationModels

/// Spots photos worth rejecting (closed eyes, a blocked face, a cut-off
/// head) so `pixelgraph review` can suggest them. Only suggestions: the user confirms.
enum Inspector {
    /// Bump when the inspection changes so cached results are redone.
    static let version = 1

    /// Reject reasons, in the order `pixelgraph review` offers them.
    static let reasons = ["eyes closed", "face blocked", "blurry", "bad framing", "other"]

    /// Eye height ÷ width below this reads as closed. Conservative on purpose:
    /// it's only used when the on-device model can't look.
    static let closedEyes: Float = 0.12

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

    /// Suggested reject reason for a photo of people, or nil when it looks fine.
    static func inspect(_ image: CGImage, analysis: Analysis, useModel: Bool) async -> String? {
        if useModel, let problem = await askModel(image) { return problem.reason }
        if analysis.eyesOpen >= 0, analysis.eyesOpen < closedEyes { return "eyes closed" }
        return nil
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
