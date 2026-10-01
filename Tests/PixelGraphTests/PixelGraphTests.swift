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
    let pick = await Picker.pick(group, useModel: false, weights: .standard)
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
    let pick = await Picker.pick(group, useModel: false, problems: ["closed": "eyes closed"], weights: .standard)
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
    let pick = await Picker.pick(group, useModel: false, weights: .standard)
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

// MARK: - Detection

private func quality(hash: UInt64 = 0, focus: Float = 0.01, motion: Float = 0, luma: Float = 0.5,
                     dark: Float = 0, bright: Float = 0, smudge: Float = 0) -> Quality {
    Quality(hash: hash, focus: focus, noise: 0, motion: motion, luma: luma, dark: dark, bright: bright, smudge: smudge)
}

private func face(x: Float = 0.5, eyes: Float = 0.3, yaw: Float = 0, sharpness: Float = 0.01) -> FaceDetail {
    FaceDetail(x: x, y: 0.4, width: 0.2, height: 0.2, eyes: eyes, yaw: yaw, pitch: 0, sharpness: sharpness)
}

private func withFaces(_ p: Photo, _ faces: [FaceDetail]) -> Photo {
    var a = p.analysis
    a.faces = faces
    a.faceCount = faces.count
    a.faceQuality = 0.5
    return Photo(id: p.id, date: p.date, isScreenshot: p.isScreenshot, width: p.width, height: p.height, analysis: a,
                 quality: p.quality, location: p.location)
}

@Test func thresholdEasesWithTimeInsteadOfJumping() {
    let a = photo("A", 0)
    let at = { (s: Double) in rules.threshold(a, photo("B", 0, at: s)) }
    #expect(abs(at(0) - 0.5) < 0.001)
    #expect(at(60) > at(300) && at(300) > at(599) && at(599) > at(601) - 0.001)
    #expect(abs(at(86_400) - 0.3) < 0.001)
}

@Test func copiesFoundByHashAcrossTimeAndPlace() {
    var a = photo("A", 0), b = photo("B", 0.09, at: 86_400 * 30)
    a.quality = quality(hash: 0xF0F0_F0F0_F0F0_F0F0)
    b.quality = quality(hash: 0xF0F0_F0F0_F0F0_F0F1)
    a.location = Location(latitude: 37.77, longitude: -122.42)
    b.location = Location(latitude: 48.85, longitude: 2.35)
    #expect(Grouper.groups([a, b], rules: rules).count == 1)
    #expect(Run.Group.Kind([a, b], rules: rules) == .copies)
}

@Test func sameLookFarApartIsNotTheSameShot() {
    var a = photo("A", 0), b = photo("B", 0.2, at: 30)
    a.location = Location(latitude: 37.77, longitude: -122.42)
    b.location = Location(latitude: 37.90, longitude: -122.42)
    #expect(Grouper.groups([a, b], rules: rules).isEmpty)
}

@Test func closeCallsApartInTimeAreMarkedForChecking() {
    let photos = [photo("A", 0), photo("B", 0.25, at: 86_400), photo("C", 0.2, at: 86_400 + 5)]
    let edges = Grouper.edges(photos, rules: rules)
    #expect(edges.first { Grouper.Pair($0.i, $0.j) == Grouper.Pair(0, 1) }?.needsCheck == true)
    #expect(edges.first { Grouper.Pair($0.i, $0.j) == Grouper.Pair(1, 2) }?.needsCheck == false)
    // A check that fails keeps the pair apart.
    let groups = Grouper.cluster(photos, edges: edges, rules: rules, rejected: [Grouper.Pair(0, 1), Grouper.Pair(0, 2)])
    #expect(ids(groups, photos) == [["B", "C"]])
}

@Test func eyesClosedIsJudgedAgainstTheSamePersonsOtherShots() {
    // Narrow eyes for this person: 0.18 is open for them, 0.05 is a blink.
    let open = withFaces(photo("open", 0), [face(eyes: 0.18)])
    let blink = withFaces(photo("blink", 0.1, at: 1), [face(eyes: 0.05)])
    let turned = withFaces(photo("turned", 0.1, at: 2), [face(eyes: 0.18, yaw: 45)])
    let problems = Inspector.compare([open, blink, turned])
    #expect(problems["blink"] == "eyes closed")
    #expect(problems["turned"] == "looking away")
    #expect(problems["open"] == nil)
}

