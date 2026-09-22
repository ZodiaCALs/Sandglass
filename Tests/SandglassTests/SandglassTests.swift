import Testing
import Foundation
import AppKit
import ImageIO
@testable import Sandglass

// MARK: - Helpers

/// Build URLs that look like real files without touching disk.
private func urls(_ names: String...) -> [URL] {
    names.map { URL(fileURLWithPath: "/tmp/shoot/\($0)") }
}

private func shotNamed(_ shots: [Shot], _ name: String) -> Shot? {
    shots.first { $0.baseName.caseInsensitiveCompare(name) == .orderedSame }
}

// MARK: - Variant detection

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

// MARK: - Pairing

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

        let jpgOnly = shotNamed(shots, "DSC_0006")
        #expect(jpgOnly?.jpgURL != nil)
        #expect(jpgOnly?.nefURL == nil)
        #expect(jpgOnly?.defaultKind == .jpg)
    }

    @Test("Does not fold numerically suffixed files into an unrelated shot")
    func doesNotGuessAtNumericSuffixes() {
        // IMG_10 and IMG_1 are different photographs. A suffix-stripping pairing
        // rule would wrongly merge them, so Sandglass matches names exactly.
        let shots = ShotPairing.pair(urls("IMG_1.JPG", "IMG_1.NEF", "IMG_10.JPG"))
        #expect(shots.count == 2)

        let first = shotNamed(shots, "IMG_1")
        #expect(first?.baseName == "IMG_1")
        #expect(first?.nefURL?.lastPathComponent == "IMG_1.NEF")

        let tenth = shotNamed(shots, "IMG_10")
        #expect(tenth?.jpgURL?.lastPathComponent == "IMG_10.JPG")
        #expect(tenth?.nefURL == nil)
    }

    @Test("Keeps both files when one shot has duplicate names")
    func keepsDuplicateNamesVisible() {
        // Two DSC_1.JPG files cannot both be "the JPG half" of one shot, so the
        // extra is surfaced as its own entry rather than hidden.
        let shots = ShotPairing.pair(urls("DSC_1.JPG", "DSC_1.NEF", "DSC_1.JPG"))
        #expect(shots.count == 2)
        #expect(shots.filter { $0.jpgURL != nil }.count == 2)
        #expect(Set(shots.map(\.id)).count == 2, "each entry still needs a distinct id")
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
}

// MARK: - Flagging

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

// MARK: - Export planning

@Suite("Export planning")
struct ExportPlanTests {

    private func makeShots() -> [Shot] {
        ShotPairing.pair(urls("A.JPG", "A.NEF", "B.JPG", "C.NEF", "D.JPG", "D.NEF"))
    }

    @Test("A JPG-only flag exports just the JPG")
    func jpgOnlyExportsJpg() {
        let shots = makeShots()
        let a = shotNamed(shots, "A")!
        let plan = Exporter.plan(shots: shots, flags: [a.id: .jpg])
        #expect(plan.files.map(\.lastPathComponent) == ["A.JPG"])
        #expect(plan.shotCount == 1)
    }

    @Test("A NEF-only flag exports just the NEF")
    func nefOnlyExportsNef() {
        let shots = makeShots()
        let a = shotNamed(shots, "A")!
        let plan = Exporter.plan(shots: shots, flags: [a.id: .nef])
        #expect(plan.files.map(\.lastPathComponent) == ["A.NEF"])
    }

    @Test("Flagging both variants exports both files")
    func bothFlagsExportBoth() {
        let shots = makeShots()
        let d = shotNamed(shots, "D")!
        let plan = Exporter.plan(shots: shots, flags: [d.id: [.jpg, .nef]])
        #expect(Set(plan.files.map(\.lastPathComponent)) == ["D.JPG", "D.NEF"])
        #expect(plan.files.count == 2)
        #expect(plan.shotCount == 1)
    }

    @Test("Unflagged shots contribute nothing")
    func unflaggedShotsAreExcluded() {
        let shots = makeShots()
        let a = shotNamed(shots, "A")!
        let plan = Exporter.plan(shots: shots, flags: [a.id: .jpg])
        #expect(!plan.files.contains { $0.lastPathComponent.hasPrefix("D.") })
    }

    @Test("A flag for a variant that is missing on disk is skipped safely")
    func missingVariantIsSkipped() {
        let shots = makeShots()
        let b = shotNamed(shots, "B")!          // JPG only
        let plan = Exporter.plan(shots: shots, flags: [b.id: [.jpg, .nef]])
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
        #expect(plan.files.isEmpty)
    }
}

// MARK: - Real files on disk

@Suite("Folder scanning and export against real files")
struct FileSystemTests {

