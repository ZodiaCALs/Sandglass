import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import Sandglass

/// Reads one pixel of an image as (r, g, b), with (0, 0) at the top left.
func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
    var data = [UInt8](repeating: 0, count: 4)
    guard let context = CGContext(
        data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return (0, 0, 0) }
    // Draw so that the wanted pixel lands on the context's single pixel.
    context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
    return (Int(data[0]), Int(data[1]), Int(data[2]))
}

private func isRed(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.r > 160 && p.g < 90 && p.b < 90 }
private func isGreen(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.g > 140 && p.r < 110 && p.b < 120 }

@Suite("Decoding")
struct DecoderTests {

    private func nativeSize(_ url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: width, height: height)
    }

    @Test("A JPEG decodes at the requested size, never larger")
    func scaledJPEG() throws {
        let url = Fixtures.sample("DSC_0010.JPG")
        let thumbnail = try #require(ImageDecoder.thumbnail(url: url, maxPixel: 288))
        #expect(thumbnail.longEdge <= 288)
        #expect(thumbnail.origin == .jpeg)
        #expect(!thumbnail.isFullResolution)

        let display = try #require(ImageDecoder.display(url: url, maxPixel: 1024))
        #expect(display.longEdge == 1024, "a screen-sized decode, not the embedded 160 px thumbnail")
    }

    @Test("Full resolution is every pixel of the file, and says so")
    func fullJPEG() throws {
        let url = Fixtures.sample("DSC_0010.JPG")
        let native = try #require(nativeSize(url))
        let full = try #require(ImageDecoder.fullResolution(url: url, allowRawDecode: false))
        #expect(CGSize(width: full.cgImage.width, height: full.cgImage.height) == native)
        #expect(full.isFullResolution)
        #expect(full.sourceSize == native)
    }

    @Test("Decoding leaves colour alone: sRGB in, sRGB out")
    func colourSpaceIsPreserved() throws {
        let image = try #require(ImageDecoder.display(url: Fixtures.sample("DSC_0001.JPG"), maxPixel: 2560))
        #expect(image.cgImage.colorSpace?.name == CGColorSpace.sRGB)
    }

    @Test("A portrait JPEG comes out upright")
    func portraitJPEG() throws {
        let image = try #require(ImageDecoder.display(url: Fixtures.orientation.appendingPathComponent("Portrait_6.JPG"), maxPixel: 2560))
        #expect(image.cgImage.width < image.cgImage.height)
        #expect(image.sourceSize.width < image.sourceSize.height)
    }

    @Test("A NEF shows the camera's full-size JPEG, turned upright by the NEF's own orientation")
    func embeddedPreview() throws {
        let url = Fixtures.raw("Embedded.NEF")
        let image = try #require(ImageDecoder.fullResolution(url: url, allowRawDecode: false))
        #expect(image.origin == .embeddedPreview)
        #expect(image.cgImage.width == 427 && image.cgImage.height == 640, "640×427 stored, orientation 6")
        #expect(image.sourceSize == CGSize(width: 427, height: 640))
        #expect(image.isFullResolution)
        // Stored top-left (red) ends up top-right; the stored bottom edge (green) on the left.
        #expect(isRed(pixel(image.cgImage, x: image.cgImage.width - 12, y: 12)))
        #expect(isGreen(pixel(image.cgImage, x: 6, y: image.cgImage.height / 2)))
    }

    @Test("A scaled NEF decode uses the embedded preview too")
    func embeddedPreviewScaled() throws {
        let image = try #require(ImageDecoder.display(url: Fixtures.raw("Embedded.NEF"), maxPixel: 320))
        #expect(image.origin == .embeddedPreview)
        #expect(image.longEdge == 320)
        #expect(!image.isFullResolution)
    }

    @Test("Other preview layouts decode: big-endian strips and maker-note previews")
    func otherLayouts() throws {
        let strip = try #require(ImageDecoder.fullResolution(url: Fixtures.raw("EmbeddedStrip_BE.NEF"), allowRawDecode: false))
        #expect(strip.cgImage.width == 480 && strip.cgImage.height == 320)

        let maker = try #require(ImageDecoder.fullResolution(url: Fixtures.raw("MakerNotePreview.NEF"), allowRawDecode: false))
        #expect(maker.cgImage.width == 213 && maker.cgImage.height == 320, "orientation 8 turns it upright")

        let corrupt = try #require(ImageDecoder.fullResolution(url: Fixtures.raw("CorruptLength.NEF"), allowRawDecode: false))
        #expect(corrupt.cgImage.width == 107 && corrupt.cgImage.height == 160, "the small preview, orientation 6")
    }

    @Test("A real NEF with no embedded JPEG falls back to what ImageIO offers")
    func realNikonFallsBack() throws {
        let image = try #require(ImageDecoder.display(url: Fixtures.sample("DSC_0008.NEF"), maxPixel: 2560))
        #expect(image.origin == .system)
        #expect(image.cgImage.width < image.cgImage.height, "orientation 6 still applies")
        #expect(image.isFullResolution, "it is all there is, so nothing sharper is requested")
    }

    @Test("Files that cannot be decoded return nil rather than crashing")
    func undecodable() {
        #expect(ImageDecoder.display(url: Fixtures.sample("DSC_0001.NEF"), maxPixel: 1024) == nil,
                "a TIFF named .NEF has no preview macOS can read")
        #expect(ImageDecoder.display(url: Fixtures.raw("Truncated.NEF"), maxPixel: 1024) == nil)
        #expect(ImageDecoder.thumbnail(url: URL(fileURLWithPath: "/tmp/sandglass-missing.JPG"), maxPixel: 128) == nil)
    }

    @Test("Header-only size reads report the oriented size")
    func pixelSize() {
        #expect(ImageDecoder.pixelSize(of: Fixtures.sample("DSC_0010.JPG")) == CGSize(width: 1600, height: 1067))
        let portrait = ImageDecoder.pixelSize(of: Fixtures.orientation.appendingPathComponent("Portrait_6.JPG"))
        #expect((portrait?.width ?? 1) < (portrait?.height ?? 0))
    }
}

