import CoreGraphics
import Foundation
import ImageIO

/// Writes a caption, title and keywords to the photos you keep, so Photos and
/// Spotlight can find them by what's in them. Apple Photos through
/// AppleScript, since PhotoKit can't set them; files in their own XMP. New
/// text goes after what's already there, and the old values are kept for undo.
enum Captions {
    struct Fields: Codable, Equatable {
        var caption = ""
        var title = ""
        var keywords: [String] = []

        var isEmpty: Bool { caption.isEmpty && title.isEmpty && keywords.isEmpty }
    }

    /// What a photo had before PixelGraph wrote to it.
    struct Change: Codable {
        var id: String
        var old: Fields
    }

    enum Failure: LocalizedError {
        case photos(String)
        case file(String)

        var errorDescription: String? {
            switch self {
            case .photos(let message):
                if message.contains("-1743") {
                    return "not allowed to control Photos. Allow it in System Settings → Privacy & Security → Automation."
                }
                return "Photos said: \(message)"
            case .file(let name): return "couldn't write to \(name)"
            }
        }
    }

    // MARK: Making them

    /// A title and caption from Apple's on-device model (when there is one)
    /// and keywords from it and Vision; nil when there's nothing to say.
    static func make(_ item: Item, useModel: Bool) async -> Fields? {
        guard let image = await item.image(maxSide: 1024, fetch: .download(timeout: 60)) else { return nil }
        var fields = Fields()
        if useModel, let written = await Insight.caption(image) {
            fields.title = written.title
            fields.caption = written.caption
            fields.keywords = written.keywords
        }
        fields.keywords = merge(fields.keywords, await Insight.sceneTags(image, limit: 6))
        return fields.isEmpty ? nil : fields
    }

    /// `new` after `old`: "old · new" for the caption and title, and any new keywords added.
    static func appending(_ new: Fields, to old: Fields) -> Fields {
        Fields(caption: join(old.caption, new.caption), title: join(old.title, new.title),
               keywords: merge(old.keywords, new.keywords))
    }

    private static func join(_ old: String, _ new: String) -> String {
        if new.isEmpty || old.contains(new) { return old }
        return old.isEmpty ? new : old + " · " + new
    }