    /// A throwaway folder tree for one test.
    private func makeTemporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sandglass-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ names: [String], in folder: URL, bytes: Int = 32) throws {
        for name in names {
            let data = Data(repeating: 0x41, count: bytes)
            try data.write(to: folder.appendingPathComponent(name))
        }
    }

    @Test("A real folder is scanned into paired shots and noise is ignored")
    func scansRealFolder() throws {
        let source = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: source) }

        try write(["DSC_0001.JPG", "DSC_0001.NEF", "dsc_0002.jpg", "DSC_0002.NEF", "DSC_0003.NEF"], in: source)
        // Noise that must be ignored: notes, an unmanaged raw format, and a PNG.
        try write(["readme.txt", "DSC_0004.CR2", "sheet.png"], in: source)
        let sub = source.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try write(["DSC_0009.JPG"], in: sub)

        let shots = try FolderScanner.scan(folder: source)

        #expect(shots.count == 3, "three base names should produce three shots")
        #expect(shots.filter(\.isPaired).count == 2, "two of them are true JPG + NEF pairs")
        #expect(shotNamed(shots, "DSC_0003")?.variantSummary == "NEF only")
        #expect(!shots.contains { $0.baseName.contains("0009") }, "subfolders are not scanned")
        #expect(!shots.contains { $0.baseName.contains("0004") }, "CR2 is not managed by Sandglass")
    }

    @Test("A folder with no managed images reports a useful error")
    func emptyFolderThrows() throws {
        let source = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: source) }
        try write(["notes.txt", "photo.png"], in: source)

        #expect(throws: FolderScanner.ScanError.self) {
            try FolderScanner.scan(folder: source)
        }
    }

    @MainActor
    @Test("Export writes exactly the flagged variants and leaves the source intact")
    func exportWritesFlaggedVariants() async throws {
        let source = try makeTemporaryDirectory()
        let destination = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }

        try write(["A.JPG", "A.NEF", "B.JPG", "B.NEF", "C.JPG"], in: source, bytes: 64)
        let shots = try FolderScanner.scan(folder: source)

        // A: keep both. B: keep only the raw. C: not kept at all.
        let a = shotNamed(shots, "A")!
        let b = shotNamed(shots, "B")!
        let flags: [Shot.ID: FlagSelection] = [a.id: [.jpg, .nef], b.id: .nef]

        let plan = Exporter.plan(shots: shots, flags: flags)
        #expect(Set(plan.files.map(\.lastPathComponent)) == ["A.JPG", "A.NEF", "B.NEF"])

        let result = await Exporter.run(
            files: plan.files,
            destination: destination,
            mode: .copy
        ) { _, _ in }

        #expect(result.failures.isEmpty)
        #expect(result.copied == 3)

        let written = try FileManager.default
            .contentsOfDirectory(atPath: destination.path)
            .sorted()
        #expect(written == ["A.JPG", "A.NEF", "B.NEF"], "only the flagged variants are copied")

        // Copying must never remove anything from the source folder.
        let remaining = try FileManager.default.contentsOfDirectory(atPath: source.path)
        #expect(remaining.count == 5)
    }

    @MainActor
    @Test("Move mode takes the flagged files out of the source folder")
    func moveRemovesFromSource() async throws {
        let source = try makeTemporaryDirectory()
        let destination = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }

        try write(["A.JPG", "A.NEF"], in: source, bytes: 64)
        let shots = try FolderScanner.scan(folder: source)
        let a = shotNamed(shots, "A")!
        let plan = Exporter.plan(shots: shots, flags: [a.id: .jpg])

        let result = await Exporter.run(files: plan.files, destination: destination, mode: .move) { _, _ in }

        #expect(result.failures.isEmpty)
        #expect(result.moved == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: source.path) == ["A.NEF"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["A.JPG"])
    }

    @Test("Exporting twice never overwrites the first copy")
    func exportDoesNotOverwrite() throws {
        let source = try makeTemporaryDirectory()
        let destination = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }

        try write(["A.JPG"], in: source, bytes: 64)
        let original = source.appendingPathComponent("A.JPG")

        let first = Exporter.uniqueDestination(for: original, in: destination)
        try FileManager.default.copyItem(at: original, to: first)
        let second = Exporter.uniqueDestination(for: original, in: destination)
        try FileManager.default.copyItem(at: original, to: second)

        #expect(first.lastPathComponent == "A.JPG")
        #expect(second.lastPathComponent == "A 2.JPG")

        let written = try FileManager.default.contentsOfDirectory(atPath: destination.path).sorted()
        #expect(written == ["A 2.JPG", "A.JPG"])
    }
}

// MARK: - Decoding

@Suite("Preview decoding")
struct ThumbnailTests {

