import CoreGraphics
import Foundation
import ImageIO

/// A second opinion from a vision model running on this Mac through Ollama
/// (or anything that speaks Ollama's /api/chat). Used by the nightly run for
/// the close calls and borderline junk PixelGraph won't settle alone: the
/// model looks at the photos and answers in a fixed JSON shape. Nothing
/// leaves the Mac.
struct Judge: Sendable {
    /// A good default for 48 GB or more; smaller Macs: qwen2.5vl:7b.
    static let defaultModel = "qwen2.5vl:32b"

    let model: String
    let endpoint: URL

    init(model: String, host: String? = nil) {
        self.model = model
        var base = host ?? ProcessInfo.processInfo.environment["OLLAMA_HOST"] ?? "http://localhost:11434"
        if !base.hasPrefix("http") { base = "http://" + base }
        endpoint = (URL(string: base) ?? URL(string: "http://localhost:11434")!).appendingPathComponent("api/chat")
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Which near-identical photo to keep.
    struct Choice: Decodable, Sendable {
        var best: String
        /// Others that are genuinely different moments worth keeping too.
        var keep: [String]?
        /// 0 … 1: how clearly the best is the best.
        var confidence: Double
        var reason: String
    }

    /// Whether a photo is junk.
    struct Verdict: Decodable, Sendable {
        var junk: Bool
        var confidence: Double
        var reason: String
    }

    private static let instructions = """
        You help someone tidy their own photo library on their Mac. Be careful: keeping a photo \
        by mistake costs nothing, removing a good one is bad. Answer only in the JSON asked for.
        """

    /// The best of near-identical photos, given in order as A, B, C…
    func choose(_ images: [Data]) async throws -> Choice {
        let labels = (0..<images.count).map(Agent.letter)
        let schema: JSON = [
            "type": "object",
            "properties": [
                "best": ["type": "string", "enum": labels] as JSON,
                "keep": ["type": "array", "items": ["type": "string", "enum": labels] as JSON] as JSON,
                "confidence": ["type": "number"],
                "reason": ["type": "string"],
            ] as JSON,
            "required": ["best", "confidence", "reason"],
        ]
        let prompt = """
            These \(images.count) photos, labelled \(labels.joined(separator: ", ")) in order, were taken moments apart \
            and look nearly the same. Which one should be kept? Prefer: in focus, everyone's eyes open, natural \
            expressions, nobody turned away or cut off, good framing and light. In "keep", list any others that \
            show a genuinely different moment worth keeping too (usually none). "confidence" is 0 to 1: how \
            clearly your pick is better than the rest; use below 0.5 when they're about equally good.
            """
        return try await ask(prompt, images: images, schema: schema)
    }

    /// Whether one photo is junk someone would happily delete.
    func judgeJunk(_ image: Data) async throws -> Verdict {
        let schema: JSON = [
            "type": "object",
            "properties": ["junk": ["type": "boolean"], "confidence": ["type": "number"], "reason": ["type": "string"]] as JSON,
            "required": ["junk", "confidence", "reason"],
        ]
        let prompt = """
            Is this photo junk the owner would happily delete: an accidental shot (inside a pocket, the floor, \
            the ceiling), a mistake too blurred to use, a screenshot of nothing lasting, or a forwarded meme? \
            Anything with meaning (people, pets, places, food, something photographed on purpose) is not junk, \
            even if imperfect. "confidence" is 0 to 1.
            """
        return try await ask(prompt, images: [image], schema: schema)
    }

    /// Ollama's /api/chat answer.
    private struct Reply: Decodable {
        struct Message: Decodable { var content: String }
        var message: Message
    }

    private func ask<T: Decodable>(_ prompt: String, images: [Data], schema: JSON) async throws -> T {
        let body: JSON = [
            "model": model,
            "stream": false,
            "format": schema,
            "options": ["temperature": 0],
            "messages": [
                ["role": "system", "content": Self.instructions] as JSON,
                ["role": "user", "content": prompt, "images": images.map { $0.base64EncodedString() }] as JSON,
            ],
        ]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure(message: "Can't reach Ollama at \(endpoint.deletingLastPathComponent().deletingLastPathComponent()). Is it running? (\(error.localizedDescription))")
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else {
            let text = String(decoding: data.prefix(300), as: UTF8.self)
            throw Failure(message: "Ollama said: \(text). Is the model pulled? Try `ollama pull \(model)`.")
        }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        do {
            return try JSONDecoder().decode(T.self, from: Data(reply.message.content.utf8))
        } catch {
            throw Failure(message: "The model's answer wasn't the JSON asked for: \(reply.message.content.prefix(200))")
        }
    }

    /// The photos of a group (in the group's order) as JPEGs for the model,
    /// from the previews on this Mac.
    static func images(_ members: [Run.Member], maxSide: CGFloat = 768) async -> [Data]? {
        let items = Items.lookup(members.map(\.id))
        var images: [Data] = []
        for member in members {
            guard let item = items[member.id], let image = await item.image(maxSide: maxSide, fetch: .localOnly),
                  let data = jpeg(image) else { return nil }
            images.append(data)
        }
        return images
    }

    static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
