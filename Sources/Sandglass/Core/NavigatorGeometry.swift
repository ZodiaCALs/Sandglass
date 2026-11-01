import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Geometry of the navigator — the small map of the whole photo shown while
/// zoomed in, with a rectangle marking the part that is on screen.
///
/// The map is always drawn at the photo's exact aspect ratio, filling the
/// navigator, so the rectangle maps onto the photo one-to-one. (Cropping the map
/// to a fixed shape is what made the rectangle drift off the true region.)
struct NavigatorGeometry: Equatable, Sendable {

    /// Where the photo is drawn inside the navigator, in navigator points
    /// (origin top-left).
    let mapRect: CGRect

    /// The rectangle never shrinks below this, so it stays visible and grabbable
    /// even at extreme zoom.
    static let minimumViewportSide: CGFloat = 8

    init(mapRect: CGRect) {
        self.mapRect = mapRect
    }

    /// The navigator's size for a photo of this aspect ratio, fitting within the
    /// given bounds.
    static func mapSize(forAspectRatio aspect: CGFloat, maxWidth: CGFloat, maxHeight: CGFloat) -> CGSize {
        guard aspect.isFinite, aspect > 0, maxWidth > 0, maxHeight > 0 else {
            return CGSize(width: max(maxWidth, 1), height: max(maxHeight, 1))
        }
        var width = maxWidth
        var height = maxWidth / aspect
        if height > maxHeight {
            height = maxHeight
            width = maxHeight * aspect
        }
        return CGSize(width: max(1, width.rounded()), height: max(1, height.rounded()))
    }

    /// The on-screen region (normalised) as a rectangle in the navigator.
    func viewportRect(for region: CGRect) -> CGRect {
        var rect = CGRect(
            x: mapRect.minX + region.minX * mapRect.width,
            y: mapRect.minY + region.minY * mapRect.height,
            width: region.width * mapRect.width,
            height: region.height * mapRect.height
        )
        let minimum = Self.minimumViewportSide
        if rect.width < minimum {
            rect = rect.insetBy(dx: (rect.width - minimum) / 2, dy: 0)
        }
        if rect.height < minimum {
            rect = rect.insetBy(dx: 0, dy: (rect.height - minimum) / 2)
        }
        // Keep a grown rectangle inside the map.
        if rect.width <= mapRect.width {
            rect.origin.x = min(max(rect.minX, mapRect.minX), mapRect.maxX - rect.width)
        }
        if rect.height <= mapRect.height {
            rect.origin.y = min(max(rect.minY, mapRect.minY), mapRect.maxY - rect.height)
        }
        return rect
    }

    /// The normalised photo point under a navigator point, clamped to the photo.
    func normalisedPoint(for point: CGPoint) -> CGPoint {
        guard mapRect.width > 0, mapRect.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        let x = (point.x - mapRect.minX) / mapRect.width
        let y = (point.y - mapRect.minY) / mapRect.height
        return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }
}

/// A drag inside the navigator.
///
/// Grabbing the rectangle remembers where inside it you grabbed, so it moves
/// with the pointer instead of jumping to centre itself under it. Clicking
/// outside the rectangle jumps there, then drags from the centre.
struct NavigatorDrag: Equatable, Sendable {
    /// From the rectangle's centre to the grab point, in navigator points.
    let grabOffset: CGSize

    static func begin(at point: CGPoint, viewportRect: CGRect) -> NavigatorDrag {
        guard viewportRect.contains(point) else { return NavigatorDrag(grabOffset: .zero) }
        return NavigatorDrag(grabOffset: CGSize(
            width: point.x - viewportRect.midX,
            height: point.y - viewportRect.midY
        ))
    }

    /// The normalised photo point that should be centred for the pointer at `point`.
    func targetCentre(for point: CGPoint, in geometry: NavigatorGeometry) -> CGPoint {
        geometry.normalisedPoint(for: CGPoint(x: point.x - grabOffset.width, y: point.y - grabOffset.height))
    }
}
