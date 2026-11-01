import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// A decoded bitmap ready for the screen, safe to hand between threads.
///
/// `CGImage` is immutable, so sharing one is safe.
struct DecodedImage: @unchecked Sendable {

    enum Origin: String, Sendable {
        /// Decoded from a JPEG file.
        case jpeg
        /// The camera's own JPEG rendering, found inside a NEF.
        case embeddedPreview
        /// Demosaiced from the raw sensor data.
        case raw
        /// Whatever ImageIO offered — typically a small embedded thumbnail.
        case system

        var label: String {
            switch self {
            case .jpeg: "JPEG"
            case .embeddedPreview: "Camera preview"
            case .raw: "Raw decode"
            case .system: "Embedded thumbnail"
            }
        }
    }

    let cgImage: CGImage
    let origin: Origin
    /// The full, oriented pixel size of the picture this bitmap stands for.
    let sourceSize: CGSize
    /// True when this bitmap has every pixel the source can provide, so asking
    /// for a sharper one would gain nothing.
    let isFullResolution: Bool

    var pixelSize: CGSize { CGSize(width: cgImage.width, height: cgImage.height) }
    var longEdge: Int { max(cgImage.width, cgImage.height) }
    var byteCost: Int { cgImage.bytesPerRow * cgImage.height }
}

/// Decodes photos with ImageIO, always off the main thread, at exactly the size
/// they are needed.
///
/// Three things make this fast:
///
/// 1. **Decode to the size on screen.** ImageIO's thumbnail path scales a JPEG
///    while decoding it (in the DCT domain), so a 24 MP file reaches a
///    screen-sized bitmap in a fraction of the time — and a sixth of the memory —
///    of a full decode. Full resolution is decoded only when zooming needs it.
/// 2. **Use the camera's JPEG for NEFs.** Nikon stores a full-size JPEG rendering
///    in every NEF. `RawPreviewLocator` finds it without parsing anything else,
///    and decoding it is as cheap as decoding a JPEG file. Demosaicing the raw is
///    the last resort, used only when a camera embedded a small preview.
/// 3. **Decode eagerly.** `kCGImageSourceShouldCacheImmediately` makes the
///    decode happen here, on a background thread, instead of lazily on the main
///    thread the first time the bitmap is drawn.
///
/// Colour is never touched: bitmaps keep the file's colour space, and Core
/// Animation colour-matches them to the display.
enum ImageDecoder {

    /// Nothing larger than this is decoded whole; an extreme scan is scaled on
    /// decode so it cannot exhaust memory. (A 12000 px photo is ~380 MB decoded.)
    static let fullResolutionCeiling = 12_000

    enum Request: Sendable, Equatable {
        /// Long edge at most this many pixels.
        case scaled(Int)
        /// Every pixel available (up to the ceiling).
        case full
    }

    /// A small rendition for the thumbnail browser.
    static func thumbnail(url: URL, maxPixel: Int) -> DecodedImage? {
        decode(url: url, request: .scaled(maxPixel), allowRawDecode: false)
    }

    /// A rendition sized for the photo pane.
    static func display(url: URL, maxPixel: Int) -> DecodedImage? {
        decode(url: url, request: .scaled(maxPixel), allowRawDecode: false)
    }

    /// Every pixel, for inspecting detail when zoomed in.
    static func fullResolution(url: URL, allowRawDecode: Bool) -> DecodedImage? {
        decode(url: url, request: .full, allowRawDecode: allowRawDecode)
    }

    static func decode(url: URL, request: Request, allowRawDecode: Bool) -> DecodedImage? {
        switch FileKind.from(url: url) {
        case .nef:
            return decodeRaw(url: url, request: request, allowRawDecode: allowRawDecode)
        default:
            return decodeImage(url: url, request: request)
        }
    }

    /// The oriented pixel size a file reports for itself (header only, no decode).
    static func pixelSize(of url: URL) -> CGSize? {
        guard let source = makeSource(url) else { return nil }
        return orientedSize(of: source)
    }

    // MARK: JPEG and other image files

