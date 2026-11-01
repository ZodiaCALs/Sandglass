import Testing
import Foundation
@testable import Sandglass

@Suite("Variant detection")
struct VariantDetectionTests {

    @Test("Recognises the JPG and NEF extensions, including .jpeg")
    func recognisesExtensions() {
        #expect(FileKind.from(extension: "jpg") == .jpg)
        #expect(FileKind.from(extension: "JPG") == .jpg)
        #expect(FileKind.from(extension: "jpeg") == .jpg)
        #expect(FileKind.from(extension: "nef") == .nef)
        #expect(FileKind.from(extension: "NEF") == .nef)
    }

    @Test("Ignores formats the app does not manage")
    func ignoresOtherFormats() {
        for ext in ["png", "tif", "cr2", "arw", "txt", "heic", ""] {
            #expect(FileKind.from(extension: ext) == nil, "\(ext) should not be handled")
        }
    }
}

@Suite("JPG / NEF pairing")
struct PairingTests {

    @Test("A matching JPG and NEF become one shot, not two")
    func pairsByBaseName() {
        let shots = ShotPairing.pair(urls("DSC_0001.JPG", "DSC_0001.NEF"))
        #expect(shots.count == 1)
        #expect(shots[0].jpgURL?.lastPathComponent == "DSC_0001.JPG")
        #expect(shots[0].nefURL?.lastPathComponent == "DSC_0001.NEF")
        #expect(shots[0].isPaired)
    }

    @Test("Pairing ignores case differences between the two files")
    func pairsCaseInsensitively() {
        let shots = ShotPairing.pair(urls("dsc_0004.jpg", "DSC_0004.NEF"))
        #expect(shots.count == 1)
        #expect(shots[0].isPaired)
    }

    @Test("Treats .jpeg as the JPG half of a pair")
    func pairsJpegAlias() {
        let shots = ShotPairing.pair(urls("IMG_10.jpeg", "IMG_10.NEF"))
        #expect(shots.count == 1)
        #expect(shots[0].isPaired)
    }

    @Test("Keeps unpaired files as single-variant shots")
    func keepsLonelyFiles() {
        let shots = ShotPairing.pair(urls("DSC_0005.NEF", "DSC_0006.JPG"))
        #expect(shots.count == 2)

        let rawOnly = shotNamed(shots, "DSC_0005")
        #expect(rawOnly?.nefURL != nil)
        #expect(rawOnly?.jpgURL == nil)
        #expect(rawOnly?.isPaired == false)
        #expect(rawOnly?.defaultKind == .nef, "a NEF-only shot should open on the NEF")
        #expect(rawOnly?.variantSummary == "NEF only")

        let jpgOnly = shotNamed(shots, "DSC_0006")
        #expect(jpgOnly?.jpgURL != nil)
        #expect(jpgOnly?.nefURL == nil)
        #expect(jpgOnly?.defaultKind == .jpg)
    }

    @Test("Does not fold numerically suffixed files into an unrelated shot")
    func doesNotGuessAtNumericSuffixes() {
        let shots = ShotPairing.pair(urls("IMG_1.JPG", "IMG_1.NEF", "IMG_10.JPG"))
        #expect(shots.count == 2)
        #expect(shotNamed(shots, "IMG_1")?.nefURL?.lastPathComponent == "IMG_1.NEF")
        #expect(shotNamed(shots, "IMG_10")?.jpgURL?.lastPathComponent == "IMG_10.JPG")
        #expect(shotNamed(shots, "IMG_10")?.nefURL == nil)
    }

    @Test("Keeps both files when one shot has duplicate names")
    func keepsDuplicateNamesVisible() {
        let shots = ShotPairing.pair(urls("DSC_1.JPG", "DSC_1.NEF", "DSC_1.JPG"))
        #expect(shots.count == 2)
        #expect(shots.filter { $0.jpgURL != nil }.count == 2)
        #expect(Set(shots.map(\.id)).count == 2, "each entry still needs a distinct id")
    }

    @Test("A duplicate's generated name never collides with a real file")
    func duplicateNamesStayUnique() {
        let shots = ShotPairing.pair(urls("DSC_1.JPG", "DSC_1.JPEG", "DSC_1-2.JPG"))
        #expect(shots.count == 3)
        #expect(Set(shots.map(\.id)).count == 3, "ids: \(shots.map(\.id))")
        #expect(shotNamed(shots, "DSC_1-2")?.jpgURL?.lastPathComponent == "DSC_1-2.JPG")
    }

    @Test("Sorts shots the way Finder does, not lexically")
    func sortsNaturally() {
        let shots = ShotPairing.pair(urls("IMG_10.JPG", "IMG_2.JPG", "IMG_1.JPG"))
        #expect(shots.map(\.baseName) == ["IMG_1", "IMG_2", "IMG_10"])
    }

