import CoreGraphics
import Foundation
import FoundationModels
@preconcurrency import Photos
import Vision

/// Photos worth throwing away though nothing else looks like them:
/// accidental shots (pocket, floor, ceiling, nothing in the frame), blurry
/// or crooked ones, old screenshots, and images forwarded from chats.
///
/// Balanced on purpose: one strong sign (nearly black, smudged, among the
/// very blurriest, an old screenshot) is enough; otherwise two weaker signs
/// must agree, and Apple's on-device model, when there is one, gets the
/// last word on those. Having no face is never a sign by itself.
enum Junk {
    /// Bump when the measures change so cached ones are redone.
    static let version = 1

    /// What Vision sees in a photo that already looks weak. Cached per photo.
    struct Signals: Codable, Sendable, Equatable {
        /// Vision's top scene labels.
        var labels: [String]
        /// Area of the largest thing that stands out, 0 … 1; near 0 when nothing does.
        var subject: Float
        /// Horizon tilt in degrees, when there's a horizon.
        var tilt: Float?
    }

    struct Context {
        /// Focus of the blurriest 5% and 15% of this scan, so "blurry" adapts to the library.
        var blurFloor: Float
        var softFloor: Float
        var screenshotDays: Int
        var now: Date
    }

    /// Plain surfaces: what a pocket, the floor or a ceiling looks like.
    static let surfaces: Set<String> = [
        "floor", "ceiling", "carpet", "rug", "textile", "fabric", "wall", "concrete", "asphalt", "pavement", "tile", "wood_processed",
    ]
    /// File names messaging apps give the images they save.
    static let forwardedNames = ["-wa", "whatsapp", "fb_img", "received_", "telegram", "signal-", "messenger", "snapchat", "downloaded"]

    /// The order the Junk tab lists reasons in.
    static let order = ["accidental shot", "blurry", "motion blur", "crooked", "bad exposure", "smudged lens",
                        "old screenshot", "forwarded image", "low quality"]

    static func context(_ all: [Photo], screenshotDays: Int, now: Date = .now) -> Context {
        let focus = all.compactMap { $0.quality?.netFocus }.sorted()
        func percentile(_ p: Float) -> Float { focus.isEmpty ? 0 : focus[Int(Float(focus.count - 1) * p)] }
        return Context(blurFloor: percentile(0.05), softFloor: percentile(0.15), screenshotDays: screenshotDays, now: now)
    }

    /// Worth the extra Vision checks: photos that already look weak in some way.
    static func worthALook(_ photo: Photo, _ context: Context) -> Bool {
        guard !photo.isScreenshot, !photo.analysis.isUtility else { return false }
        if photo.analysis.aesthetic < 0 { return true }
        if let q = photo.quality, q.netFocus <= context.softFloor { return true }
        return max(photo.width, photo.height) <= 1600
    }

    static func measure(_ image: CGImage) async -> Signals {
        var signals = Signals(labels: [], subject: 0, tilt: nil)
        let handler = ImageRequestHandler(image)
        if let labels = try? await handler.perform(ClassifyImageRequest()) {
            signals.labels = labels.filter { $0.confidence >= 0.3 }.sorted { $0.confidence > $1.confidence }.prefix(5).map(\.identifier)
        }
        if let saliency = try? await handler.perform(GenerateObjectnessBasedSaliencyImageRequest()) {
            signals.subject = Float(saliency.salientObjects.map { $0.boundingBox.width * $0.boundingBox.height }.max() ?? 0)
        }
        if let horizon = try? await handler.perform(DetectHorizonRequest()) {
            signals.tilt = Float(horizon.angle.converted(to: .degrees).value)
        }
        return signals
    }

    /// The name the photo came in with: the original file name in Photos,
    /// the file name for folders. Lower-cased.
    static func origin(_ item: Item) -> String {
        switch item.backing {
        case .photo(let asset): return PHAssetResource.assetResources(for: asset).first?.originalFilename.lowercased() ?? ""
        case .file(let url): return url.lastPathComponent.lowercased()
        }
    }

    /// Why a photo looks like junk, and whether that's sure or needs a second
    /// opinion; nil when it looks fine. `strong` is a sure reason found already.
    static func judge(_ photo: Photo, origin: String, signals: Signals?, strong: String?, _ context: Context) -> (reason: String, sure: Bool)? {
        if let strong { return (strong, true) }
        if photo.isScreenshot {
            let days = context.now.timeIntervalSince(photo.date) / 86_400
            return days > Double(context.screenshotDays) ? ("old screenshot", true) : nil
        }
        guard !photo.analysis.isUtility else { return nil }
        var signs: [String] = []
        if let q = photo.quality, q.netFocus <= context.softFloor { signs.append(q.motion >= 0.5 ? "motion blur" : "blurry") }
        if photo.analysis.aesthetic < -0.3 { signs.append("low quality") }
        if let s = signals {
            // A face means someone meant to take it.
            if photo.analysis.faceCount == 0, s.subject < 0.02 || !Set(s.labels).isDisjoint(with: surfaces) { signs.append("accidental shot") }
            if let tilt = s.tilt, (6...35).contains(abs(tilt)) { signs.append("crooked") }
        }
        // Small and named by a messaging app: a forward, which counts twice.
        let small = max(photo.width, photo.height) <= 1600 && photo.pixels < 2_000_000
        if small, forwardedNames.contains(where: { origin.contains($0) }) { signs += ["forwarded image", "forwarded image"] }
        guard signs.count >= 2 else { return nil }
        let reason = ["forwarded image", "accidental shot", "crooked", "motion blur", "blurry"].first(where: signs.contains) ?? "low quality"
        return (reason, false)
    }

    @Generable
    struct Verdict {
        @Guide(description: "true if someone would want to keep this photo; false for an accidental shot, a blurry mistake, or a meme or forward nobody would miss")
        var keep: Bool
    }

    /// Apple's on-device model's second opinion: true to keep. Nil when it can't say.
    static func worthKeeping(_ image: CGImage) async -> Bool? {
        let session = LanguageModelSession(instructions: """
            You help someone clear out their camera roll. Say whether a photo is worth keeping. \
            Keep anything with meaning: people, places, pets, food, things someone photographed on purpose, \
            even if imperfect. Only call it junk when it's clearly a mistake or clutter.
            """)
        do {
            return try await session.respond(generating: Verdict.self) {
                "Is this photo worth keeping?"
                Attachment(image).label("photo")
            }.content.keep
        } catch {
            return nil
        }
    }
}
