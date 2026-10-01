import CoreGraphics
import Foundation
import FoundationModels
import Vision

/// What a photo shows: its text (for documents), what kind of document it
/// is, a one-line description, and scene tags. All on this Mac.
enum Insight {
    /// Bump when any of these change so cached results are redone.
    static let version = 2

    // MARK: Text

    /// The text in a photo, top to bottom, as Vision reads it.
    static func readText(_ image: CGImage) async -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        guard let lines = try? await ImageRequestHandler(image).perform(request) else { return "" }
        return lines.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    /// How alike two documents' text is, 0 … 1: the share of words they have
    /// in common. Two forms from the same template with different names and
    /// numbers score low; two photos of the same page score near 1.
    static func similarity(_ a: String, _ b: String) -> Double {
        let (x, y) = (words(a), words(b))
        guard !x.isEmpty || !y.isEmpty else { return 0 }
        return Double(x.intersection(y).count) / Double(x.union(y).count)
    }

    static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 })
    }

    // MARK: Documents

    @Generable
    enum DocKind: Equatable {
        case receipt, bill, form, letter, idCard, ticket, notes, whiteboard, screenshot, photoOfScreen, otherDocument, notADocument

        var title: String? {
            switch self {
            case .receipt: "Receipt"
            case .bill: "Bill"
            case .form: "Form"
            case .letter: "Letter"
            case .idCard: "ID"
            case .ticket: "Ticket"
            case .notes: "Notes"
            case .whiteboard: "Whiteboard"
            case .screenshot: "Screenshot"
            case .photoOfScreen: "Photo of a screen"
            case .otherDocument: "Document"
            case .notADocument: nil
            }
        }
    }

    @Generable
    struct DocReading {
        var kind: DocKind
        @Guide(description: "What the document is, in at most 6 words, e.g. 'Pier 39 Café receipt' or 'I-797C notice'. No personal names or numbers.")
        var title: String
    }

    struct Document: Codable, Sendable, Equatable {
        var kind: String
        var title: String
        var text: String

        /// "Form · I-797C notice", or just the title when it already says
        /// what it is ("Pier 39 Café receipt").
        var label: String {
            let trimmed = title.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return kind }
            if trimmed.lowercased().contains(kind.lowercased()) { return trimmed.prefix(1).uppercased() + trimmed.dropFirst() }
            return "\(kind) · \(trimmed)"
        }
    }

    /// Decides whether a photo is a document and names it. Only called for
    /// photos Vision marks as utility shots, and for screenshots.
    static func document(_ image: CGImage, isScreenshot: Bool, useModel: Bool) async -> Document? {
        let text = await readText(image)
        let firstLine = text.split(separator: "\n").first.map { String($0.prefix(40)) } ?? ""
        if useModel, let reading = await askModel(image, text: text) {
            guard let kind = reading.kind.title else { return isScreenshot ? Document(kind: "Screenshot", title: firstLine, text: text) : nil }
            // The file system knows a screenshot for certain; keep the model's title.
            return Document(kind: isScreenshot ? "Screenshot" : kind, title: reading.title, text: text)
        }
        if isScreenshot { return Document(kind: "Screenshot", title: firstLine, text: text) }
        return text.count >= 40 ? Document(kind: "Document", title: firstLine, text: text) : nil
    }

    private static func askModel(_ image: CGImage, text: String) async -> DocReading? {
        let session = LanguageModelSession(instructions: """
            You sort photos from someone's camera roll. Decide whether a photo is a document \
            (receipt, bill, form, letter, ID, ticket, notes, whiteboard, screenshot, or a photo \
            taken of a computer or TV screen showing text) or an ordinary photo, and name it briefly.
            """)
        do {
            return try await session.respond(generating: DocReading.self) {
                "Text read from the photo:\n\(String(text.prefix(500)))"
                Attachment(image).label("photo")
            }.content
        } catch {
            return nil
        }
    }

    // MARK: Descriptions and tags

    @Generable
    struct Description {
        @Guide(description: "One plain sentence, at most 12 words: who (never names), what they are doing, where. Don't start with 'This photo'.")
        var sentence: String
    }

    /// A one-line description from Apple's on-device model, or nil.
    static func describe(_ image: CGImage) async -> String? {
        let session = LanguageModelSession(instructions: "You write short, plain descriptions of personal photos.")
        do {
            let response = try await session.respond(generating: Description.self) {
                "Describe this photo."
                Attachment(image).label("photo")
            }
            let sentence = response.content.sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            return sentence.isEmpty ? nil : sentence
        } catch {
            return nil
        }
    }

    /// Scene tags from Vision's built-in classifier: fast, no model needed.
    static func sceneTags(_ image: CGImage, limit: Int = 4) async -> [String] {
        guard let labels = try? await ImageRequestHandler(image).perform(ClassifyImageRequest()) else { return [] }
        let generic: Set<String> = ["people", "adult", "structure", "material", "textile", "clothing", "consumable"]
        return labels
            .filter { $0.confidence >= 0.35 }
            .sorted { $0.confidence > $1.confidence }
            .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
            .filter { !generic.contains($0) }
            .prefix(limit)
            .map { $0 }
    }
}
