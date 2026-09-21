import SwiftUI
import AppKit
import QuartzCore

/// An image view that zooms and pans at display refresh rate.
///
/// SwiftUI is the wrong tool for this: `scaleEffect` invalidates layout for the
/// whole view tree on every gesture change, so zoom visibly lags the cursor. Here
/// the decoded bitmap is the *contents* of a `CALayer`, and zoom/pan are a single
/// `CATransform3D` on that layer. The compositor re-runs; SwiftUI does not. This
/// is what makes the image track the hand.
struct ImageCanvas: NSViewRepresentable {
    /// The bitmap to show, already decoded at the resolution it will be drawn at.
    let image: CGImage?
    /// Changes when a different photo is shown, so zoom can reset per photo.
    let resetToken: String
    /// Reports the zoom factor so the UI can display it. Display only — the
    /// canvas is the source of truth while a gesture is running.
    var onZoomChange: (CGFloat) -> Void = { _ in }
    /// Reports which part of the photo is visible, for the navigator.
    var onViewportChange: (CGRect) -> Void = { _ in }
    /// Hands the live canvas to the owner so controls can drive it.
    var onCanvasReady: (ImageCanvasView) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ImageCanvasView {
        let view = ImageCanvasView()
        view.onViewportChanged = onViewportChange
        view.setImage(image, resetZoom: true)
        context.coordinator.token = resetToken
        onCanvasReady(view)
        return view
    }

    func updateNSView(_ view: ImageCanvasView, context: Context) {
        view.onViewportChanged = onViewportChange
        // Only reset the zoom when the photo itself changes, not on every
        // unrelated SwiftUI update (which would fight the user's gestures).
        let isNewPhoto = context.coordinator.token != resetToken
        context.coordinator.token = resetToken
        view.setImage(image, resetZoom: isNewPhoto)
    }

    final class Coordinator {
        var token: String = ""
    }
}

/// The AppKit/Core Animation side of `ImageCanvas`.
///
/// The photo lives in a layer sized to the image's own pixels and is fitted to
/// the view by a single `CATransform3D`. Nothing rasterises the bitmap to the
/// view's size, so magnifying it shows real pixels instead of a stretched
/// screenshot of themselves. This is the whole reason zoom can be sharp *and*
/// track the cursor at display refresh rate.
final class ImageCanvasView: NSView {
    private let imageLayer = CALayer()

    private(set) var zoom: CGFloat = 1
    /// Translation in view points, applied on top of the fit.
    private var pan: CGPoint = .zero
    /// Scale that fits the image inside the view at zoom 1.
    private var fitScale: CGFloat = 1

    private let minimumZoom: CGFloat = 1
    private let maximumZoom: CGFloat = 12

    /// Called on the main thread whenever the zoom factor changes.
    var onZoomChanged: ((CGFloat) -> Void)?

    /// Called when the visible region changes, in normalised image coordinates
    /// (0…1, origin top-left). Drives the navigator thumbnail.
    var onViewportChanged: ((CGRect) -> Void)?

    /// The layer holding the photo. Exposed so tests can render and measure the
    /// actual output rather than trusting that it looks right.
    var imageContentsLayer: CALayer { imageLayer }

    /// Side of the pane the photo is fitted into, in points.
    var fitScaleValue: CGFloat { fitScale }
    /// Pixel size of the bitmap currently displayed.
    var sourcePixelSize: CGSize {
        guard let contents = imageLayer.contents as! CGImage? else { return .zero }
        return CGSize(width: contents.width, height: contents.height)
    }
    /// Size the photo is actually drawn at, in points.
    var drawnPointSize: CGSize {
        let scale = fitScale * zoom
        let size = sourcePixelSize
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    /// Which part of the photo is currently on screen, in normalised
    /// coordinates. Returns the whole image when it is fully visible.
    var visibleRegion: CGRect {
        guard let contents = imageLayer.contents as! CGImage?,
              bounds.width > 1, bounds.height > 1 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }

        let scale = fitScale * zoom
        guard scale > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }

