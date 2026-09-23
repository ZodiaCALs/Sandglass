import Foundation
import CoreGraphics

/// Applies EXIF orientation to a decoded image.
///
/// `CGImageSourceCreateImageAtIndex` hands back the image in its stored pixel
/// order and ignores the orientation tag, so a photo shot in portrait arrives
/// sideways or upside down. This restores what the camera intended.
///
/// The transforms are written as explicit rotate/translate steps rather than raw
/// matrix coefficients: the eight cases are easy to get subtly wrong that way, and
/// a mirrored-then-rotated image looks plausible enough to pass a glance.
enum Orient {

    /// Canonical transform for an EXIF orientation value (1…8).
    ///
    /// Returns the transform to concatenate plus the size of the canvas it needs.
    ///
    /// The four rotated cases are deliberately **not** named by their EXIF
    /// descriptions. Those descriptions are written in a top-left origin
    /// convention, while a `CGContext` has its origin at the bottom-left, so
    /// "rotate 90° clockwise" reads as a counter-clockwise transform here. Getting
    /// that backwards produces a portrait photo that is upside down rather than
    /// sideways, which looks plausible enough to miss.
    ///
    /// Each case below was verified to reproduce the result of Apple's own
    /// orientation handling (`kCGImageSourceCreateThumbnailWithTransform`), which
    /// is the authority for how these files should look.
    ///
    /// 1 identity · 2 mirror across the vertical axis · 3 rotate 180
    /// 4 mirror across the horizontal axis
    /// 5 transpose · 6 quarter turn (portrait) · 7 transverse · 8 quarter turn the
    /// other way
    static func transform(for orientation: Int, size: CGSize) -> (CGAffineTransform, CGSize)? {
        let w = size.width
        let h = size.height

        switch orientation {
        case 1:
            return (.identity, CGSize(width: w, height: h))
        case 2:
            // Mirror across the vertical axis.
            return (CGAffineTransform(translationX: w, y: 0).scaledBy(x: -1, y: 1), CGSize(width: w, height: h))
        case 3:
            // 180°.
            return (CGAffineTransform(translationX: w, y: h).scaledBy(x: -1, y: -1), CGSize(width: w, height: h))
        case 4:
            // Mirror across the horizontal axis.
            return (CGAffineTransform(translationX: 0, y: h).scaledBy(x: 1, y: -1), CGSize(width: w, height: h))
        case 5:
            // Reflection across the anti-diagonal.
            return (CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: w, ty: h), CGSize(width: h, height: w))
        case 6:
            // The common "shot in portrait" case, and the one that showed up
            // upside down when this was inverted.
            let transform = CGAffineTransform(translationX: 0, y: w).rotated(by: -.pi / 2)
            return (transform, CGSize(width: h, height: w))
        case 7:
            // Reflection across the main diagonal.
            return (CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0), CGSize(width: h, height: w))
        case 8:
            let transform = CGAffineTransform(translationX: h, y: 0).rotated(by: .pi / 2)
            return (transform, CGSize(width: h, height: w))
        default:
            return (.identity, CGSize(width: w, height: h))
        }
    }

    /// Return `image` rotated and mirrored so it displays the right way up.
    ///
    /// Returns the input unchanged for orientation 1, and nil only if a drawing
    /// context cannot be created.
    static func apply(_ orientation: Int, to image: CGImage) -> CGImage? {
        guard orientation != 1 else { return image }
        let size = CGSize(width: image.width, height: image.height)
        guard let (transform, canvas) = transform(for: orientation, size: size) else { return image }

        let width = Int(canvas.width.rounded())
        let height = Int(canvas.height.rounded())
        guard width > 0, height > 0 else { return image }

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.concatenate(transform)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        return context.makeImage()
    }
}