    @Test("ImageIO decodes a JPG and a real NEF for the same shot")
    func decodesBothVariants() async throws {
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SandglassTests
            .deletingLastPathComponent()   // Tests
            .appendingPathComponent("Fixtures/SampleShoot")

        let jpg = folder.appendingPathComponent("DSC_0008.JPG")
        let nef = folder.appendingPathComponent("DSC_0008.NEF")

        try #require(FileManager.default.fileExists(atPath: jpg.path), "fixture missing: \(jpg.path)")
        try #require(FileManager.default.fileExists(atPath: nef.path), "fixture missing: \(nef.path)")

        let jpgThumb = await ThumbnailLoader.shared.thumbnail(for: jpg, maxPixel: 256)
        let nefThumb = await ThumbnailLoader.shared.thumbnail(for: nef, maxPixel: 256)

        let jpgImage = try #require(jpgThumb, "JPG should decode").image
        let nefImage = try #require(nefThumb, "a real NEF should decode").image

        #expect(max(jpgImage.width, jpgImage.height) <= 256)
        #expect(max(nefImage.width, nefImage.height) <= 256)
        #expect(jpgImage.width > 0 && nefImage.width > 0)
    }

    @Test("A NEF whose preview cannot be decoded fails softly instead of crashing")
    func undecodableRawReturnsNil() async throws {
        // Some raw variants carry no embedded preview ImageIO can read. The app
        // must surface that as a nil thumbnail, never a crash.
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/SampleShoot")
        let stripped = folder.appendingPathComponent("DSC_0001.NEF")

        try #require(FileManager.default.fileExists(atPath: stripped.path))
        let result = await ThumbnailLoader.shared.thumbnail(for: stripped, maxPixel: 256)
        #expect(result == nil)
    }

    @Test("A missing or unreadable file decodes to nil rather than crashing")
    func missingFileReturnsNil() async {
        let bogus = URL(fileURLWithPath: "/tmp/sandglass-definitely-missing.JPG")
        let result = await ThumbnailLoader.shared.thumbnail(for: bogus, maxPixel: 128)
        #expect(result == nil)
    }
}

// MARK: - Metadata

@Suite("Metadata reading")
struct MetadataTests {

    private var fixtureFolder: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/SampleShoot")
    }

    @Test("Reads camera, lens and ISO from EXIF")
    func readsFullExif() throws {
        let url = fixtureFolder.appendingPathComponent("DSC_0010.JPG")
        let metadata = try #require(MetadataReader.read(url: url), "fixture should carry metadata")

        #expect(metadata.value(for: "Camera") == "NIKON Z 7_2")
        #expect(metadata.value(for: "Lens") == "NIKKOR Z 35mm f/1.8 S")
        #expect(metadata.value(for: "ISO") == "400")
        #expect(metadata.value(for: "White balance") == "Auto")
        #expect(metadata.value(for: "Flash") == "Did not fire")
        #expect(metadata.value(for: "Program") == "Aperture priority")
        #expect(metadata.value(for: "Metering") == "Pattern")
        #expect(metadata.value(for: "Copyright") == "(c) 2024 Sandglass Tests")
    }

    @Test("Reports GPS coordinates with hemisphere references")
    func readsLocation() throws {
        let url = fixtureFolder.appendingPathComponent("DSC_0010.JPG")
        let metadata = try #require(MetadataReader.read(url: url))

        let latitude = try #require(metadata.value(for: "Latitude"))
        let longitude = try #require(metadata.value(for: "Longitude"))
        #expect(latitude.hasPrefix("51.5"), "got \(latitude)")
        #expect(latitude.hasSuffix("N"), "got \(latitude)")
        #expect(longitude.hasSuffix("W"), "got \(longitude)")
        #expect(metadata.sections.contains { $0.title == "Location" })
    }

    @Test("Names the file and reports its size and dimensions")
    func readsFileFacts() throws {
        let url = fixtureFolder.appendingPathComponent("DSC_0010.JPG")
        let metadata = try #require(MetadataReader.read(url: url))

        #expect(metadata.value(for: "Name") == "DSC_0010.JPG")
        #expect(metadata.value(for: "Dimensions") == "1600 × 1067")
        #expect(metadata.value(for: "File size")?.isEmpty == false)
    }

    @Test("Formats shutter speeds the way a camera displays them")
    func formatsShutterSpeed() {
        // Fast speeds read as fractions, not as 0.004.
        #expect(MetadataReader.shutterString(1.0 / 250) == "1/250 s")
        #expect(MetadataReader.shutterString(1.0 / 60) == "1/60 s")
        #expect(MetadataReader.shutterString(1.0 / 8000) == "1/8000 s")
        // A second or longer reads as a duration.
        #expect(MetadataReader.shutterString(1) == "1 s")
        #expect(MetadataReader.shutterString(2.5) == "2.5 s")
        #expect(MetadataReader.shutterString(30) == "30 s")
    }

    @Test("Trims trailing zeros from numeric values")
    func trimsNumbers() {
        #expect(MetadataReader.trim(2.8) == "2.8")
        #expect(MetadataReader.trim(4.0) == "4")
        #expect(MetadataReader.trim(35.0) == "35")
        #expect(MetadataReader.trim(-0.3) == "-0.3")
        #expect(MetadataReader.trim(10.0) == "10")
    }

    @Test("Names exposure programs and metering modes")
    func namesEnums() {
        #expect(MetadataReader.exposureProgram(1) == "Manual")
        #expect(MetadataReader.exposureProgram(2) == "Program AE")
        #expect(MetadataReader.exposureProgram(3) == "Aperture priority")
        #expect(MetadataReader.exposureProgram(4) == "Shutter priority")
        #expect(MetadataReader.exposureProgram(99) == "Not defined")

        #expect(MetadataReader.meteringMode(2) == "Center-weighted")
        #expect(MetadataReader.meteringMode(3) == "Spot")
        #expect(MetadataReader.meteringMode(5) == "Pattern")
        #expect(MetadataReader.meteringMode(99) == "Unknown")
    }

    @Test("A file with no metadata reports nothing rather than failing")
    func handlesMissingMetadata() throws {
        // The synthetic raw fixtures carry no EXIF at all.
        let url = fixtureFolder.appendingPathComponent("DSC_0001.NEF")
        try #require(FileManager.default.fileExists(atPath: url.path))

        let metadata = MetadataReader.read(url: url)
        // Either nil, or sections that contain no camera data.
        if let metadata {
            #expect(metadata.value(for: "Camera") == nil)
            #expect(metadata.value(for: "ISO") == nil)
        }
    }

    @Test("An unreadable file returns nil instead of crashing")
    func handlesUnreadableFile() {
        let bogus = URL(fileURLWithPath: "/tmp/sandglass-missing-metadata.JPG")
        #expect(MetadataReader.read(url: bogus) == nil)
    }
}