    private static func decodeImage(url: URL, request: Request) -> DecodedImage? {
        guard let source = makeSource(url) else { return nil }
        let size = orientedSize(of: source)
        let native = size.map { Int(max($0.width, $0.height)) } ?? fullResolutionCeiling
        let target = pixels(for: request, native: native)
        guard let image = thumbnail(from: source, maxPixel: target, applyOrientation: true, fromFullImage: true) else {
            return nil
        }
        let sourceSize = size ?? CGSize(width: image.width, height: image.height)
        return DecodedImage(
            cgImage: image,
            origin: .jpeg,
            sourceSize: sourceSize,
            isFullResolution: max(image.width, image.height) >= Int(max(sourceSize.width, sourceSize.height))
        )
    }

    // MARK: NEF

    private static func decodeRaw(url: URL, request: Request, allowRawDecode: Bool) -> DecodedImage? {
        let data = try? Data(contentsOf: url, options: [.alwaysMapped])
        let container = data.flatMap { RawPreviewLocator.inspect($0) }
        let preview = container?.largestPreview

        if request == .full, allowRawDecode,
           let developed = decodeSensorData(url: url, comparedWith: preview) {
            return developed
        }

        if let data, let container, let preview,
           let image = decodeEmbedded(preview, in: data, orientation: container.orientation, request: request) {
            return image
        }

        // No usable embedded JPEG: take whatever ImageIO can offer.
        guard let source = makeSource(url) else { return nil }
        let target = pixels(for: request, native: fullResolutionCeiling)
        guard let image = thumbnail(from: source, maxPixel: target, applyOrientation: true, fromFullImage: false) else {
            return nil
        }
        return DecodedImage(
            cgImage: image,
            origin: .system,
            sourceSize: CGSize(width: image.width, height: image.height),
            // Smaller than asked for means it is all there is.
            isFullResolution: request == .full || max(image.width, image.height) < target
        )
    }

    /// The camera's JPEG, scaled to the request and turned upright.
    private static func decodeEmbedded(
        _ preview: EmbeddedJPEG,
        in data: Data,
        orientation: Int,
        request: Request
    ) -> DecodedImage? {
        let start = data.startIndex + preview.offset
        let bytes = data.subdata(in: start ..< start + preview.length)
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceTypeIdentifierHint: UTType.jpeg.identifier as CFString
        ]
        guard let source = CGImageSourceCreateWithData(bytes as CFData, options as CFDictionary) else { return nil }

        let native = preview.longEdge > 0 ? preview.longEdge : fullResolutionCeiling
        let target = pixels(for: request, native: native)
        // The preview is stored the way the sensor saw the scene; the NEF's own
        // orientation tag (not the JPEG's) says how to turn it upright.
        guard let decoded = thumbnail(from: source, maxPixel: target, applyOrientation: false, fromFullImage: true) else {
            return nil
        }
        let upright = Orientation.apply(orientation, to: decoded) ?? decoded
        var fullSize = CGSize(width: preview.width, height: preview.height)
        if Orientation.swapsAxes(orientation) {
            fullSize = CGSize(width: fullSize.height, height: fullSize.width)
        }
        if fullSize.width <= 0 || fullSize.height <= 0 {
            fullSize = CGSize(width: upright.width, height: upright.height)
        }
        return DecodedImage(
            cgImage: upright,
            origin: .embeddedPreview,
            sourceSize: fullSize,
            isFullResolution: max(decoded.width, decoded.height) >= min(native, fullResolutionCeiling)
        )
    }

    /// Demosaic the raw — only when the embedded preview is clearly smaller than
    /// the sensor, because the camera's full-size JPEG is the same picture.
    private static func decodeSensorData(url: URL, comparedWith preview: EmbeddedJPEG?) -> DecodedImage? {
        guard let source = makeSource(url), let rawSize = orientedSize(of: source) else { return nil }
        let rawLongEdge = Int(max(rawSize.width, rawSize.height))
        if let preview, Double(preview.longEdge) >= Double(rawLongEdge) * 0.75 { return nil }
        let target = min(rawLongEdge, fullResolutionCeiling)
        guard let image = thumbnail(from: source, maxPixel: target, applyOrientation: true, fromFullImage: true) else {
            return nil
        }
        // An undecodable raw can come back as its tiny embedded thumbnail; that is
        // not a raw decode, so let the caller fall back properly.
        guard Double(max(image.width, image.height)) >= Double(target) * 0.5 else { return nil }
        return DecodedImage(cgImage: image, origin: .raw, sourceSize: rawSize, isFullResolution: true)
    }

    // MARK: ImageIO

    private static func pixels(for request: Request, native: Int) -> Int {
        let limit = max(1, min(native, fullResolutionCeiling))
        switch request {
        case .scaled(let maxPixel): return max(1, min(maxPixel, limit))
        case .full: return limit
        }
    }

    private static func makeSource(_ url: URL) -> CGImageSource? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { return nil }
        return source
    }

    private static func orientedSize(of source: CGImageSource) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return Orientation.swapsAxes(orientation)
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)
    }

    /// The workhorse: a decode scaled to `maxPixel` on the long edge.
    ///
    /// `fromFullImage` decodes the image proper rather than accepting a small
    /// embedded thumbnail — a camera JPEG carries a 160 px one, which is exactly
    /// the blur this app must never show.
    private static func thumbnail(
        from source: CGImageSource,
        maxPixel: Int,
        applyOrientation: Bool,
        fromFullImage: Bool
    ) -> CGImage? {
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: applyOrientation,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel)
        ]
        if fromFullImage {
            options[kCGImageSourceCreateThumbnailFromImageAlways] = true
        } else {
            options[kCGImageSourceCreateThumbnailFromImageIfAbsent] = true
        }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Applies an EXIF orientation to decoded pixels.