        let imageWidth = CGFloat(contents.width)
        let imageHeight = CGFloat(contents.height)
        // Size of the pane measured in image pixels.
        let visibleWidth = min(imageWidth, bounds.width / scale)
        let visibleHeight = min(imageHeight, bounds.height / scale)

        // Top-left corner of that window within the image. Pan is in view points.
        let originX = (imageWidth - visibleWidth) / 2 - pan.x / scale
        let originY = (imageHeight - visibleHeight) / 2 - pan.y / scale

        return CGRect(
            x: originX / imageWidth,
            y: originY / imageHeight,
            width: visibleWidth / imageWidth,
            height: visibleHeight / imageHeight
        ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private func reportViewport() {
        onViewportChanged?(visibleRegion)
    }

    private let magnificationKey = "magnification"

    // MARK: Setup

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = .clear
        // The view composites at the display's scale. Left at the default 1 the
        // whole pane gets rendered into a 1x backing store and then blown up to
        // fill a Retina screen, which softens every pixel of the photo.
        layer?.contentsScale = window?.backingScaleFactor ?? 2

        imageLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        // Pin the backing store to the bitmap's own resolution. Left at the
        // screen's scale (2 on Retina) the layer allocates a 2x backing store and
        // interpolates the photo up into it — softening it before the transform
        // even runs. At 1, one image pixel is one backing-store pixel, so the
        // zoom transform magnifies real pixels.
        imageLayer.contentsScale = 1
        // The bitmap is placed 1:1 in layer space, so no filtering is needed for
        // the fit itself; zoom is a geometric transform on top.
        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .nearest
        imageLayer.minificationFilter = .nearest
        layer?.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        if let scale = window?.backingScaleFactor, layer?.contentsScale != scale {
            layer?.contentsScale = scale
        }
        recomputeFit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scale = window?.backingScaleFactor {
            layer?.contentsScale = scale
        }
        recomputeFit()
    }

    // MARK: Content

    /// Replace the displayed bitmap.
    ///
    /// Zoom resets only when the photo changes, so sharpening in place
    /// (prefetch → full resolution) does not jump the view.
    func setImage(_ image: CGImage?, resetZoom: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        if let image {
            // Layer space is measured in the image's own pixels.
            imageLayer.bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        } else {
            imageLayer.bounds = .zero
        }
        CATransaction.commit()

        recomputeFit()
        if resetZoom {
            zoom = 1
            pan = .zero
            applyTransform()
            onZoomChanged?(1)
        }
    }

    /// Recompute the fit scale and re-apply the transform.
    private func recomputeFit() {
        guard let contents = imageLayer.contents as! CGImage?,
              bounds.width > 1, bounds.height > 1 else {
            fitScale = 1
            return
        }
        fitScale = min(
            bounds.width / CGFloat(contents.width),
            bounds.height / CGFloat(contents.height)
        )
        if !(fitScale > 0) || !fitScale.isFinite { fitScale = 1 }
        applyTransform()
    }