// MARK: - Preview sharpness

@Suite("Preview resolution")
struct PreviewResolutionTests {

    private var fixtureFolder: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/SampleShoot")
    }

    /// Native pixel size of a file, straight from its metadata.
    private func nativeSize(_ url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    @Test("The large preview is never smaller than the source image")
    func previewIsNotDownscaled() async throws {
        let url = fixtureFolder.appendingPathComponent("DSC_0001.JPG")
        let native = try #require(nativeSize(url), "fixture should report its size")

        // This is what the preview pane asks for.
        let preview = try #require(
            await ThumbnailLoader.shared.thumbnail(
                for: url,
                maxPixel: ThumbnailLoader.maximumPreviewPixel
            ),
            "preview should decode"
        )

        let longEdge = max(preview.image.width, preview.image.height)
        let nativeLongEdge = max(native.width, native.height)

        #expect(
            longEdge >= nativeLongEdge,
            "preview \(preview.image.width)x\(preview.image.height) must not be smaller than the native \(native.width)x\(native.height)"
        )
        #expect(preview.image.width == native.width, "width must match the source exactly")
        #expect(preview.image.height == native.height, "height must match the source exactly")
    }

    @Test("A tile-sized request is genuinely downscaled")
    func tileRequestIsSmall() async throws {
        let url = fixtureFolder.appendingPathComponent("DSC_0001.JPG")
        let tile = try #require(
            await ThumbnailLoader.shared.thumbnail(for: url, maxPixel: 320),
            "tile should decode"
        )
        // The grid must stay cheap: tiles are capped, the big pane is not.
        #expect(max(tile.image.width, tile.image.height) <= 320)
    }

    @Test("Decoding leaves the pixels untouched — no colour transform")
    func previewPreservesColourSpace() async throws {
        let url = fixtureFolder.appendingPathComponent("DSC_0001.JPG")
        let preview = try #require(
            await ThumbnailLoader.shared.thumbnail(for: url, maxPixel: ThumbnailLoader.maximumPreviewPixel)
        )
        // sRGB in, sRGB out: nothing is converted, tinted or filtered.
        let name = preview.image.colorSpace?.name
        #expect(name == CGColorSpace.sRGB, "expected sRGB, got \(String(describing: name))")
    }
}

// MARK: - Display sizing

@Suite("Preview display sizing")
struct DisplaySizingTests {

    private func makeThumbnail(width: Int, height: Int) -> Thumbnail {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return Thumbnail(
            image: context.makeImage()!,
            pixelSize: CGSize(width: width, height: height)
        )
    }