    static func merge(_ old: [String], _ new: [String]) -> [String] {
        var seen = Set(old.map { $0.lowercased() })
        return old + new.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    // MARK: Writing them

    /// Adds `new` to a photo's caption, title and keywords. Returns what it
    /// had before, or nil for files whose format can't hold them.
    static func write(_ new: Fields, to id: String) async throws -> Change? {
        if id.hasPrefix("file:") {
            let url = URL(fileURLWithPath: String(id.dropFirst(5)))
            guard canWrite(url) else { return nil }
            let old = read(url)
            try write(appending(new, to: old), to: url)
            return Change(id: id, old: old)
        }
        let old = try await readPhoto(id)
        try await writePhoto(appending(new, to: old), to: id)
        return Change(id: id, old: old)
    }

    /// Puts back what the photos had before.
    static func restore(_ changes: [Change]) async throws {
        for change in changes.reversed() {
            if change.id.hasPrefix("file:") {
                try write(change.old, to: URL(fileURLWithPath: String(change.id.dropFirst(5))))
            } else {
                try await writePhoto(change.old, to: change.id)
            }
        }
    }

    // MARK: Apple Photos

    /// Photos' scripting names: description is the caption, name the title.
    /// Keywords travel joined by a group separator, fields by a unit separator.
    private static let script = """
        on run argv
        	set GS to character id 29
        	set US to character id 31
        	set verb to item 1 of argv
        	set theID to item 2 of argv
        	if verb is "write" then
        		set newKeywords to {}
        		if item 5 of argv is not "" then
        			set AppleScript's text item delimiters to GS
        			set newKeywords to text items of (item 5 of argv)
        			set AppleScript's text item delimiters to ""
        		end if
        		tell application "Photos"
        			set m to media item id theID
        			set description of m to item 3 of argv
        			set name of m to item 4 of argv
        			if newKeywords is {} then
        				try
        					set keywords of m to {}
        				end try
        			else
        				set keywords of m to newKeywords
        			end if
        		end tell
        		return ""
        	end if
        	tell application "Photos"
        		set m to media item id theID
        		set c to description of m
        		set t to name of m
        		set k to keywords of m
        	end tell
        	if c is missing value then set c to ""
        	if t is missing value then set t to ""
        	if k is missing value then set k to {}
        	set AppleScript's text item delimiters to GS
        	set ks to k as text
        	set AppleScript's text item delimiters to ""
        	return c & US & t & US & ks
        end run
        """

    private static func readPhoto(_ id: String) async throws -> Fields {
        let parts = try await osascript(["read", id]).components(separatedBy: "\u{1F}")
        guard parts.count == 3 else { return Fields() }
        return Fields(caption: parts[0], title: parts[1],
                      keywords: parts[2].isEmpty ? [] : parts[2].components(separatedBy: "\u{1D}"))
    }

    private static func writePhoto(_ fields: Fields, to id: String) async throws {
        _ = try await osascript(["write", id, fields.caption, fields.title, fields.keywords.joined(separator: "\u{1D}")])
    }

    private static func osascript(_ arguments: [String]) async throws -> String {
        let file = Paths.root.appendingPathComponent("captions.applescript")
        try script.write(to: file, atomically: true, encoding: .utf8)
        return try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = [file.path] + arguments
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            try process.run()
            let output = out.fileHandleForReading.readDataToEndOfFile()
            let error = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw Failure.photos(String(decoding: error, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            var text = String(decoding: output, as: UTF8.self)
            if text.hasSuffix("\n") { text.removeLast() }
            return text
        }.value
    }

    // MARK: Files

    /// Formats ImageIO can add metadata to without touching the pixels.
    private static let writable: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff"]

    static func canWrite(_ url: URL) -> Bool {
        writable.contains(url.pathExtension.lowercased()) && !Files.isCloudOnly(url)
    }

    /// The caption (dc:description), title (dc:title) and keywords (dc:subject) in a file's XMP.
    static func read(_ url: URL) -> Fields {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) else { return Fields() }
        func text(_ path: String) -> String {
            (CGImageMetadataCopyStringValueWithPath(metadata, nil, path as CFString) as String?) ?? ""
        }
        var keywords: [String] = []
        if let tag = CGImageMetadataCopyTagWithPath(metadata, nil, "dc:subject" as CFString),
           let values = CGImageMetadataTagCopyValue(tag) as? [CGImageMetadataTag] {
            keywords = values.compactMap { CGImageMetadataTagCopyValue($0) as? String }
        }
        return Fields(caption: text("dc:description"), title: text("dc:title"), keywords: keywords)
    }

    /// Sets exactly `fields`, removing what's empty. The image data is copied as is.
    static func write(_ fields: Fields, to url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(source)
        else { throw Failure.file(url.lastPathComponent) }
        let metadata = CGImageMetadataCreateMutable()
        func set(_ property: CFString, _ path: String, _ value: CFTypeRef?) {
            if let value {
                CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyIPTCDictionary, property, value)
            } else {
                CGImageMetadataSetValueWithPath(metadata, nil, path as CFString, kCFNull)
            }
        }
        set(kCGImagePropertyIPTCCaptionAbstract, "dc:description", fields.caption.isEmpty ? nil : fields.caption as CFString)
        set(kCGImagePropertyIPTCObjectName, "dc:title", fields.title.isEmpty ? nil : fields.title as CFString)
        set(kCGImagePropertyIPTCKeywords, "dc:subject", fields.keywords.isEmpty ? nil : fields.keywords as CFArray)

        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).pixelgraph")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, type, 1, nil)
        else { throw Failure.file(url.lastPathComponent) }
        let options = [kCGImageDestinationMetadata: metadata, kCGImageDestinationMergeMetadata: true] as CFDictionary
        guard CGImageDestinationCopyImageSource(destination, source, options, nil)
        else { throw Failure.file(url.lastPathComponent) }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }
}
