import Testing
import Foundation
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
                maxPixel: LibraryModel.fullResolutionPixel
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
            await ThumbnailLoader.shared.thumbnail(for: url, maxPixel: LibraryModel.fullResolutionPixel)
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

    @Test("A decoded bitmap is displayed at one image pixel per device pixel")
    func imageSizeMatchesDisplayScale() {
        // The regression this guards: sizing an NSImage by its pixel count makes
        // it draw at 1x on a 2x display, stretching every pixel across two device
        // pixels — which is exactly what a blurred preview looks like.
        let thumbnail = makeThumbnail(width: 1600, height: 1067)
        let image = LibraryModel.makeImage(from: thumbnail)

        #expect(image.size.width == 1600 / LibraryModel.retinaScale)
        #expect(image.size.height == 1067 / LibraryModel.retinaScale)

        // The bitmap itself must stay at full pixel resolution.
        let rep = image.representations.first
        #expect(rep?.pixelsWide == 1600)
        #expect(rep?.pixelsHigh == 1067)
    }

    @Test("Point size is always half the pixel size at 2x")
    func pointSizeIsHalfPixelSize() {
        #expect(LibraryModel.retinaScale == 2)
        for side in [320, 1400, 4200] {
            let image = LibraryModel.makeImage(from: makeThumbnail(width: side, height: side))
            #expect(image.size.width == CGFloat(side) / 2)
        }
    }

    @Test("The rendered image always has at least the pixels it is drawn into")
    func sufficientPixelsForRetinaPane() {
        // A typical pane is about 800x700 points; at 2x that needs 1600x1400 px.
        let panePoints = CGSize(width: 800, height: 700)
        let needed = max(panePoints.width, panePoints.height) * LibraryModel.retinaScale

        #expect(
            CGFloat(LibraryModel.fullResolutionPixel) >= needed,
            "full-resolution budget must cover a Retina pane"
        )
        #expect(LibraryModel.tilePixel >= 156 * Int(LibraryModel.retinaScale))
        #expect(LibraryModel.prefetchPixel < LibraryModel.fullResolutionPixel)
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
        model.requestThumbnail(for: shot, kind: .jpg, maxPixel: LibraryModel.tilePixel)
        _ = await waitUntil { model.cachedThumbnail(for: shot, kind: .jpg) != nil }

        let tile = try #require(model.cachedThumbnail(for: shot, kind: .jpg))
        #expect(tile.size.width <= CGFloat(LibraryModel.tilePixel) / LibraryModel.retinaScale + 1,
                "grid tile should be small, got \(tile.size)")

        // Now the preview must be able to reach full resolution regardless.
        let becameSharp = await waitUntil {
            model.hasFullResolutionPreview(for: shot, kind: .jpg)
        }
        #expect(becameSharp, "the preview should still reach full resolution after a tile was cached")

        let preview = try #require(model.previewImage(for: shot, kind: .jpg))
        #expect(
            preview.size.width > tile.size.width,
            "preview (\(preview.size)) must be sharper than the tile (\(tile.size))"
        )
        // 1600px source at 2x display scale -> 800 points wide.
        #expect(preview.size.width == 800, "expected native 1600px at 2x, got \(preview.size)")
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
        #expect(model.previewImage(for: paired, kind: .nef) == nil || model.hasFullResolutionPreview(for: paired, kind: .nef) == false,
                "the NEF must not be served the JPG's cached preview")
    }
}
