import CoreGraphics
import Foundation
import ImageIO
@preconcurrency import Photos
import QuickLookThumbnailing

/// Where photos come from: an Apple Photos album or date range, or a folder
/// on this Mac, an external drive or iCloud Drive.
enum Source: Codable, Hashable, CustomStringConvertible {
    case album(id: String, title: String)
    case dates(from: Date?, to: Date?)
    case folder(path: String)

    var description: String {
        switch self {
        case .album(_, let title): return title
        case .dates(let from, let to):
            let f = DateFormatter()
            f.dateFormat = "MMM yyyy"
            return "Photos, \(from.map(f.string) ?? "start") – \(to.map { f.string(from: $0.addingTimeInterval(-1)) } ?? "now")"
        case .folder(let path): return (path as NSString).lastPathComponent
        }
    }

    var kind: String {
        switch self {
        case .album: return "Photos album"
        case .dates: return "Photos library"
        case .folder(let path):
            if path.hasPrefix("/Volumes/") { return "External drive" }
            if path.contains("/Library/Mobile Documents/") { return "iCloud Drive" }
            return "Folder"
        }
    }

    /// A folder source with one spelling per place (no /private, no symlinks),
    /// so recents and moves line up.
    static func folder(_ url: URL) -> Source {
        .folder(path: url.resolvingSymlinksInPath().path)
    }

    var isPhotos: Bool {
        if case .folder = self { return false }
        return true
    }
}

/// One photo from any source.
struct Item: @unchecked Sendable {
    enum Backing {
        case photo(PHAsset)
        case file(URL)
    }

    let backing: Backing
    let id: String
    let date: Date
    /// Changes when the photo is edited, so cached analysis is redone.
    let modified: Date
    let width: Int
    let height: Int
    let isScreenshot: Bool

    init(_ asset: PHAsset) {
        backing = .photo(asset)
        id = asset.localIdentifier
        date = asset.creationDate ?? .distantPast
        modified = asset.modificationDate ?? asset.creationDate ?? .distantPast
        width = asset.pixelWidth
        height = asset.pixelHeight
        isScreenshot = asset.mediaSubtypes.contains(.photoScreenshot)
    }

    /// nil for files that aren't images.
    init?(file url: URL) {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey, .fileSizeKey])
        backing = .file(url)
        id = Item.fileID(url)
        modified = values?.contentModificationDate ?? .distantPast
        let name = url.lastPathComponent.lowercased()
        isScreenshot = name.hasPrefix("screenshot") || name.hasPrefix("screen shot")

        // Files only in iCloud Drive: reading them would download them, so use
        // what the file system knows and let the thumbnail fill in later.
        if Files.isCloudOnly(url) {
            date = values?.creationDate ?? modified
            width = 0
            height = 0
            return
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var w = props[kCGImagePropertyPixelWidth] as? Int, var h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        if let orientation = props[kCGImagePropertyOrientation] as? Int, orientation >= 5 { swap(&w, &h) }
        width = w
        height = h
        date = Files.captureDate(props) ?? values?.creationDate ?? modified
    }

    static func fileID(_ url: URL) -> String { "file:" + url.standardizedFileURL.path }

    var fileURL: URL? {
        if case .file(let url) = backing { return url }
        return nil
    }

    /// A rendered copy that fits in `maxSide` × `maxSide`, or smaller when
    /// only a small local preview exists.
    func image(maxSide: CGFloat, fetch: Library.Fetch) async -> CGImage? {
        switch backing {
        case .photo(let asset):
            return await Library.image(asset, maxSide: maxSide, fetch: fetch)
        case .file(let url):
            if Files.isCloudOnly(url) {
                if case .download(let timeout) = fetch, await Files.download(url, timeout: timeout) {
                    return Files.thumbnail(url, maxSide: maxSide)
                }
                return await Files.cloudThumbnail(url, maxSide: maxSide)
            }
            return Files.thumbnail(url, maxSide: maxSide)
        }
    }
}