    @Test("Bitmaps are drawn at one image pixel per device pixel")
    func displaySizeMatchesScale() {
        // The regression this guards: sizing an image by its pixel count makes it
        // draw at 1x on a 2x display, stretching every pixel across two device
        // pixels — which is exactly what a blurred preview looks like.
        let thumbnail = makeThumbnail(width: 1600, height: 1067)
        let size = LibraryModel.displaySize(for: thumbnail)

        #expect(size.width == 1600 / LibraryModel.retinaScale)
        #expect(size.height == 1067 / LibraryModel.retinaScale)
        // The bitmap itself must stay at full pixel resolution.
        #expect(thumbnail.image.width == 1600)
        #expect(thumbnail.image.height == 1067)
    }

    @Test("Point size is always half the pixel size at 2x")
    func pointSizeIsHalfPixelSize() {
        #expect(LibraryModel.retinaScale == 2)
        for side in [320, 1400, 4200] {
            let size = LibraryModel.displaySize(for: makeThumbnail(width: side, height: side))
            #expect(size.width == CGFloat(side) / 2)
        }
    }

    @Test("Budgets cover a Retina pane without over-decoding")
    func budgetsAreSensible() {
        let panePoints = CGSize(width: 800, height: 700)
        let needed = max(panePoints.width, panePoints.height) * LibraryModel.retinaScale

        #expect(
            CGFloat(ThumbnailLoader.maximumPreviewPixel) >= needed,
            "full-resolution budget must cover a Retina pane"
        )
        #expect(ThumbnailLoader.tilePixel >= 156 * Int(LibraryModel.retinaScale))
        #expect(ThumbnailLoader.prefetchPixel < ThumbnailLoader.maximumPreviewPixel)
    }
}

// MARK: - Preview pipeline end to end

@Suite("Preview pipeline")
@MainActor
struct PreviewPipelineTests {

    private var fixtureFolder: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/SampleShoot")
    }

    /// Load a folder and wait for the scan to settle.
    private func loadedModel() async throws -> LibraryModel {
        let model = LibraryModel()
        model.openFolder(at: fixtureFolder)
        for _ in 0..<200 where model.isScanning {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        try #require(!model.shots.isEmpty, "fixtures should load")
        return model
    }

    /// Poll until `condition` holds, or give up.
    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        timeout: TimeInterval = 5
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    @Test("A grid tile never displaces the large preview")
    func tileAndPreviewDoNotCollide() async throws {
        let model = try await loadedModel()
        let shot = try #require(model.shots.first { $0.jpgURL != nil })
        model.go(to: 0)

        // Ask for the grid tile first, exactly as the filmstrip does, then wait
        // for the tile to land before looking at the preview pane.
        model.requestThumbnail(for: shot, kind: .jpg, maxPixel: ThumbnailLoader.tilePixel)
        _ = await waitUntil { model.cachedThumbnail(for: shot, kind: .jpg) != nil }

        let tile = try #require(model.cachedThumbnail(for: shot, kind: .jpg))
        #expect(tile.width <= ThumbnailLoader.tilePixel,
                "grid tile should be small, got \(tile.width)px")

        // Now the preview must be able to reach full resolution regardless.
        let becameSharp = await waitUntil {
            model.hasFullResolutionPreview(for: shot, kind: .jpg)
        }
        #expect(becameSharp, "the preview should still reach full resolution after a tile was cached")

        let preview = try #require(model.previewCGImage(for: shot, kind: .jpg))
        #expect(
            preview.width > tile.width,
            "preview (\(preview.width)px) must be sharper than the tile (\(tile.width)px)"
        )
        // The source is 1600px, so the preview must be at native resolution.
        #expect(preview.width == 1600, "expected native 1600px, got \(preview.width)px")
    }

    @Test("Metadata is read on demand and then cached")
    func metadataLoadsAndCaches() async throws {
        let model = try await loadedModel()
        let shot = try #require(model.shots.first { $0.baseName == "DSC_0010" })
        model.go(to: try #require(model.shots.firstIndex(of: shot)))

        #expect(model.metadata(for: shot, kind: .jpg) == nil, "nothing loaded yet")
        model.loadMetadata(for: shot, kind: .jpg)

        let loaded = await waitUntil { model.metadata(for: shot, kind: .jpg) != nil }
        #expect(loaded, "metadata should load")

        let metadata = try #require(model.metadata(for: shot, kind: .jpg))
        #expect(metadata.value(for: "Camera") == "NIKON Z 7_2")
        #expect(model.isLoadingMetadata(for: shot, kind: .jpg) == false, "loading flag should clear")
    }

    @Test("The decode budget follows the pane size instead of being fixed")
    func budgetTracksCanvas() {
        let model = LibraryModel()

        // Default canvas: roughly the shipping window's preview pane.
        let initial = model.previewPixelBudget

        // A big window should ask for more pixels...
        model.reportCanvasSize(CGSize(width: 1100, height: 900))
        let enlarged = model.previewPixelBudget
        #expect(enlarged > initial, "a larger pane should decode more pixels")

        // ...and a small one should stop paying for them.
        model.reportCanvasSize(CGSize(width: 400, height: 300))
        let shrunk = model.previewPixelBudget
        #expect(shrunk < initial, "a smaller pane should decode fewer pixels")

        // Always enough for the pane at 2x, never past the ceiling.
        #expect(shrunk >= 1024)
        #expect(enlarged <= ThumbnailLoader.maximumPreviewPixel)
    }

    @Test("Switching variant re-resolves the preview for that file")
    func switchingVariantChangesPreview() async throws {
        let model = try await loadedModel()
        let paired = try #require(model.shots.first { $0.isPaired })
        model.go(to: try #require(model.shots.firstIndex(of: paired)))

        model.setKind(.jpg)
        let gotJPG = await waitUntil { model.hasFullResolutionPreview(for: paired, kind: .jpg) }
        #expect(gotJPG, "JPG preview should load")

        model.setKind(.nef)
        #expect(model.kind == .nef)
        // A different file means a different cache entry, not the JPG's image.
        #expect(
            model.previewCGImage(for: paired, kind: .nef) == nil
                || model.hasFullResolutionPreview(for: paired, kind: .nef) == false,
            "the NEF must not be served the JPG's cached preview"
        )
    }
}