@Test func softSubjectIsFlaggedAgainstTheSharpestShot() {
    var crisp = photo("crisp", 0), shaken = photo("shaken", 0.1, at: 1)
    crisp.quality = quality(focus: 0.02)
    shaken.quality = quality(focus: 0.002, motion: 0.8)
    #expect(Inspector.compare([crisp, shaken]) == ["shaken": "motion blur"])
}

@Test func junkIsBlackBlownSmudgedOrAmongTheBlurriest() {
    var all = (0..<40).map { i -> Photo in
        var p = photo("p\(i)", Float(i), at: Double(i))
        p.quality = quality(focus: 0.01 + Float(i) * 0.001)
        return p
    }
    var black = photo("black", 0), soft = photo("soft", 0, aesthetic: -0.5)
    black.quality = quality(luma: 0.02, dark: 0.9)
    soft.quality = quality(focus: 0.0001)
    all += [black, soft]
    let found = Inspector.rejects([black, soft, all[20]], among: all)
    #expect(found == ["black": "bad exposure", "soft": "blurry"])
}

@Test func learnerLeansTowardWhatYouChoose() {
    // You always pick the sharper shot even when it looks worse.
    let diffs = Array(repeating: [-0.2, 0.6, 0, 0, 0], count: 30)
    let learned = Learner.fit(diffs)
    #expect(learned.sharpness > Picker.Weights.standard.sharpness)
    #expect(learned.aesthetic < Picker.Weights.standard.aesthetic)
}

@Test func qualityTellsSharpFromBlurredAndDarkFromBright() throws {
    func image(_ draw: (CGContext) -> Void) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        draw(context)
        return try #require(context.makeImage())
    }
    let checks = try image { c in
        for y in stride(from: 0, to: 256, by: 8) {
            for x in stride(from: 0, to: 256, by: 8) {
                c.setFillColor(gray: (x / 8 + y / 8) % 2 == 0 ? 0.1 : 0.9, alpha: 1)
                c.fill(CGRect(x: x, y: y, width: 8, height: 8))
            }
        }
    }
    let flat = try image { c in
        c.setFillColor(gray: 0.02, alpha: 1)
        c.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
    }
    let sharp = try #require(Gray(checks, maxSide: 256)), dark = try #require(Gray(flat, maxSide: 256))
    #expect(sharp.peakFocus() > dark.peakFocus())
    #expect(dark.exposure().dark > 0.9)
    #expect(Verifier.correlation(sharp, sharp, 0, 0) > 0.99)
    #expect(Quality.distance(Quality.hash(checks), Quality.hash(checks)) == 0)
}

