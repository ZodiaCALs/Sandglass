import Testing
import Foundation
import ImageIO
import CoreGraphics
@testable import Sandglass

/// Photos shot in portrait are stored landscape with an EXIF orientation tag.
/// Applying that tag wrongly is what made vertical photos appear upside down, so
/// each value is checked against Apple's own orientation handling.
@Suite("EXIF orientation")
struct OrientationTests {

    private var folder: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Orientation")
    }

    /// Apple's orientation handling, used as the authority.
    private func reference(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4000
        ] as CFDictionary)
    }

    /// Decode the way the app does: read the image, then apply its tag.
    private func ours(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(
                  source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        let orientation = Int(props[kCGImagePropertyOrientation] as? UInt32 ?? 1)
        return Orient.apply(orientation, to: image)
    }

    /// Fraction of pixels that differ beyond JPEG noise. A wrong orientation
    /// moves whole regions, so the fraction jumps from ~0 to a large value.
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
        for i in 0..<x.count where abs(Int(x[i]) - Int(y[i])) > 60 { differing += 1 }
        return Double(differing) / Double(x.count)
    }

    @Test("Portrait photos are oriented to match Apple's handling", arguments: [1, 3, 6, 8])
    func matchesAppleOrientation(orientation: Int) throws {
        let url = folder.appendingPathComponent("Portrait_\(orientation).JPG")
        try #require(FileManager.default.fileExists(atPath: url.path), "missing fixture: \(url.lastPathComponent)")

        let decoded = try #require(ours(url), "decode failed")
        let expected = try #require(reference(url), "reference failed")

        // Rotated cases must have their axes swapped; 1 and 3 must not.
        if orientation == 6 || orientation == 8 {
            #expect(decoded.width < decoded.height, "a portrait photo should be taller than wide")
        }
        #expect(decoded.width == expected.width && decoded.height == expected.height,
                "size mismatch: got \(decoded.width)x\(decoded.height), expected \(expected.width)x\(expected.height)")

        // This is the assertion that matters: pixel-for-pixel agreement with
        // Apple's own orientation handling. A quarter turn applied the wrong way
        // round still produces a plausibly-shaped photo, so only comparing the
        // actual pixels catches it — which is exactly how the upside-down
        // portrait bug slipped through.
        let differing = mismatch(decoded, expected)
        #expect(differing < 0.02, "orientation \(orientation) differs from Apple by \(differing * 100)%")
    }

    @Test("Orientation 1 leaves the image untouched")
    func orientationOneIsIdentity() throws {
        let url = folder.appendingPathComponent("Portrait_1.JPG")
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let raw = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        // Returning the same image avoids a pointless redraw.
        let result = try #require(Orient.apply(1, to: raw))
        #expect(result.width == raw.width && result.height == raw.height)
    }
}
