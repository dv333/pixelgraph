import ArgumentParser
import Foundation
import ImageIO
import Vision

/// Hidden helper for tuning: scores image files and prints pairwise
/// fingerprint distances, without touching Photos.
struct DebugImages: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "debug-images", abstract: "Score image files and print pairwise distances.", shouldDisplay: false)

    @Argument(help: "Image files.")
    var files: [String]

    @Flag(help: "Also ask Apple's on-device model to pick the best (first 4 files).")
    var judge = false

    @Option(help: "Group the files and write a report into this folder, to preview the report without Photos.")
    var report: String?

    func run() async throws {
        var photos: [Photo] = []
        var prints: [FeaturePrintObservation] = []
        var images: [CGImage] = []
        var urls: [URL] = []
        for file in files {
            let url = URL(fileURLWithPath: file)
            guard let image = Self.load(url, maxSide: 512) else { print("can't read \(file)"); continue }
            urls.append(url)
            images.append(image)
            let a = try await Analyzer.analyze(image)
            prints.append(try await ImageRequestHandler(image).perform(GenerateImageFeaturePrintRequest()))
            photos.append(Photo(id: url.lastPathComponent, date: .now.addingTimeInterval(Double(photos.count)), isScreenshot: false,
                                width: image.width, height: image.height, analysis: a))
            print(String(format: "%-28@ look %+.2f  sharp %.4f  faces %d (q %.2f)  dims %d",
                         url.lastPathComponent, a.aesthetic, a.sharpness, a.faceCount, a.faceQuality, a.vector.count))
        }
        print("\nPairwise distance (ours / Vision's):")
        for i in photos.indices {
            for j in photos.indices where j > i {
                let vision = (try? prints[i].distance(to: prints[j])) ?? -1
                print(String(format: "  %-28@ %-28@ %.3f / %.3f", photos[i].id, photos[j].id, Grouper.distance(photos[i], photos[j]), vision))
            }
        }

        if judge {
            print("\nApple model available with vision: \(Picker.modelAvailable)")
            let started = Date.now
            if let verdict = await Picker.askModel(Array(images.prefix(4))) {
                print("Model picked \(photos[verdict.index].id): \(verdict.reason) (\(String(format: "%.1f", Date.now.timeIntervalSince(started)))s)")
            } else {
                print("Model gave no usable answer.")
            }
        }
        if let report { try await writeReport(photos, urls, to: URL(fileURLWithPath: report)) }
    }

    private func writeReport(_ photos: [Photo], _ urls: [URL], to folder: URL) async throws {
        let rules = GroupingRules(momentThreshold: 0.5, momentWindow: 600, sceneThreshold: 0.3)
        var groups: [Run.Group] = []
        for indices in Grouper.groups(photos, rules: rules) {
            let members = indices.map { photos[$0] }
            groups.append(Run.Group(kind: Run.Group.Kind(members, rules: rules), photos: members.map(Run.Member.init),
                                    pick: await Picker.pick(members, useModel: false)))
        }
        let run = Run(date: .now, scope: "test images", scanned: photos.count, rules: rules, groups: groups)
        _ = try Report.resetFolder(folder)
        var images: [String: Report.Images] = [:]
        for (photo, url) in zip(photos, urls) {
            if let thumb = Self.load(url, maxSide: Report.thumbSide), let full = Self.load(url, maxSide: Report.fullSide) {
                images[photo.id] = Report.save(thumb: thumb, full: full, as: "\(images.count)", in: folder)
            }
        }
        try Report.render(run, images: images, in: folder)
        try run.save(to: folder.appendingPathComponent("last-run.json"))
        print("\nReport: \(Report.page(in: folder).path)")
    }

    private static func load(_ url: URL, maxSide: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
    }
}