    private func applyTransform() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)

        let scale = fitScale * zoom
        // Translate in layer space so a point of cursor movement moves the image
        // by exactly one point on screen.
        var transform = CATransform3DIdentity
        if scale > 0 {
            transform = CATransform3DTranslate(transform, pan.x / scale, pan.y / scale, 0)
        }
        transform = CATransform3DScale(transform, scale, scale, 1)
        imageLayer.transform = transform
        CATransaction.commit()
        reportViewport()
    }

    // MARK: Zoom

    /// How far the image may be dragged before its edge would leave the pane.
    ///
    /// Exposed so the framing rules can be verified directly.
    func panLimit() -> CGPoint {
        guard let contents = imageLayer.contents as! CGImage? else { return .zero }
        let shownWidth = CGFloat(contents.width) * fitScale * zoom
        let shownHeight = CGFloat(contents.height) * fitScale * zoom
        return CGPoint(
            x: max(0, (shownWidth - bounds.width) / 2),
            y: max(0, (shownHeight - bounds.height) / 2)
        )
    }

    /// Keep the image from being dragged entirely out of view.
    private func clampedPan(_ value: CGPoint) -> CGPoint {
        let limit = panLimit()
        return CGPoint(
            x: min(max(value.x, -limit.x), limit.x),
            y: min(max(value.y, -limit.y), limit.y)
        )
    }

    /// Zoom about a fixed point so the pixel under the cursor stays put.
    private func setZoom(_ newZoom: CGFloat, anchor: CGPoint) {
        let clamped = min(max(newZoom, minimumZoom), maximumZoom)
        guard abs(clamped - zoom) > 0.0001 else { return }

        // Keep the anchor stationary: the offset from the pane centre scales by
        // the same factor as the image, so whatever was under the cursor stays
        // under it. At zoom 1 the image is centred (pan is zero).
        let ratio = clamped / zoom
        pan = CGPoint(
            x: anchor.x + (pan.x - anchor.x) * ratio,
            y: anchor.y + (pan.y - anchor.y) * ratio
        )
        zoom = clamped
        pan = clampedPan(pan)
        applyTransform()
        onZoomChanged?(zoom)
    }

    func resetZoom() {
        zoom = 1
        pan = .zero
        applyTransform()
        onZoomChanged?(1)
    }

    /// Zoom from a control rather than a gesture, anchored on the pane centre.
    func setZoomFromUI(_ value: CGFloat) {
        setZoom(value, anchor: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    /// Move the view so that `point` (normalised image coordinates, 0…1) sits at
    /// the centre of the pane. Used by the navigator.
    func centreOn(normalised point: CGPoint) {
        guard let contents = imageLayer.contents as! CGImage? else { return }
        let scale = fitScale * zoom
        guard scale > 0 else { return }

        let imageWidth = CGFloat(contents.width)
        let imageHeight = CGFloat(contents.height)
        let targetX = point.x * imageWidth * scale
        let targetY = point.y * imageHeight * scale

        // Offset of that pixel from the image centre, once drawn.
        let offsetX = targetX - (imageWidth * scale) / 2
        let offsetY = targetY - (imageHeight * scale) / 2

        // Panning moves content by `pan`, so cancel the offset.
        pan = clampedPan(CGPoint(x: -offsetX, y: -offsetY))
        applyTransform()
    }

    // MARK: Events

    override func scrollWheel(with event: NSEvent) {
        let anchor = convert(event.locationInWindow, from: nil)

        // A trackpad pinch arrives as a scroll event carrying `magnification`.
        if let magnification = event.value(forKey: magnificationKey) as? CGFloat,
           abs(magnification) > 0 {
            setZoom(zoom * (1 + magnification), anchor: anchor)
            return
        }

        if event.modifierFlags.contains(.command) {
            // ⌘-scroll is the familiar zoom gesture.
            setZoom(zoom * (1 + event.scrollingDeltaY * 0.01), anchor: anchor)
            return
        }

        guard zoom > 1 else { return }
        // Two-finger scroll pans while zoomed in.
        pan = clampedPan(
            CGPoint(x: pan.x + event.scrollingDeltaX, y: pan.y + event.scrollingDeltaY)
        )
        applyTransform()
    }

    override func magnify(with event: NSEvent) {
        setZoom(
            zoom * (1 + event.magnification),
            anchor: convert(event.locationInWindow, from: nil)
        )
    }

    override func mouseDragged(with event: NSEvent) {
        guard zoom > 1 else { return }
        pan = clampedPan(CGPoint(x: pan.x + event.deltaX, y: pan.y + event.deltaY))
        applyTransform()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            // Toggle between fit and 1:1, the standard viewer gesture.
            if zoom > 1 {
                resetZoom()
            } else {
                setZoom(max(2, minimumZoom), anchor: convert(event.locationInWindow, from: nil))
            }
        }
    }
}
