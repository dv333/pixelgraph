import Foundation
import ImageIO
import Testing
@testable import pixelgraph

private let rules = GroupingRules(momentThreshold: 0.5, momentWindow: 600, sceneThreshold: 0.3)
private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

private func photo(_ id: String, _ x: Float, _ y: Float = 0, at seconds: TimeInterval = 0,
                   screenshot: Bool = false, sharpness: Float = 0.01, aesthetic: Float = 0) -> Photo {
    Photo(id: id, date: t0.addingTimeInterval(seconds), isScreenshot: screenshot, width: 4000, height: 3000,
          analysis: Analysis(vector: [x, y, 0, 0], aesthetic: aesthetic, isUtility: false, sharpness: sharpness,
                             faceCount: 0, faceQuality: -1, previewSide: 1024))
}

private func ids(_ groups: [[Int]], _ photos: [Photo]) -> Set<Set<String>> {
    Set(groups.map { Set($0.map { photos[$0].id }) })
}

@Test func chainDoesNotDriftIntoOneGroup() {
    // Each neighbour is 0.3 apart, but A and C are 0.6 apart.
    let photos = [photo("A", 0), photo("B", 0.3), photo("C", 0.6), photo("D", 0.9)]
    #expect(ids(Grouper.groups(photos, rules: rules), photos) == [["A", "B"], ["C", "D"]])
}

@Test func sameMomentIsLooserThanAnyTime() {
    let close = [photo("A", 0), photo("B", 0.4, at: 60)]
    let apart = [photo("A", 0), photo("B", 0.4, at: 86_400)]
    #expect(Grouper.groups(close, rules: rules).count == 1)
    #expect(Grouper.groups(apart, rules: rules).isEmpty)
}

@Test func copiesMatchAcrossTime() {
    let photos = [photo("A", 0), photo("B", 0.03, at: 86_400 * 365)]
    #expect(Grouper.groups(photos, rules: rules).count == 1)
}

@Test func screenshotsNeverGroupWithPhotos() {
    let photos = [photo("A", 0), photo("B", 0, screenshot: true), photo("C", 0.01, screenshot: true)]
    #expect(ids(Grouper.groups(photos, rules: rules), photos) == [["B", "C"]])
}

@Test func unrelatedPhotosStaySeparate() {
    let photos = [photo("A", 0), photo("B", 1, 0), photo("C", 0, 1)]
    #expect(Grouper.groups(photos, rules: rules).isEmpty)
}

@Test func sharperShotWinsWhenLookIsEqual() async {
    let group = [photo("soft", 0, sharpness: 0.001), photo("crisp", 0.2, at: 2, sharpness: 0.02)]
    let pick = await Picker.pick(group, useModel: false)
    #expect(pick.best == "crisp")
    #expect(pick.decidedBy == "vision")
    #expect(pick.notes["soft"] == "blurrier")
}

@Test func groupKindLabels() {
    #expect(Run.Group.Kind([photo("A", 0), photo("B", 0.03, at: 86_400)], rules: rules) == .copies)
    #expect(Run.Group.Kind([photo("A", 0), photo("B", 0.4, at: 30)], rules: rules) == .moment)
    #expect(Run.Group.Kind([photo("A", 0), photo("B", 0.28, at: 86_400)], rules: rules) == .scene)
}

@Test func endDatesIncludeTheWholePeriod() throws {
    let calendar = Calendar.current
    let month = try #require(try DateArgument.parse("2024-07", end: true))
    #expect(calendar.dateComponents([.year, .month, .day], from: month) == DateComponents(year: 2024, month: 8, day: 1))
    let year = try #require(try DateArgument.parse("2024", end: true))
    #expect(calendar.component(.year, from: year) == 2025)
    #expect(throws: (any Error).self) { try DateArgument.parse("July", end: false) }
}

@Test func flaggedPhotoIsNotPickedWhenThereIsAnAlternative() async {
    // The sharper shot has its eyes closed, so the softer one wins.
    let group = [photo("closed", 0, sharpness: 0.02), photo("open", 0.2, at: 2, sharpness: 0.005)]
    let pick = await Picker.pick(group, useModel: false, problems: ["closed": "eyes closed"])
    #expect(pick.best == "open")
    #expect(pick.keepers == ["open"])
    #expect(pick.suggestions == ["closed": "eyes closed"])
}

@Test func scansFromBeforeKeepMoveStillLoad() throws {
    let old = #"{"best":"A","decidedBy":"you","notes":{"A":"sharpest"},"keepers":["A"],"rejects":{"B":"eyes closed"}}"#
    let pick = try JSONDecoder().decode(Pick.self, from: Data(old.utf8))
    #expect(pick.keepers == ["A"])
    #expect(pick.reasons == ["B": "eyes closed"])
    #expect(pick.kept.isEmpty && pick.moved.isEmpty)
}

