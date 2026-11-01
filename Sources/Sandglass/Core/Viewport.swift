import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Where a photo sits inside a pane.
///
/// The framing is stored as two resolution-independent numbers:
///
/// - `zoom` — magnification on top of *fit* (1 shows the whole photo), and
/// - `centre` — the point of the photo shown at the middle of the pane, in
///   normalised image coordinates (0…1, origin top-left).
///
/// Everything else — the drawn frame, the visible region the navigator outlines,
/// the zoom percentage — is derived from them. Because nothing is stored in
/// pixels, swapping the bitmap for a sharper one never moves the photo, and
/// because nothing is accumulated, no sequence of gestures or resizes can make
/// the framing drift.
struct Viewport: Equatable, Sendable {

    /// The photo's logical size in pixels: oriented, at full resolution as far as
    /// it is known. Only its aspect ratio matters for the framing; its scale only
    /// matters for the percentage readout.
    private(set) var imageSize: CGSize
    /// The pane's size in points.
    private(set) var viewSize: CGSize
    /// Device pixels per point (2 on a Retina display).
    private(set) var backingScale: CGFloat

    /// Magnification relative to fit. Never below 1.
    private(set) var zoom: CGFloat = 1
    /// The normalised image point at the centre of the pane.
    private(set) var centre = CGPoint(x: 0.5, y: 0.5)

    /// The most a photo can be magnified: 16 device pixels per image pixel (1600%).
    static let maximumPixelMagnification: CGFloat = 16

    /// Magnification stops used by the zoom buttons and ⌘+ / ⌘−, expressed as
    /// device pixels per image pixel (1 = 100%).
    static let zoomStops: [CGFloat] = [
        0.0625, 1.0 / 12, 0.125, 1.0 / 6, 0.25, 1.0 / 3, 0.5, 2.0 / 3,
        1, 1.5, 2, 3, 4, 6, 8, 12, 16
    ]

    init(imageSize: CGSize = .zero, viewSize: CGSize = .zero, backingScale: CGFloat = 2) {
        self.imageSize = imageSize
        self.viewSize = viewSize
        self.backingScale = backingScale > 0 ? backingScale : 2
    }

    // MARK: Derived geometry

    /// True when both the photo and the pane have a real size.
    var hasContent: Bool {
        imageSize.width > 0 && imageSize.height > 0 && viewSize.width > 0 && viewSize.height > 0
    }

    /// Points per image pixel at zoom 1.
    var fitScale: CGFloat {
        guard hasContent else { return 1 }
        let scale = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        return scale.isFinite && scale > 0 ? scale : 1
    }

    /// Points per image pixel at the current zoom.
    var scale: CGFloat { fitScale * zoom }

    /// Device pixels per image pixel. 1 means 100% — one photo pixel per screen pixel.
    var pixelMagnification: CGFloat { scale * backingScale }

    /// The zoom at which the photo is shown pixel for pixel.
    var actualPixelsZoom: CGFloat { 1 / (fitScale * backingScale) }

    /// The deepest zoom allowed for this photo in this pane.
    var maximumZoom: CGFloat {
        max(1, Self.maximumPixelMagnification / (fitScale * backingScale))
    }

    /// The photo's size on screen, in points.
    var displayedSize: CGSize {
        CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    /// Where the photo is drawn, in pane points (origin top-left).
    var imageFrame: CGRect {
        let size = displayedSize
        return CGRect(
            x: viewSize.width / 2 - centre.x * size.width,
            y: viewSize.height / 2 - centre.y * size.height,
            width: size.width,
            height: size.height
        )
    }

    /// The part of the photo that is on screen, in normalised image coordinates.
    var visibleRegion: CGRect {
        let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard hasContent else { return whole }
        let size = displayedSize
        let width = min(1, viewSize.width / size.width)
        let height = min(1, viewSize.height / size.height)
        return CGRect(x: centre.x - width / 2, y: centre.y - height / 2, width: width, height: height)
            .intersection(whole)
    }

    /// True once the photo is magnified beyond fit.
    var isZoomedIn: Bool { zoom > 1.0005 }

    /// True when part of the photo is outside the pane, so dragging can move it.
    var canPan: Bool {
        let size = displayedSize
        return size.width > viewSize.width + 0.5 || size.height > viewSize.height + 0.5
    }

    // MARK: Conversions

    /// The normalised image point under a point of the pane. May fall outside 0…1
    /// when the point is over the letterbox.
    func normalisedPoint(forViewPoint point: CGPoint) -> CGPoint {
        let frame = imageFrame
        guard frame.width > 0, frame.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: (point.x - frame.minX) / frame.width, y: (point.y - frame.minY) / frame.height)
    }

    /// The pane point where a normalised image point is drawn.
    func viewPoint(forNormalised point: CGPoint) -> CGPoint {
        let frame = imageFrame
        return CGPoint(x: frame.minX + point.x * frame.width, y: frame.minY + point.y * frame.height)
    }

    // MARK: Changing the inputs

    /// A new photo, or a new rendition of the same one. The framing is kept, so a
    /// sharper bitmap replacing a softer one lands exactly where the old one was.
    mutating func setImageSize(_ size: CGSize) {
        guard size != imageSize else { return }
        imageSize = size
        zoom = clampedZoom(zoom)
        centre = clampedCentre(centre, zoom: zoom)
    }