    @Test("Gives every shot a distinct stable identity")
    func idsAreUnique() {
        let shots = ShotPairing.pair(urls("A.JPG", "A.NEF", "B.JPG", "C.NEF"))
        #expect(Set(shots.map(\.id)).count == shots.count)
        #expect(shots.count == 3)
    }

    @Test("A preferred variant is shown only when the shot has it")
    func preferredKindFallsBack() {
        let shots = ShotPairing.pair(urls("A.JPG", "A.NEF", "B.JPG", "C.NEF"))
        #expect(shotNamed(shots, "A")?.kind(preferring: .nef) == .nef)
        #expect(shotNamed(shots, "B")?.kind(preferring: .nef) == .jpg)
        #expect(shotNamed(shots, "C")?.kind(preferring: .jpg) == .nef)
    }
}

@Suite("Flag selection")
struct FlagSelectionTests {

    @Test("Flagging is independent per variant, so both can be kept")
    func flagsCombineIndependently() {
        var selection = FlagSelection.jpg
        #expect(selection.contains(.jpg))
        #expect(!selection.contains(.nef))
        #expect(selection.label == "JPG")

        selection.insert(.nef)
        #expect(selection.kinds == [.jpg, .nef])
        #expect(selection.label == "JPG + NEF")
        #expect(selection == .both)

        selection.remove(.jpg)
        #expect(selection.kinds == [.nef])
    }

    @Test("An empty selection means the shot is not flagged")
    func emptyIsUnflagged() {
        #expect(FlagSelection([]).isEmpty)
        #expect(FlagSelection([]).kinds.isEmpty)
        #expect(!FlagSelection.jpg.isEmpty)
    }
}

@Suite("Export planning")
struct ExportPlanTests {

    private func makeShots() -> [Shot] {
        ShotPairing.pair(urls("A.JPG", "A.NEF", "B.JPG", "C.NEF", "D.JPG", "D.NEF"))
    }

    @Test("A JPG-only flag exports just the JPG")
    func jpgOnlyExportsJpg() throws {
        let shots = makeShots()
        let a = try #require(shotNamed(shots, "A"))
        let plan = Exporter.plan(shots: shots, flags: [a.id: .jpg])
        #expect(plan.files.map(\.lastPathComponent) == ["A.JPG"])
        #expect(plan.shotCount == 1)
    }

    @Test("A NEF-only flag exports just the NEF")
    func nefOnlyExportsNef() throws {
        let shots = makeShots()
        let a = try #require(shotNamed(shots, "A"))
        let plan = Exporter.plan(shots: shots, flags: [a.id: .nef])
        #expect(plan.files.map(\.lastPathComponent) == ["A.NEF"])
    }

    @Test("Flagging both variants exports both files")
    func bothFlagsExportBoth() throws {
        let shots = makeShots()
        let d = try #require(shotNamed(shots, "D"))
        let plan = Exporter.plan(shots: shots, flags: [d.id: .both])
        #expect(Set(plan.files.map(\.lastPathComponent)) == ["D.JPG", "D.NEF"])
        #expect(plan.shotCount == 1)
    }

    @Test("A flag for a variant that is missing on disk is skipped safely")
    func missingVariantIsSkipped() throws {
        let shots = makeShots()
        let b = try #require(shotNamed(shots, "B"))
        let plan = Exporter.plan(shots: shots, flags: [b.id: .both])
        #expect(plan.files.map(\.lastPathComponent) == ["B.JPG"])
    }

    @Test("Multiple flagged shots export in folder order")
    func exportsInShotOrder() {
        let shots = makeShots()
        var flags: [Shot.ID: FlagSelection] = [:]
        for shot in shots { flags[shot.id] = .jpg }
        let plan = Exporter.plan(shots: shots, flags: flags)
        #expect(plan.files.map(\.lastPathComponent) == ["A.JPG", "B.JPG", "D.JPG"])
        #expect(plan.shotCount == 3)
    }

    @Test("No flags means an empty plan")
    func emptyPlanWhenNothingFlagged() {
        let plan = Exporter.plan(shots: makeShots(), flags: [:])
        #expect(plan.isEmpty)
    }
}

@Suite("Scanning and exporting real files")
struct FileSystemTests {