enum Items {
    /// Items by id, for photos from any source.
    static func lookup(_ ids: [String]) -> [String: Item] {
        var result: [String: Item] = [:]
        let photoIDs = ids.filter { !$0.hasPrefix("file:") }
        if !photoIDs.isEmpty {
            PHAsset.fetchAssets(withLocalIdentifiers: photoIDs, options: nil)
                .enumerateObjects { asset, _, _ in result[asset.localIdentifier] = Item(asset) }
        }
        for id in ids where id.hasPrefix("file:") {
            if let item = Item(file: URL(fileURLWithPath: String(id.dropFirst(5)))) { result[id] = item }
        }
        return result
    }

    static func load(_ source: Source) throws -> [Item] {
        switch source {
        case .album(let id, let title):
            return try Library.assets(inAlbum: id, title: title).map(Item.init)
        case .dates(let from, let to):
            return Library.assets(from: from, to: to).map(Item.init)
        case .folder(let path):
            return try Files.images(in: URL(fileURLWithPath: path)).compactMap(Item.init(file:))
                .sorted { $0.date < $1.date }
        }
    }
}

/// Photos in folders: finding them, reading dates, thumbnails, and iCloud Drive.
enum Files {
    static let duplicatesFolder = "PGDuplicates"
    /// What the Duplicates folder was called before; moves made then went there.
    static let oldDuplicatesFolder = "PixelGraph Duplicates"
    /// Folders PixelGraph makes, skipped when scanning.
    static let ownFolders: Set<String> = [duplicatesFolder, documentsFolder, oldDuplicatesFolder]
    static let documentsFolder = "PGDocuments"

    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "webp",
        "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "pef", "srw",
    ]
    static let rawExtensions: Set<String> = ["dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "pef", "srw"]
    static let sidecarExtensions: Set<String> = ["xmp", "aae"]

    enum FolderError: LocalizedError {
        case missing(String)
        var errorDescription: String? {
            switch self {
            case .missing(let path): return "Can't open “\(path)”. Check the drive is connected."
            }
        }
    }

    /// Images under `folder`, one per shot: when RAW and JPEG versions share a
    /// name, the JPEG stands for both (it's faster to read) and the RAW moves with it.
    static func images(in folder: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: folder.path) else { throw FolderError.missing(folder.path) }
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var byShot: [String: [URL]] = [:]
        for case let url as URL in walker {
            if ownFolders.contains(url.lastPathComponent) {
                walker.skipDescendants()
                continue
            }
            let ext = url.pathExtension.lowercased()
            guard imageExtensions.contains(ext) else { continue }
            byShot[url.deletingPathExtension().path, default: []].append(url)
        }
        return byShot.values.compactMap { shot in
            shot.first { !rawExtensions.contains($0.pathExtension.lowercased()) } ?? shot.first
        }
    }

    /// The other files that belong to a shot: its RAW or JPEG twin and sidecars.
    static func companions(of url: URL) -> [URL] {
        let base = url.deletingPathExtension()
        let folder = url.deletingLastPathComponent()
        let siblings = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return siblings.filter { other in
            other.lastPathComponent != url.lastPathComponent
                && (other.deletingPathExtension().lastPathComponent == base.lastPathComponent
                    || other.lastPathComponent == url.lastPathComponent + ".xmp")
        }.filter { imageExtensions.contains($0.pathExtension.lowercased()) || sidecarExtensions.contains($0.pathExtension.lowercased()) }
    }

    static func captureDate(_ props: [CFString: Any]) -> Date? {
        guard let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.date(from: text)
    }

    static func thumbnail(_ url: URL, maxSide: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
    }

    // MARK: iCloud Drive

    static func isCloudOnly(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              values.isUbiquitousItem == true else { return false }
        return values.ubiquitousItemDownloadingStatus != .current
    }

    /// The thumbnail iCloud keeps for a file that isn't downloaded.
    static func cloudThumbnail(_ url: URL, maxSide: CGFloat) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: maxSide, height: maxSide),
                                                   scale: 1, representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
    }

    /// Asks iCloud Drive for the file and waits until it's here.
    static func download(_ url: URL, timeout: TimeInterval) async -> Bool {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if !isCloudOnly(url) { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }
}