    /// The pane changed size.
    ///
    /// At fit the photo stays fitted. Zoomed in, the on-screen magnification is
    /// kept instead — showing or hiding a panel at 100% leaves you at 100% — and
    /// the same point of the photo stays in the middle.
    mutating func setViewSize(_ size: CGSize) {
        guard size != viewSize else { return }
        let wasZoomedIn = isZoomedIn && hasContent
        let previousScale = scale
        viewSize = size
        guard hasContent else { return }
        zoom = wasZoomedIn ? clampedZoom(previousScale / fitScale) : 1
        centre = clampedCentre(centre, zoom: zoom)
    }

    mutating func setBackingScale(_ value: CGFloat) {
        guard value > 0, value.isFinite, value != backingScale else { return }
        backingScale = value
        zoom = clampedZoom(zoom)
        centre = clampedCentre(centre, zoom: zoom)
    }

    // MARK: Zooming and panning

    /// Back to fit, centred.
    mutating func reset() {
        zoom = 1
        centre = CGPoint(x: 0.5, y: 0.5)
    }

    /// Zoom to `newZoom`, keeping the photo point under `anchor` (pane points)
    /// where it is. Without an anchor the pane centre is used.
    mutating func setZoom(_ newZoom: CGFloat, anchor: CGPoint? = nil) {
        guard newZoom.isFinite else { return }
        let target = clampedZoom(newZoom)
        guard hasContent else {
            zoom = target
            return
        }
        let anchorPoint = anchor ?? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        let offset = CGPoint(x: anchorPoint.x - viewSize.width / 2, y: anchorPoint.y - viewSize.height / 2)
        let before = displayedSize
        let underAnchor = CGPoint(
            x: centre.x + offset.x / before.width,
            y: centre.y + offset.y / before.height
        )
        zoom = target
        let after = displayedSize
        let candidate = CGPoint(
            x: underAnchor.x - offset.x / after.width,
            y: underAnchor.y - offset.y / after.height
        )
        centre = clampedCentre(candidate, zoom: zoom)
    }

    /// Multiply the zoom by `factor` about `anchor`.
    mutating func magnify(by factor: CGFloat, anchor: CGPoint? = nil) {
        guard factor.isFinite, factor > 0 else { return }
        setZoom(zoom * factor, anchor: anchor)
    }

    /// Move the photo by a distance in pane points: positive values move it right
    /// and down, the way a drag does.
    mutating func pan(by delta: CGSize) {
        guard hasContent, delta.width.isFinite, delta.height.isFinite else { return }
        let size = displayedSize
        let candidate = CGPoint(x: centre.x - delta.width / size.width, y: centre.y - delta.height / size.height)
        centre = clampedCentre(candidate, zoom: zoom)
    }

    /// Put a normalised image point at the centre of the pane, as far as the edges allow.
    mutating func setCentre(_ point: CGPoint) {
        guard point.x.isFinite, point.y.isFinite else { return }
        centre = clampedCentre(point, zoom: zoom)
    }

    /// Adopt another pane's framing (used to keep the two halves of Compare in step).
    mutating func adopt(zoom newZoom: CGFloat, centre newCentre: CGPoint) {
        guard newZoom.isFinite, newCentre.x.isFinite, newCentre.y.isFinite else { return }
        zoom = clampedZoom(newZoom)
        centre = clampedCentre(newCentre, zoom: zoom)
    }

    // MARK: Steps

    enum Direction: Sendable { case `in`, out }

    /// The zoom reached by one press of zoom in / zoom out: the next standard
    /// magnification (25%, 33%, 50%, 100%, 200%…) beyond the current one.
    func steppedZoom(_ direction: Direction) -> CGFloat {
        guard hasContent else { return 1 }
        let fitMagnification = fitScale * backingScale
        let current = pixelMagnification
        switch direction {
        case .in:
            if let stop = Self.zoomStops.first(where: { $0 > current * 1.01 && $0 > fitMagnification * 1.01 }) {
                return clampedZoom(stop / fitMagnification)
            }
            return maximumZoom
        case .out:
            if let stop = Self.zoomStops.last(where: { $0 < current * 0.99 && $0 > fitMagnification * 1.01 }) {
                return clampedZoom(stop / fitMagnification)
            }
            return 1
        }
    }

    /// What "toggle zoom" (double-click, Z, smart magnify) should do from here:
    /// back to fit when zoomed in, otherwise to the requested pixel magnification —
    /// or, for a photo so small that this is no bigger than fit, to twice fit.
    func toggledZoom(pixelMagnification target: CGFloat = 1) -> CGFloat {
        if isZoomedIn { return 1 }
        let candidate = target / (fitScale * backingScale)
        return clampedZoom(candidate > 1.05 ? candidate : 2)
    }

    // MARK: Clamping

    func clampedZoom(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 1 }
        guard hasContent else { return max(1, value) }
        return min(max(value, 1), maximumZoom)
    }

    /// A centre that keeps the photo covering the pane in every axis where it is
    /// larger than the pane, and centred in every axis where it is not.
    func clampedCentre(_ point: CGPoint, zoom value: CGFloat) -> CGPoint {
        guard hasContent else { return CGPoint(x: 0.5, y: 0.5) }
        let scale = fitScale * value
        func axis(_ position: CGFloat, displayed: CGFloat, available: CGFloat) -> CGFloat {
            guard position.isFinite, displayed > available + 0.0001 else { return 0.5 }
            let half = available / displayed / 2
            return min(max(position, half), 1 - half)
        }
        return CGPoint(
            x: axis(point.x, displayed: imageSize.width * scale, available: viewSize.width),
            y: axis(point.y, displayed: imageSize.height * scale, available: viewSize.height)
        )
    }
}