/// Photos shot in portrait are stored landscape with an EXIF orientation tag.
/// Each value is checked against Apple's own orientation handling.
@Suite("EXIF orientation")
struct OrientationTests {

    private func reference(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4000
        ] as CFDictionary)
    }

    private func ours(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return Orientation.apply(orientation, to: image)
    }

    /// Fraction of pixels that differ beyond JPEG noise.
    private func mismatch(_ a: CGImage, _ b: CGImage) -> Double {
        func grey(_ image: CGImage) -> [UInt8]? {
            var data = [UInt8](repeating: 0, count: image.width * image.height)
            guard let context = CGContext(
                data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return data
        }
        guard let x = grey(a), let y = grey(b), x.count == y.count else { return 1 }
        var differing = 0
        for index in 0..<x.count where abs(Int(x[index]) - Int(y[index])) > 60 { differing += 1 }
        return Double(differing) / Double(x.count)
    }

    @Test("Portrait photos are oriented exactly as Apple orients them", arguments: [1, 3, 6, 8])
    func matchesApple(orientation: Int) throws {
        let url = Fixtures.orientation.appendingPathComponent("Portrait_\(orientation).JPG")
        let decoded = try #require(ours(url))
        let expected = try #require(reference(url))
        if orientation == 6 || orientation == 8 {
            #expect(decoded.width < decoded.height)
        }
        #expect(decoded.width == expected.width && decoded.height == expected.height)
        #expect(mismatch(decoded, expected) < 0.02, "orientation \(orientation) differs from Apple's")
    }

    @Test("Every orientation produces the right canvas, and 1 is the identity")
    func canvasSizes() throws {
        let size = CGSize(width: 40, height: 30)
        for value in 1...8 {
            let (_, canvas) = Orientation.transform(for: value, size: size)
            #expect(canvas == (Orientation.swapsAxes(value) ? CGSize(width: 30, height: 40) : size))
        }
        let source = try #require(CGImageSourceCreateWithURL(Fixtures.orientation.appendingPathComponent("Portrait_1.JPG") as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(Orientation.apply(1, to: image) === image)
    }
}

@Suite("Metadata")
struct MetadataTests {

    @Test("Reads camera, lens, exposure and copyright from EXIF")
    func readsExif() throws {
        let metadata = try #require(MetadataReader.read(url: Fixtures.sample("DSC_0010.JPG")))
        #expect(metadata.value(for: "Camera") == "NIKON Z 7_2")
        #expect(metadata.value(for: "Lens") == "NIKKOR Z 35mm f/1.8 S")
        #expect(metadata.value(for: "ISO") == "400")
        #expect(metadata.value(for: "White balance") == "Auto")
        #expect(metadata.value(for: "Flash") == "Did not fire")
        #expect(metadata.value(for: "Program") == "Aperture priority")
        #expect(metadata.value(for: "Metering") == "Matrix")
        #expect(metadata.value(for: "Copyright") == "(c) 2024 Sandglass Tests")
        #expect(metadata.exposureSummary?.contains("ISO 400") == true)
    }

    @Test("Reports GPS coordinates with hemisphere references")
    func readsLocation() throws {
        let metadata = try #require(MetadataReader.read(url: Fixtures.sample("DSC_0010.JPG")))
        let latitude = try #require(metadata.value(for: "Latitude"))
        let longitude = try #require(metadata.value(for: "Longitude"))
        #expect(latitude.hasPrefix("51.5") && latitude.hasSuffix("N"), "got \(latitude)")
        #expect(longitude.hasSuffix("W"), "got \(longitude)")
    }

    @Test("Names the file and reports its size and dimensions")
    func readsFileFacts() throws {
        let metadata = try #require(MetadataReader.read(url: Fixtures.sample("DSC_0010.JPG")))
        #expect(metadata.value(for: "Name") == "DSC_0010.JPG")
        #expect(metadata.value(for: "Dimensions")?.hasPrefix("1600 × 1067") == true)
        #expect(metadata.value(for: "Size")?.isEmpty == false)
    }

    @Test("A NEF reports its embedded camera preview")
    func reportsEmbeddedPreview() throws {
        let metadata = try #require(MetadataReader.read(url: Fixtures.raw("Embedded.NEF")))
        #expect(metadata.value(for: "Camera preview") == "640 × 427 JPEG")
    }

    @Test("Files without metadata, or without a file, fail softly")
    func missing() {
        if let metadata = MetadataReader.read(url: Fixtures.sample("DSC_0001.NEF")) {
            #expect(metadata.value(for: "Camera") == nil)
        }
        #expect(MetadataReader.read(url: URL(fileURLWithPath: "/tmp/sandglass-missing-metadata.JPG")) == nil)
    }
}