    @Test("A real folder is scanned into paired shots and noise is ignored")
    func scansRealFolder() throws {
        let source = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: source) }

        try writeFiles(["DSC_0001.JPG", "DSC_0001.NEF", "dsc_0002.jpg", "DSC_0002.NEF", "DSC_0003.NEF"], in: source)
        try writeFiles(["readme.txt", "DSC_0004.CR2", "sheet.png"], in: source)
        let nested = source.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try writeFiles(["DSC_0009.JPG"], in: nested)

        let shots = try FolderScanner.scan(folder: source)
        #expect(shots.count == 3)
        #expect(shots.filter(\.isPaired).count == 2)
        #expect(shotNamed(shots, "DSC_0003")?.variantSummary == "NEF only")
        #expect(!shots.contains { $0.baseName.contains("0009") }, "subfolders are not scanned")
        #expect(!shots.contains { $0.baseName.contains("0004") }, "CR2 is not managed")
    }

    @Test("A folder with no managed images reports a useful error")
    func emptyFolderThrows() throws {
        let source = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: source) }
        try writeFiles(["notes.txt", "photo.png"], in: source)
        #expect(throws: FolderScanner.ScanError.noImages(source)) {
            try FolderScanner.scan(folder: source)
        }
    }

    @Test("A file is not a folder")
    func fileIsNotAFolder() throws {
        let file = Fixtures.sample("DSC_0001.JPG")
        #expect(throws: FolderScanner.ScanError.notAFolder(file)) {
            try FolderScanner.scan(folder: file)
        }
    }

    @Test("The sample shoot pairs the way the README describes")
    func samplesPair() throws {
        let shots = try FolderScanner.scan(folder: Fixtures.sampleShoot)
        #expect(shotNamed(shots, "DSC_0004")?.isPaired == true, ".jpg and .NEF pair")
        #expect(shotNamed(shots, "DSC_0005")?.variantSummary == "NEF only")
        #expect(shotNamed(shots, "DSC_0006")?.variantSummary == "JPG only")
        #expect(shotNamed(shots, "DSC_0002-2")?.isPaired == true, "suffixed names are their own shot")
        #expect(shotNamed(shots, "DSC_9999") == nil, "CR2 is ignored")
        #expect(shotNamed(shots, "DSC_8888") == nil, "subfolders are ignored")
    }

    @Test("Export writes exactly the flagged variants and leaves the source intact")
    func exportWritesFlaggedVariants() async throws {
        let source = try makeTemporaryDirectory()
        let destination = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        try writeFiles(["A.JPG", "A.NEF", "B.JPG", "B.NEF", "C.JPG"], in: source, bytes: 64)
        let shots = try FolderScanner.scan(folder: source)
        let a = try #require(shotNamed(shots, "A"))
        let b = try #require(shotNamed(shots, "B"))
        let plan = Exporter.plan(shots: shots, flags: [a.id: .both, b.id: .nef])
        #expect(plan.totalBytes == 192)

        let progress = ProgressLog()
        let result = await Exporter.run(files: plan.files, destination: destination, mode: .copy) { done, total in
            progress.record(done, total)
        }

        #expect(result.failures.isEmpty)
        #expect(result.copied == 3)
        #expect(result.summary == "3 copied")
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).sorted() == ["A.JPG", "A.NEF", "B.NEF"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: source.path).count == 5)
        #expect(progress.values == [3, 3, 3].enumerated().map { [$0.offset + 1, $0.element] })
    }

    @Test("Move mode takes the flagged files out of the source folder")
    func moveRemovesFromSource() async throws {
        let source = try makeTemporaryDirectory()
        let destination = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        try writeFiles(["A.JPG", "A.NEF"], in: source, bytes: 64)
        let shots = try FolderScanner.scan(folder: source)
        let a = try #require(shotNamed(shots, "A"))
        let plan = Exporter.plan(shots: shots, flags: [a.id: .jpg])

        let result = await Exporter.run(files: plan.files, destination: destination, mode: .move)
        #expect(result.failures.isEmpty)
        #expect(result.moved == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: source.path) == ["A.NEF"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["A.JPG"])
    }

    @Test("Exporting twice never overwrites the first copy")
    func exportDoesNotOverwrite() async throws {
        let source = try makeTemporaryDirectory()
        let destination = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        try writeFiles(["A.JPG"], in: source, bytes: 64)
        let file = source.appendingPathComponent("A.JPG")
        _ = await Exporter.run(files: [file], destination: destination, mode: .copy)
        _ = await Exporter.run(files: [file], destination: destination, mode: .copy)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).sorted() == ["A 2.JPG", "A.JPG"])
    }

    @Test("Exporting into the source folder is skipped rather than duplicating files")
    func exportIntoSourceIsSkipped() async throws {
        let source = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: source) }
        try writeFiles(["A.JPG"], in: source)
        let result = await Exporter.run(files: [source.appendingPathComponent("A.JPG")], destination: source, mode: .copy)
        #expect(result.skipped == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: source.path) == ["A.JPG"])
    }
}

/// Collects progress callbacks, which arrive from a background context.
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[Int]] = []

    func record(_ done: Int, _ total: Int) {
        lock.lock()
        storage.append([done, total])
        lock.unlock()
    }

    var values: [[Int]] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