@Test func tickedMonthsBecomeOneRangeOrExactlyThoseMonths() throws {
    let calendar = Calendar.current
    func month(_ y: Int, _ m: Int) throws -> Date { try #require(calendar.date(from: DateComponents(year: y, month: m, day: 1))) }
    let together = Source.selection(of: [try month(2021, 3), try month(2021, 1), try month(2021, 2)])
    #expect(together == .dates(from: try month(2021, 1), to: try month(2021, 4)))
    let apart = Source.selection(of: [try month(2022, 3), try month(2021, 1), try month(2021, 2)])
    #expect(apart == .months([try month(2021, 1), try month(2021, 2), try month(2022, 3)]))
    #expect(Source.runs([try month(2021, 1), try month(2021, 2), try month(2022, 3)]).count == 2)
}

// MARK: - Assistants and the nightly run

private func member(_ id: String, sharpness: Float = 0.01, aesthetic: Float = 0) -> Run.Member {
    Run.Member(id: id, date: t0, width: 4000, height: 3000, aesthetic: aesthetic, sharpness: sharpness,
               faceCount: 0, faceQuality: -1, previewSide: 1024)
}

@Test func nightlyMovesCopiesAndClearlyWorseShotsOnly() {
    let copies = Run.Group(kind: .copies, photos: [member("A"), member("B")], pick: Pick(best: "A", decidedBy: "vision", notes: [:]))
    #expect(Agent.clearMoves(copies) == ["B"])

    // B is far behind A; C is nearly as good, so it waits for a person.
    let burst = Run.Group(kind: .moment, photos: [member("A", sharpness: 0.04, aesthetic: 0.6), member("B", sharpness: 0.002, aesthetic: -0.6),
                                                  member("C", sharpness: 0.038, aesthetic: 0.58)],
                          pick: Pick(best: "A", decidedBy: "vision", notes: [:]))
    #expect(Agent.clearMoves(burst) == ["B"])

    let revisited = Run.Group(kind: .scene, photos: [member("A"), member("B")], pick: Pick(best: "A", decidedBy: "vision", notes: [:]))
    #expect(Agent.clearMoves(revisited).isEmpty)
    let closeCall = Run.Group(kind: .copies, photos: [member("A"), member("B")],
                              pick: Pick(best: "A", decidedBy: "vision", notes: [:], suggestions: ["A": "eyes closed"]))
    #expect(Agent.clearMoves(closeCall).isEmpty)
}

@Test func httpRequestWaitsForTheWholeBody() throws {
    let partial = Data("POST /mcp/abc HTTP/1.1\r\nContent-Length: 10\r\n\r\n{\"a\":".utf8)
    #expect(HTTPRequest(partial) == nil)
    let request = try #require(HTTPRequest(partial + Data("1}  ".utf8)))
    #expect(request.method == "POST" && request.path == "/mcp/abc")
    #expect(String(decoding: request.body, as: UTF8.self) == "{\"a\":1}  ")
}

@Test func mcpServerAnswersTheHandshakeAndListsTools() async throws {
    let server = MCPServer(allowTrash: false)
    let hello = try #require(await server.handle(Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#.utf8)))
    let reply = try #require(try JSONSerialization.jsonObject(with: hello) as? [String: Any])
    #expect((reply["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-06-18")
    #expect(await server.handle(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)) == nil)
    let list = try #require(await server.handle(Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#.utf8)))
    let tools = try #require(((try JSONSerialization.jsonObject(with: list) as? [String: Any])?["result"] as? [String: Any])?["tools"] as? [[String: Any]])
    #expect(tools.contains { $0["name"] as? String == "show_photos" })
    // Deleting is off, so "trash" isn't offered.
    #expect(!String(decoding: list, as: UTF8.self).contains("\"trash\""))
}

@Test func junkNeedsOneStrongSignOrTwoThatAgree() {
    let context = Junk.context([], screenshotDays: 30, now: t0.addingTimeInterval(86_400 * 40))
    let plain = Junk.Signals(labels: ["dog"], subject: 0.3, tilt: nil)

    // An old screenshot is junk; a recent one isn't.
    #expect(Junk.judge(photo("old", 0, at: 0, screenshot: true), origin: "", signals: nil, strong: nil, context)?.reason == "old screenshot")
    #expect(Junk.judge(photo("new", 0, at: 86_400 * 35, screenshot: true), origin: "", signals: nil, strong: nil, context) == nil)

    // One weak sign (a poor rating) isn't enough; add a crooked horizon and it is, pending a second opinion.
    let dull = photo("dull", 0, aesthetic: -0.5)
    #expect(Junk.judge(dull, origin: "img_1.heic", signals: plain, strong: nil, context) == nil)
    let crooked = Junk.judge(dull, origin: "img_1.heic", signals: Junk.Signals(labels: ["dog"], subject: 0.3, tilt: 14), strong: nil, context)
    #expect(crooked?.reason == "crooked" && crooked?.sure == false)

    // Pointing at the floor with nothing in frame, and a poor rating: an accidental shot.
    #expect(Junk.judge(dull, origin: "", signals: Junk.Signals(labels: ["floor"], subject: 0, tilt: nil), strong: nil, context)?.reason == "accidental shot")

    // A small image named by WhatsApp is a forward on its own.
    let small = Photo(id: "wa", date: t0, isScreenshot: false, width: 1280, height: 960, analysis: photo("x", 0).analysis)
    #expect(Junk.judge(small, origin: "img-20240101-wa0003.jpg", signals: nil, strong: nil, context)?.reason == "forwarded image")
    // Having no face is never a sign by itself.
    #expect(Junk.judge(photo("landscape", 0), origin: "img_2.heic", signals: plain, strong: nil, context) == nil)
}