// MARK: - Rendered sharpness

@Suite("Rendered sharpness")
@MainActor
struct RenderedSharpnessTests {

    /// A checkerboard with a known cell size: exact, countable detail.
    private func checkerboard(side: Int, cell: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        for y in stride(from: 0, to: side, by: cell) {
            for x in stride(from: 0, to: side, by: cell) {
                let on = ((x / cell) + (y / cell)) % 2 == 0
                context.setFillColor(gray: on ? 1 : 0, alpha: 1)
                context.fill(CGRect(x: x, y: y, width: cell, height: cell))
            }
        }
        return context.makeImage()!
    }

    private struct Render {
        let grey: [UInt8]
        let width: Int
        let height: Int
    }

    /// Render the canvas through its layer tree, which is what reaches the screen.
    ///
    /// `cacheDisplay(in:to:)` is deliberately avoided: it re-rasterises the view
    /// and smooths the result, so it cannot answer a question about sharpness.
    ///
    /// Note the vertical flip: `CALayer.render(in:)` draws in unflipped layer
    /// coordinates, so row 0 of the output is the *bottom* of the view.
    private func render(_ canvas: ImageCanvasView, size: CGSize) -> Render? {
        canvas.frame = CGRect(origin: .zero, size: size)
        canvas.layout()
        let width = Int(size.width)
        let height = Int(size.height)
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .none
        canvas.layer?.render(in: context)
        guard let image = context.makeImage() else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let grey = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        grey.interpolationQuality = .none
        grey.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Render(grey: pixels, width: width, height: height)
    }

    /// Lengths of the alternating runs along one row.
    private func runs(_ render: Render, row: Int) -> [Int] {
        var lengths: [Int] = []
        var current = render.grey[row * render.width] > 127
        var length = 1
        for x in 1..<render.width {
            let on = render.grey[row * render.width + x] > 127
            if on == current { length += 1 } else { lengths.append(length); current = on; length = 1 }
        }
        lengths.append(length)
        return lengths
    }

    /// Pixels that are neither black nor white — the signature of smoothing.
    private func intermediatePixels(_ render: Render) -> Int {
        render.grey.filter { $0 > 40 && $0 < 215 }.count
    }