@Test func everythingButTheBestStartsSelectedToMove() async {
    let group = [photo("A", 0, sharpness: 0.02), photo("B", 0.1, at: 1), photo("C", 0.2, at: 2)]
    let pick = await Picker.pick(group, useModel: false)
    #expect(pick.best == "A")
    #expect(!pick.willMove("A"))
    #expect(pick.willMove("B") && pick.willMove("C"))
}

@Test func keptAndMovedPhotosAreNotSelected() {
    var pick = Pick(best: "A", decidedBy: "vision", notes: [:])
    pick.kept = ["B"]
    pick.moved = ["C"]
    #expect(!pick.willMove("B"))
    #expect(!pick.willMove("C"))
    #expect(pick.willMove("D"))
}

@Test func displayPutsBestFirstThenKeptThenMovingThenMoved() {
    var pick = Pick(best: "C", decidedBy: "you", notes: [:])
    pick.kept = ["D"]
    pick.moved = ["A"]
    let members = ["A", "B", "C", "D"].enumerated().map {
        Run.Member(id: $0.element, date: t0.addingTimeInterval(Double($0.offset)), width: 4, height: 3,
                   aesthetic: 0, sharpness: 0, faceCount: 0, faceQuality: -1, previewSide: 1024)
    }
    let group = Run.Group(kind: .moment, photos: members, pick: pick)
    #expect(Run.displayOrder(group).map(\.id) == ["C", "D", "B", "A"])
}

@Test func runListsPhotosToMoveAndForgetsThemAfterUndo() {
    let members = ["A", "B"].map {
        Run.Member(id: $0, date: t0, width: 4, height: 3, aesthetic: 0, sharpness: 0, faceCount: 0, faceQuality: -1, previewSide: 1024)
    }
    var run = Run(date: t0, scope: "test", scanned: 2, rules: rules,
                  groups: [Run.Group(kind: .moment, photos: members, pick: Pick(best: "A", decidedBy: "vision", notes: [:]))])
    #expect(run.toMove == ["B"])
    run.markMoved(["B"])
    #expect(run.toMove.isEmpty)
    run.unmark(["B"])
    #expect(run.toMove == ["B"])
}

@Test func problemsMapToRejectReasons() {
    #expect(Inspector.Problem.none.reason == nil)
    #expect(Inspector.Problem.eyesClosed.reason == "eyes closed")
    #expect(Inspector.Problem.cutOff.reason == "bad framing")
    #expect(Inspector.reasons.contains(Inspector.Problem.faceBlocked.reason!))
}

// MARK: - Folders

private func scratchFolder() throws -> URL {
    // Keep the move log out of the real data folder.
    setenv("PIXELGRAPH_HOME", FileManager.default.temporaryDirectory.appendingPathComponent("pixelgraph-test-home").path, 0)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("pixelgraph-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func rawAndJpegPairsCountAsOneShot() throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    for name in ["IMG_1.JPG", "IMG_1.CR3", "IMG_1.xmp", "IMG_2.heic", "notes.txt"] {
        FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data())
    }
    try FileManager.default.createDirectory(at: folder.appendingPathComponent(Files.duplicatesFolder), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: folder.appendingPathComponent(Files.duplicatesFolder + "/IMG_9.jpg").path, contents: Data())

    let shots = try Files.images(in: folder).map(\.lastPathComponent).sorted()
    #expect(shots == ["IMG_1.JPG", "IMG_2.heic"])
    let companions = Files.companions(of: folder.appendingPathComponent("IMG_1.JPG")).map(\.lastPathComponent).sorted()
    #expect(companions == ["IMG_1.CR3", "IMG_1.xmp"])
}


// MARK: - Documents

private let formA = """
    U.S. Department of Homeland Security I-797C Notice of Action
    Receipt Number IOE0912345678 Case Type I-765 Application for Employment Authorization
    Applicant ANITA KUMAR Received Date 03/14/2025 Priority Date Notice Date 03/18/2025
    """
private let formB = """
    U.S. Department of Homeland Security I-797C Notice of Action
    Receipt Number IOE0998877665 Case Type I-131 Application for Travel Document
    Applicant RAVI MENON Received Date 07/02/2024 Priority Date Notice Date 07/09/2024
    """

@Test func sameTemplateDifferentContentIsNotADuplicate() {
    #expect(Insight.similarity(formA, formB) < 0.85)
    // The same page read twice, with an OCR slip, still matches.
    let reread = formA.replacingOccurrences(of: "Employment", with: "Employrnent")
    #expect(Insight.similarity(formA, reread) >= 0.85)
}

