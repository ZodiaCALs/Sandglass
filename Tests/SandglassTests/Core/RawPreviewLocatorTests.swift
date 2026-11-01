import Testing
import Foundation
@testable import Sandglass

/// Finding the camera's own JPEG inside a NEF is what makes NEFs quick to show.
@Suite("Embedded NEF previews")
struct RawPreviewLocatorTests {

    @Test("The full-size preview in a SubIFD is found and preferred")
    func findsLargestPreview() throws {
        let container = try #require(RawPreviewLocator.inspect(fileAt: Fixtures.raw("Embedded.NEF")))
        #expect(container.previews.count == 2, "the IFD1 preview and the SubIFD preview")
        let largest = try #require(container.largestPreview)
        #expect(largest.width == 640 && largest.height == 427)
        #expect(container.orientation == 6)
        #expect(container.make == "NIKON CORPORATION")
        #expect(container.model == "SANDGLASS TEST")

        let data = try Data(contentsOf: Fixtures.raw("Embedded.NEF"))
        #expect(data[largest.offset] == 0xFF && data[largest.offset + 1] == 0xD8, "starts at the SOI marker")
        #expect(largest.byteRange.upperBound <= data.count)
    }

    @Test("Big-endian files and single-strip JPEGs work; lossless raw strips are ignored")
    func bigEndianStrip() throws {
        let container = try #require(RawPreviewLocator.inspect(fileAt: Fixtures.raw("EmbeddedStrip_BE.NEF")))
        #expect(container.previews.count == 1, "the lossless-JPEG raw data is not a preview")
        #expect(container.largestPreview?.width == 480)
        #expect(container.largestPreview?.height == 320)
        #expect(container.orientation == 1)
        #expect(container.model == "SANDGLASS BE")
    }

    @Test("Nikon's maker-note preview is found, with its own byte order and base")
    func makerNotePreview() throws {
        let container = try #require(RawPreviewLocator.inspect(fileAt: Fixtures.raw("MakerNotePreview.NEF")))
        #expect(container.previews.count == 1)
        #expect(container.largestPreview?.width == 320)
        #expect(container.largestPreview?.height == 213)
        #expect(container.orientation == 8)
    }

    @Test("A preview whose length runs off the end of the file is rejected")
    func corruptLength() throws {
        let container = try #require(RawPreviewLocator.inspect(fileAt: Fixtures.raw("CorruptLength.NEF")))
        #expect(container.previews.count == 1)
        #expect(container.largestPreview?.width == 160, "falls back to the small preview")
    }

    @Test("A truncated file yields nothing rather than crashing")
    func truncated() throws {
        let container = RawPreviewLocator.inspect(fileAt: Fixtures.raw("Truncated.NEF"))
        #expect(container?.previews.isEmpty ?? true)
    }

    @Test("A real Nikon NEF without an embedded JPEG reports its orientation")
    func realNikonWithoutJPEG() throws {
        let container = try #require(RawPreviewLocator.inspect(fileAt: Fixtures.sample("DSC_0008.NEF")))
        #expect(container.previews.isEmpty, "this D1X file carries only an RGB thumbnail")
        #expect(container.orientation == 6)
        #expect(container.make == "NIKON CORPORATION")
        #expect(container.model == "NIKON D1X")
    }

    @Test("TIFFs that only pretend to be NEFs have no previews")
    func plainTIFF() throws {
        let container = try #require(RawPreviewLocator.inspect(fileAt: Fixtures.sample("DSC_0001.NEF")))
        #expect(container.previews.isEmpty)
    }

    @Test("Files that are not TIFF are not inspected")
    func notTIFF() {
        #expect(RawPreviewLocator.inspect(fileAt: Fixtures.sample("DSC_0001.JPG")) == nil)
        #expect(RawPreviewLocator.inspect(fileAt: Fixtures.sample("DSC_9999.CR2")) == nil)
        #expect(RawPreviewLocator.inspect(Data()) == nil)
        #expect(RawPreviewLocator.inspect(Data([0x49, 0x49, 0x2A, 0x00])) == nil)
        #expect(RawPreviewLocator.inspect(fileAt: URL(fileURLWithPath: "/nonexistent.NEF")) == nil)
    }

    @Test("Random bytes after a TIFF header never crash the walk")
    func fuzz() {
        var generator = SplitMix64(seed: 0x5A4D_6C61_7373)
        for length in [8, 16, 64, 512, 4096] {
            for _ in 0..<200 {
                var bytes = [UInt8](repeating: 0, count: length)
                for index in bytes.indices { bytes[index] = UInt8(truncatingIfNeeded: generator.next()) }
                let header: [UInt8] = generator.next() % 2 == 0 ? [0x49, 0x49, 0x2A, 0x00] : [0x4D, 0x4D, 0x00, 0x2A]
                bytes.replaceSubrange(0..<4, with: header)
                let container = RawPreviewLocator.inspect(Data(bytes))
                for preview in container?.previews ?? [] {
                    #expect(preview.byteRange.upperBound <= length)
                }
            }
        }
    }

    @Test("JPEG frame headers are read for size, and lossless frames are recognised")
    func jpegFrames() throws {
        let data = try Data(contentsOf: Fixtures.sample("DSC_0001.JPG"))
        let frame = try #require(RawPreviewLocator.jpegFrame(in: data, offset: 0, length: data.count))
        #expect(frame.width > 0 && frame.height > 0)
        #expect(!frame.lossless)

        let lossless = Data([0xFF, 0xD8, 0xFF, 0xC3, 0x00, 0x0B, 0x0C, 0x0F, 0xC0, 0x17, 0x80, 0x01, 0x01, 0x11, 0x00])
        #expect(RawPreviewLocator.jpegFrame(in: lossless, offset: 0, length: lossless.count)?.lossless == true)
        #expect(RawPreviewLocator.jpegFrame(in: Data([0xFF, 0xD8, 0xFF, 0xDA]), offset: 0, length: 4) == nil)
    }
}

/// Deterministic pseudo-random numbers for the fuzz test.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