    @Test("Zoom magnifies real pixels: cell size scales exactly, with no smoothing")
    func zoomIsPixelExact() throws {
        let cell = 3
        let side = 300
        let canvas = ImageCanvasView()
        // Same size as the pane, so the fit scale is exactly 1 and any softening
        // would have to come from the zoom path itself.
        canvas.setImage(checkerboard(side: side, cell: cell), resetZoom: true)

        for zoom in [1, 2, 3, 4] {
            canvas.setZoomFromUI(CGFloat(zoom))
            let output = try #require(render(canvas, size: CGSize(width: side, height: side)))
            let row = side / 2

            #expect(
                intermediatePixels(output) == 0,
                "zoom \(zoom)x produced softened pixels — the bitmap is being interpolated"
            )

            // Interior runs must all be exactly cell * zoom wide.
            let interior = runs(output, row: row).dropFirst().dropLast()
            let expected = cell * zoom
            let wrong = interior.filter { $0 != expected }
            #expect(
                wrong.isEmpty,
                "zoom \(zoom)x: expected \(expected)px runs, found \(Array(interior.prefix(6)))"
            )
        }
    }

    @Test("Fitting a photo to the pane keeps its aspect ratio and fills the frame")
    func aspectFitPreserved() throws {
        // A 4:1 image in a square pane must letterbox, leaving the top empty.
        let context = CGContext(
            data: nil, width: 400, height: 100,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 100))

        let canvas = ImageCanvasView()
        canvas.setImage(context.makeImage()!, resetZoom: true)
        let output = try #require(render(canvas, size: CGSize(width: 300, height: 300)))

        // Rows well away from the centre band are letterbox: uniformly black.
        // (Row 0 is the bottom in layer coordinates; the band is centred either way.)
        let topRow = (0..<output.width).map { output.grey[10 * output.width + $0] }
        #expect(topRow.allSatisfy { $0 < 20 }, "a 4:1 photo should letterbox in a square pane")

        // Middle rows: the photo itself, uniformly white.
        let midRow = (0..<output.width).map { output.grey[150 * output.width + $0] }
        #expect(midRow.allSatisfy { $0 > 235 }, "the photo should fill the middle band")
    }

    /// Where the centre of the pane sits within the image, derived from the
    /// drawn frame. Unambiguous, unlike `CALayer.convert` on a transformed layer.
    private func centreInImage(_ canvas: ImageCanvasView, pane: CGSize, side: Int) -> CGPoint {
        let frame = canvas.imageContentsLayer.frame
        let drawn = Double(side) * Double(canvas.fitScaleValue) * Double(canvas.zoom)
        return CGPoint(
            x: (Double(pane.width) / 2 - Double(frame.minX)) / drawn * Double(side),
            y: (Double(pane.height) / 2 - Double(frame.minY)) / drawn * Double(side)
        )
    }

    private func solidImage(side: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()!
    }

    @Test("Zooming about an off-centre point never accumulates drift")
    func zoomDoesNotDrift() throws {
        let side = 600
        let pane = CGSize(width: 800, height: 600)
        let canvas = ImageCanvasView()
        canvas.setImage(solidImage(side: side), resetZoom: true)
        canvas.frame = CGRect(origin: .zero, size: pane)
        canvas.layout()

        let start = centreInImage(canvas, pane: pane, side: side)
        #expect(abs(start.x - 300) < 0.5 && abs(start.y - 300) < 0.5, "should start centred")

        // A pinch into the bottom-right corner, then all the way back out.
        let anchor = CGPoint(x: 780, y: 570)
        for step in 1...30 {
            canvas.setZoom(anchor: anchor, value: 1 + CGFloat(step) * 0.08)
        }
        for step in stride(from: 30, through: 1, by: -1) {
            canvas.setZoom(anchor: anchor, value: 1 + CGFloat(step) * 0.08)
        }

        // Anchored zoom legitimately leaves the photo shifted; the invariant is
        // that resetting returns it exactly, with no residue from the gestures.
        canvas.resetZoom()
        let after = centreInImage(canvas, pane: pane, side: side)
        #expect(abs(after.x - 300) < 0.5, "x drifted to \(after.x) after zooming")
        #expect(abs(after.y - 300) < 0.5, "y drifted to \(after.y) after zooming")
    }

    @Test("Resizing the pane never slides the photo into a corner")
    func resizeDoesNotDrift() throws {
        let side = 600
        let canvas = ImageCanvasView()
        canvas.setImage(solidImage(side: side), resetZoom: true)
        var pane = CGSize(width: 800, height: 600)
        canvas.frame = CGRect(origin: .zero, size: pane)
        canvas.layout()

        canvas.setZoomFromUI(3)

        // Repeated resizes, including while zoomed in: the centred part of the
        // photo must not move, and nothing may accumulate.
        for _ in 0..<40 {
            pane = CGSize(width: 640, height: 480)
            canvas.frame = CGRect(origin: .zero, size: pane)
            canvas.layout()
            pane = CGSize(width: 1000, height: 760)
            canvas.frame = CGRect(origin: .zero, size: pane)
            canvas.layout()
        }
        pane = CGSize(width: 800, height: 600)
        canvas.frame = CGRect(origin: .zero, size: pane)
        canvas.layout()

        let zoomed = centreInImage(canvas, pane: pane, side: side)
        #expect(abs(zoomed.x - 300) < 1, "x drifted to \(zoomed.x) while zoomed and resizing")
        #expect(abs(zoomed.y - 300) < 1, "y drifted to \(zoomed.y) while zoomed and resizing")

        canvas.resetZoom()
        let fitted = centreInImage(canvas, pane: pane, side: side)
        #expect(abs(fitted.x - 300) < 0.5, "x drifted to \(fitted.x) after reset")
        #expect(abs(fitted.y - 300) < 0.5, "y drifted to \(fitted.y) after reset")
    }

    @Test("A mouse wheel zooms, a trackpad two-finger scroll pans")
    func scrollGestureRouting() {
        typealias Action = ImageCanvasView.ScrollAction

        // A wheel has detents, not precise deltas: zoom about the pointer.
        #expect(
            ImageCanvasView.scrollAction(scrollingDeltaY: 1, hasPreciseDeltas: false, modifierFlags: [])
                == .zoom(factor: 1 + ImageCanvasView.wheelZoomRate)
        )
        // Rolling the other way zooms out.
        if case .zoom(let factor)? = ImageCanvasView.scrollAction(
            scrollingDeltaY: -1, hasPreciseDeltas: false, modifierFlags: []
        ) {
            #expect(factor < 1, "scrolling down should zoom out, got factor \(factor)")
        } else {
            Issue.record("a downward wheel notch should zoom out")
        }

        // A trackpad pans by default...
        #expect(
            ImageCanvasView.scrollAction(scrollingDeltaY: 4, hasPreciseDeltas: true, modifierFlags: [])
                == .pan
        )
        // ...and zooms with ⌘ or ⌥ held.
        for flags: NSEvent.ModifierFlags in [.command, .option] {
            if case .zoom? = ImageCanvasView.scrollAction(
                scrollingDeltaY: 4, hasPreciseDeltas: true, modifierFlags: flags
            ) {} else {
                Issue.record("modifier-scroll on a trackpad should zoom")
            }
        }

        // An event with no movement does nothing at all.
        #expect(
            ImageCanvasView.scrollAction(scrollingDeltaY: 0, hasPreciseDeltas: false, modifierFlags: []) == nil
        )
    }

    @Test("Every viewport change carries a new tick")
    func viewportTickAdvances() throws {
        let side = 600
        let pane = CGSize(width: 800, height: 600)
        let canvas = ImageCanvasView()
        canvas.setImage(solidImage(side: side), resetZoom: true)
        canvas.frame = CGRect(origin: .zero, size: pane)
        canvas.layout()

        var ticks: [Int] = []
        var widthsByZoom: [CGFloat: CGFloat] = [:]
        canvas.onViewportChanged = { region, tick in
            ticks.append(tick)
            widthsByZoom[canvas.zoom] = region.width
        }

        canvas.setZoomFromUI(2)
        canvas.setZoomFromUI(4)
        canvas.resetZoom()

        #expect(ticks.count == 3, "expected one report per change, got \(ticks.count)")
        // Strictly increasing, so a view comparing only the tick still redraws.
        #expect(ticks == ticks.sorted(), "ticks must increase: \(ticks)")
        #expect(Set(ticks).count == ticks.count, "ticks must be unique: \(ticks)")

        // The region genuinely narrows as the photo is magnified, which is what
        // the navigator rectangle draws.
        let atFit = try #require(widthsByZoom[1], "fit should be reported")
        let at2x = try #require(widthsByZoom[2], "2x should be reported")
        let at4x = try #require(widthsByZoom[4], "4x should be reported")
        #expect(atFit > at2x, "zooming in should shrink the visible region")
        #expect(at2x > at4x, "zooming further in should shrink it again")
        #expect(abs(atFit - 1.0) < 0.001, "at fit the whole photo is visible")
    }

    @Test("The photo can never be panned out of view")
    func panningStaysInBounds() throws {
        let side = 600
        let pane = CGSize(width: 800, height: 600)
        let canvas = ImageCanvasView()
        canvas.setImage(solidImage(side: side), resetZoom: true)
        canvas.frame = CGRect(origin: .zero, size: pane)
        canvas.layout()

        // At fit the photo exactly fills one axis, so it must stay centred.
        #expect(canvas.zoom == 1)
        var centre = centreInImage(canvas, pane: pane, side: side)
        #expect(abs(centre.x - 300) < 0.5 && abs(centre.y - 300) < 0.5)

        // Zoomed to 2x, the visible area is 300x300 image px within a 800x600
        // pane, so the centre may range over [150, 450] and no further.
        canvas.setZoomFromUI(2)
        canvas.centreOn(normalised: CGPoint(x: 1, y: 1))   // hard bottom-right
        centre = centreInImage(canvas, pane: pane, side: side)
        #expect(centre.x <= 450.5, "centre ran past the right edge: \(centre.x)")
        #expect(centre.y <= 450.5, "centre ran past the bottom edge: \(centre.y)")

        canvas.centreOn(normalised: CGPoint(x: 0, y: 0))   // hard top-left
        centre = centreInImage(canvas, pane: pane, side: side)
        #expect(centre.x >= 149.5, "centre ran past the left edge: \(centre.x)")
        #expect(centre.y >= 149.5, "centre ran past the top edge: \(centre.y)")
    }
}
