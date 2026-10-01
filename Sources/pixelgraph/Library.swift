import AppKit
@preconcurrency import Photos

enum PixelGraphError: LocalizedError {
    case noAccess
    case albumNotFound(String)
    case noRun

    var errorDescription: String? {
        switch self {
        case .noAccess:
            return "No access to Photos. Allow it in System Settings → Privacy & Security → Photos."
        case .albumNotFound(let name):
            return "No album named “\(name)”. Run `pixelgraph albums` to see the names."
        case .noRun:
            return "Nothing scanned yet. Run `pixelgraph` to choose what to scan."
        }
    }
}

/// Apple Photos (and iCloud Photos) through PhotoKit.
enum Library {
    struct Album {
        let id: String
        let title: String
        let count: Int
        let latest: Date?
    }

    static func requestAccess() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { throw PixelGraphError.noAccess }
    }

    /// Your albums with photos in them, most recent first. Leaves out the
    /// Duplicates album PixelGraph makes.
    static func albums() -> [Album] {
        var result: [Album] = []
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
            .enumerateObjects { collection, _, _ in
                guard collection.localizedTitle != duplicatesAlbum, collection.localizedTitle != documentsAlbum else { return }
                let count = PHAsset.fetchAssets(in: collection, options: imagesOnly()).count
                guard count > 0 else { return }
                result.append(Album(id: collection.localIdentifier, title: collection.localizedTitle ?? "Untitled",
                                    count: count, latest: collection.endDate))
            }
        return result.sorted { ($0.latest ?? .distantPast) > ($1.latest ?? .distantPast) }
    }

    /// Photo counts for the last `months` months, newest first.
    static func months(_ months: Int = 24) -> [(start: Date, end: Date, count: Int)] {
        let calendar = Calendar.current
        let thisMonth = calendar.dateInterval(of: .month, for: .now)!.start
        return (0..<months).compactMap { back in
            guard let start = calendar.date(byAdding: .month, value: -back, to: thisMonth),
                  let end = calendar.date(byAdding: .month, value: 1, to: start) else { return nil }
            let count = assets(from: start, to: end).count
            return count > 0 ? (start, end, count) : nil
        }
    }

    static func totalCount() -> Int { PHAsset.fetchAssets(with: imagesOnly()).count }

    static func album(named name: String) -> PHAssetCollection? {
        var match: PHAssetCollection?
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
            .enumerateObjects { collection, _, stop in
                if collection.localizedTitle == name {
                    match = collection
                    stop.pointee = true
                }
            }
        return match
    }

    /// Photos in an album, oldest first.
    static func assets(inAlbum id: String, title: String) throws -> [PHAsset] {
        guard let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject
        else { throw PixelGraphError.albumNotFound(title) }
        return all(PHAsset.fetchAssets(in: collection, options: imagesOnly()))
    }

    /// Photos taken in a date range, oldest first.
    static func assets(from: Date?, to: Date?) -> [PHAsset] {
        let options = imagesOnly()
        var predicates = [options.predicate!]
        if let from { predicates.append(NSPredicate(format: "creationDate >= %@", from as NSDate)) }
        if let to { predicates.append(NSPredicate(format: "creationDate < %@", to as NSDate)) }
        options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        return all(PHAsset.fetchAssets(with: options))
    }

    private static func all(_ fetch: PHFetchResult<PHAsset>) -> [PHAsset] {
        var assets: [PHAsset] = []
        assets.reserveCapacity(fetch.count)
        fetch.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    // MARK: - Duplicates album

    static let duplicatesAlbum = "PixelGraph Duplicates"
    static let documentsAlbum = "PGDocuments"

    /// Adds photos to the album called `destination` (creating it if needed)
    /// and takes them out of `album`. Nothing leaves the library.
    static func move(_ ids: [String], to destination: String, from album: String?) async throws {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        let existing = Library.album(named: destination)
        let source = album.flatMap { PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [$0], options: nil).firstObject }
        try await PHPhotoLibrary.shared().performChanges {
            let duplicates = existing.flatMap { PHAssetCollectionChangeRequest(for: $0) }
                ?? PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: destination)
            duplicates.addAssets(assets)
            if let source, source.canPerform(.removeContent) {
                PHAssetCollectionChangeRequest(for: source)?.removeAssets(assets)
            }
        }
    }

    /// Reverses `move`.
    static func restore(_ ids: [String], from destination: String, to album: String?) async throws {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        let duplicates = Library.album(named: destination)
        let source = album.flatMap { PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [$0], options: nil).firstObject }
        try await PHPhotoLibrary.shared().performChanges {
            if let duplicates { PHAssetCollectionChangeRequest(for: duplicates)?.removeAssets(assets) }
            if let source, source.canPerform(.addContent) { PHAssetCollectionChangeRequest(for: source)?.addAssets(assets) }
        }
    }

    enum Fetch {
        /// Never touch the network. With "Optimize Mac Storage" most originals
        /// live in iCloud, but Photos keeps a small preview of every photo on
        /// the Mac, which is enough for fingerprints.
        case localOnly
        /// Download from iCloud if needed, giving up after `timeout` seconds.
        case download(timeout: TimeInterval)
    }

    /// A rendered copy of the photo that fits in `maxSide` × `maxSide`, or
    /// smaller when only a small local preview exists. Check the result's size.
    static func image(_ asset: PHAsset, maxSide: CGFloat, fetch: Fetch = .localOnly) async -> CGImage? {
        switch fetch {
        case .localOnly:
            if let image = await request(asset, maxSide, .highQualityFormat, network: false, timeout: nil) { return image }
            return await request(asset, maxSide, .fastFormat, network: false, timeout: nil)
        case .download(let timeout):
            if let image = await request(asset, maxSide, .highQualityFormat, network: true, timeout: timeout) { return image }
            return await request(asset, maxSide, .fastFormat, network: false, timeout: nil)
        }
    }

    private static func request(
        _ asset: PHAsset, _ maxSide: CGFloat, _ mode: PHImageRequestOptionsDeliveryMode,
        network: Bool, timeout: TimeInterval?
    ) async -> CGImage? {
        await withCheckedContinuation { continuation in
            let once = Once(continuation)
            let options = PHImageRequestOptions()
            options.deliveryMode = mode
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = network
            options.version = .current
            let id = PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: maxSide, height: maxSide),
                contentMode: .aspectFit,
                options: options
            ) { image, _ in
                once.resume(image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            }
            if let timeout {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    PHImageManager.default().cancelImageRequest(id)
                    once.resume(nil)
                }
            }
        }
    }

    /// Resumes a continuation exactly once, whichever of result or timeout comes first.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<CGImage?, Never>?
        init(_ continuation: CheckedContinuation<CGImage?, Never>) { self.continuation = continuation }
        func resume(_ image: CGImage?) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: image)
        }
    }

    private static func imagesOnly() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        // Skip photos in other people's shared albums: they can't be moved.
        options.includeAssetSourceTypes = [.typeUserLibrary, .typeiTunesSynced]
        return options
    }
}