@Test func documentCopiesGroupByText() {
    let a = photo("a", 0), b = photo("b", 0.05, at: 86_400), c = photo("c", 0.02, at: 3_600)
    let documents: [String: Insight.Document] = [
        "a": Insight.Document(kind: "Form", title: "I-797C notice", text: formA),
        "b": Insight.Document(kind: "Form", title: "I-797C notice", text: formA + "\nPage 1 of 1"),
        "c": Insight.Document(kind: "Form", title: "I-797C notice", text: formB),
    ]
    let groups = Scanner.documentGroups([a, b, c], documents).map { Set($0.map(\.id)) }
    #expect(Set(groups) == [["a", "b"], ["c"]])
}


/// Moves share one undo log, so these run one at a time.
@Suite(.serialized)
struct MoveTests {
    @Test func folderMovesKeepLayoutAndUndoPutsThemBack() async throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let day = folder.appendingPathComponent("Day 1")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        for name in ["IMG_1.JPG", "IMG_1.CR3"] {
            FileManager.default.createFile(atPath: day.appendingPathComponent(name).path, contents: Data("x".utf8))
        }
        let id = Item.fileID(day.appendingPathComponent("IMG_1.JPG"))

        let record = try await Mover.move([id], from: .folder(path: folder.path))
        let moved = folder.appendingPathComponent("\(Files.duplicatesFolder)/Day 1")
        #expect(record.files.count == 2)
        #expect(FileManager.default.fileExists(atPath: moved.appendingPathComponent("IMG_1.JPG").path))
        #expect(FileManager.default.fileExists(atPath: moved.appendingPathComponent("IMG_1.CR3").path))
        #expect(!FileManager.default.fileExists(atPath: day.appendingPathComponent("IMG_1.JPG").path))

        try await Mover.undoLast()
        #expect(FileManager.default.fileExists(atPath: day.appendingPathComponent("IMG_1.JPG").path))
        #expect(FileManager.default.fileExists(atPath: day.appendingPathComponent("IMG_1.CR3").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(Files.duplicatesFolder).path))
    }

    @Test func filingDocumentsAndCopiesUndoesInOneStep() async throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["receipt.jpg", "receipt copy.jpg"] {
            FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data("x".utf8))
        }
        let source = Source.folder(path: folder.path)
        let batch = UUID()
        _ = try await Mover.move([Item.fileID(folder.appendingPathComponent("receipt.jpg"))], from: source, to: .documents, batch: batch)
        _ = try await Mover.move([Item.fileID(folder.appendingPathComponent("receipt copy.jpg"))], from: source, to: .duplicates, batch: batch)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("PGDocuments/receipt.jpg").path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("PGDuplicates/receipt copy.jpg").path))

        let undone = try await Mover.undoLast()
        #expect(undone?.ids.count == 2)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("receipt.jpg").path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("receipt copy.jpg").path))
    }

    @Test func deletingFromAFolderUsesTheTrashAndUndoPutsItBack() async throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let shot = folder.appendingPathComponent("IMG_7.JPG")
        FileManager.default.createFile(atPath: shot.path, contents: Data("x".utf8))
        FileManager.default.createFile(atPath: folder.appendingPathComponent("IMG_7.xmp").path, contents: Data("x".utf8))

        let record = try await Mover.move([Item.fileID(shot)], from: .folder(path: folder.path), to: .trash)
        #expect(record.files.count == 2)
        #expect(!FileManager.default.fileExists(atPath: shot.path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(Files.duplicatesFolder).path))

        try await Mover.undoLast()
        #expect(FileManager.default.fileExists(atPath: shot.path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("IMG_7.xmp").path))
    }
}

@Test func captionsAppendAfterWhatsThere() {
    let old = Captions.Fields(caption: "Mom's birthday", title: "Party", keywords: ["family", "Cake"])
    let new = Captions.Fields(caption: "Candles on a chocolate cake.", title: "Birthday cake", keywords: ["cake", "candles"])
    let both = Captions.appending(new, to: old)
    #expect(both.caption == "Mom's birthday · Candles on a chocolate cake.")
    #expect(both.title == "Party · Birthday cake")
    #expect(both.keywords == ["family", "Cake", "candles"])
    #expect(Captions.appending(new, to: both) == both)
}

@Test func captionsGoIntoTheFileAndUndoPutsTheOldOnesBack() async throws {
    let folder = try scratchFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("beach.jpg")
    let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    #expect(CGImageDestinationFinalize(destination))

    let id = Item.fileID(url)
    let fields = Captions.Fields(caption: "Waves at sunset.", title: "Ocean Beach", keywords: ["beach", "sunset"])
    let change = try await Captions.write(fields, to: id)
    #expect(change?.old == Captions.Fields())
    #expect(Captions.read(url) == fields)

    try await Captions.restore([change!])
    #expect(Captions.read(url) == Captions.Fields())
}