///
/// Used for NEF previews, whose orientation lives in the raw file rather than in
/// the embedded JPEG. Each case was verified against Apple's own handling
/// (`kCGImageSourceCreateThumbnailWithTransform`); a quarter turn applied the
/// wrong way still looks plausibly shaped, so only a pixel comparison catches it.
enum Orientation {

    static func swapsAxes(_ orientation: Int) -> Bool {
        (5...8).contains(orientation)
    }

    /// The transform to concatenate, and the canvas size it needs.
    ///
    /// The rotated cases are not named by their EXIF descriptions: those are
    /// written for a top-left origin, while a `CGContext` has its origin at the
    /// bottom left, so "rotate 90° clockwise" is a counter-clockwise transform here.
    static func transform(for orientation: Int, size: CGSize) -> (CGAffineTransform, CGSize) {
        let w = size.width
        let h = size.height
        switch orientation {
        case 2:
            return (CGAffineTransform(translationX: w, y: 0).scaledBy(x: -1, y: 1), CGSize(width: w, height: h))
        case 3:
            return (CGAffineTransform(translationX: w, y: h).scaledBy(x: -1, y: -1), CGSize(width: w, height: h))
        case 4:
            return (CGAffineTransform(translationX: 0, y: h).scaledBy(x: 1, y: -1), CGSize(width: w, height: h))
        case 5:
            return (CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: w, ty: h), CGSize(width: h, height: w))
        case 6:
            return (CGAffineTransform(translationX: 0, y: w).rotated(by: -.pi / 2), CGSize(width: h, height: w))
        case 7:
            return (CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0), CGSize(width: h, height: w))
        case 8:
            return (CGAffineTransform(translationX: h, y: 0).rotated(by: .pi / 2), CGSize(width: h, height: w))
        default:
            return (.identity, CGSize(width: w, height: h))
        }
    }

    /// `image` turned the right way up. Returns the input for orientation 1, and
    /// nil only if no drawing context could be made.
    static func apply(_ orientation: Int, to image: CGImage) -> CGImage? {
        guard (2...8).contains(orientation) else { return image }
        let size = CGSize(width: image.width, height: image.height)
        let (transform, canvas) = transform(for: orientation, size: size)
        let width = Int(canvas.width.rounded())
        let height = Int(canvas.height.rounded())
        guard width > 0, height > 0 else { return image }

        // Keep the file's colour space where it can be drawn into; anything else
        // (greyscale, CMYK) becomes sRGB rather than failing.
        let space: CGColorSpace
        if let own = image.colorSpace, own.model == .rgb {
            space = own
        } else {
            space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        }
        let opaqueLayouts: [CGImageAlphaInfo] = [.none, .noneSkipLast, .noneSkipFirst]
        let opaque = opaqueLayouts.contains(image.alphaInfo)
        let alpha = opaque ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: alpha.rawValue
        ) else { return nil }
        context.concatenate(transform)
        // Quarter turns move pixels one-to-one, so no interpolation is needed.
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(origin: .zero, size: size))
        return context.makeImage()
    }
}
