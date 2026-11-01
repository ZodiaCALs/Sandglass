import AppKit
import QuartzCore

/// The photo surface.
///
/// The decoded bitmap is the `contents` of a layer sized to the bitmap's own
/// pixels and placed by a single transform; zoom and pan change that transform
/// and nothing else, so the compositor follows the hand at display refresh rate.
/// All geometry comes from a `Viewport`, which stores the framing in
/// resolution-independent terms — that is what lets a sharper bitmap replace a
/// softer one mid-zoom without the photo jumping, and what keeps any sequence of
/// gestures and window resizes from drifting the photo into a corner.
///
/// Events arrive the ordinary AppKit way (no global event monitor), so a scroll
/// in a sheet, a popover or another window can never zoom the photo behind it.
@MainActor
final class ImageCanvasView: NSView {

    /// Called after every change of framing.
    var onViewportChange: ((ImageCanvasView) -> Void)?
    /// What double-click, Z and smart magnify zoom to, in device pixels per image pixel.
    var toggleMagnification: CGFloat = 1

    private(set) var viewport = Viewport()
    private(set) var image: CGImage?
    /// True when the bitmap is the full-resolution one, so magnifying it shows
    /// real pixels and it is drawn without smoothing.
    private(set) var showsAllPixels = false

    private let imageLayer = CALayer()
    private var dragOrigin: CGPoint?

    /// The layer holding the photo, exposed so tests can render and measure the
    /// real output instead of trusting that it looks right.
    var imageContentsLayer: CALayer { imageLayer }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.masksToBounds = true

        imageLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        imageLayer.contentsGravity = .resize
        // Smooth when a bitmap is shown smaller than its pixels (mipmapped, so
        // no aliasing at fit); crisp when real pixels are magnified.
        imageLayer.minificationFilter = .trilinear
        imageLayer.magnificationFilter = .nearest
        imageLayer.isHidden = true
        imageLayer.actions = ["contents": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(imageLayer)

        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Content

    /// Show a bitmap.
    ///
    /// - Parameters:
    ///   - logicalSize: the full-resolution size the bitmap stands for. The
    ///     framing is kept in these terms, so swapping a screen-sized rendition
    ///     for every pixel moves nothing.
    ///   - allPixels: the bitmap is full resolution.
    ///   - resetFraming: a different photo — start at fit.
    func setImage(_ image: CGImage?, logicalSize: CGSize? = nil, allPixels: Bool, resetFraming: Bool) {
        let couldPan = viewport.canPan
        self.image = image
        showsAllPixels = allPixels
        let size = logicalSize ?? image.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
        viewport.setImageSize(size)
        if resetFraming { viewport.reset() }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        imageLayer.isHidden = image == nil
        if let image {
            let opaqueLayouts: [CGImageAlphaInfo] = [.none, .noneSkipLast, .noneSkipFirst]
            imageLayer.isOpaque = opaqueLayouts.contains(image.alphaInfo)
        }
        CATransaction.commit()

        apply(animated: false)
        if couldPan != viewport.canPan { window?.invalidateCursorRects(for: self) }
    }

    // MARK: Zoom and pan

    func zoom(to value: CGFloat, anchor: CGPoint? = nil, animated: Bool) {
        guard image != nil else { return }
        viewport.setZoom(value, anchor: anchor)
        apply(animated: animated)
        window?.invalidateCursorRects(for: self)
    }

    func zoomIn() { zoom(to: viewport.steppedZoom(.in), animated: true) }
    func zoomOut() { zoom(to: viewport.steppedZoom(.out), animated: true) }
    func zoomToFit() { zoom(to: 1, animated: true) }

    func zoomToActualPixels(anchor: CGPoint? = nil) {
        zoom(to: viewport.actualPixelsZoom, anchor: anchor, animated: true)
    }

    /// Fit ↔ the toggle magnification (100% by default).
    func toggleZoom(at anchor: CGPoint? = nil) {
        zoom(to: viewport.toggledZoom(pixelMagnification: toggleMagnification), anchor: anchor, animated: true)
    }

    /// Put a normalised photo point in the middle of the pane (the navigator).
    func centre(on point: CGPoint, animated: Bool = false) {
        guard image != nil else { return }
        viewport.setCentre(point)
        apply(animated: animated)
    }

    /// Take another pane's framing (Compare keeps both halves in step).
    func adopt(zoom: CGFloat, centre: CGPoint) {
        viewport.adopt(zoom: zoom, centre: centre)
        apply(animated: false)
        window?.invalidateCursorRects(for: self)
    }

    // MARK: Rendering

    private func apply(animated: Bool) {
        if let image {
            let frame = viewport.imageFrame
            let width = CGFloat(image.width)
            let height = CGFloat(image.height)
            // Snap the photo's corner to a device pixel so 100% is pixel-exact.
            let scale = viewport.backingScale
            let originX = (frame.minX * scale).rounded() / scale
            let originY = (frame.minY * scale).rounded() / scale

            CATransaction.begin()
            if animated {
                CATransaction.setAnimationDuration(0.22)
                CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
            } else {
                CATransaction.setDisableActions(true)
            }
            imageLayer.bounds = CGRect(x: 0, y: 0, width: width, height: height)
            imageLayer.position = CGPoint(x: originX + frame.width / 2, y: originY + frame.height / 2)
            imageLayer.transform = CATransform3DMakeScale(frame.width / width, frame.height / height, 1)
            // A screen-sized rendition magnified while every pixel loads is
            // smoothed rather than blocky; real pixels are shown as they are.
            imageLayer.magnificationFilter = showsAllPixels ? .nearest : .linear
            CATransaction.commit()
        }
        onViewportChange?(self)
    }

    // MARK: Geometry changes

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        viewport.setViewSize(newSize)
        apply(animated: false)
        window?.invalidateCursorRects(for: self)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
        viewport.setBackingScale(scale)
        apply(animated: false)
    }

    // MARK: Events

    override func scrollWheel(with event: NSEvent) {
        guard image != nil else {
            super.scrollWheel(with: event)
            return
        }
        let intent = ZoomInput.interpret(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            hasPreciseDeltas: event.hasPreciseScrollingDeltas,
            isDirectionInverted: event.isDirectionInvertedFromDevice,
            modifiers: InputModifiers(event.modifierFlags)
        )
        switch intent {
        case .zoom(let factor):
            viewport.magnify(by: factor, anchor: location(of: event))
            apply(animated: false)
            window?.invalidateCursorRects(for: self)
        case .pan(let dx, let dy):
            guard viewport.canPan else { return }
            viewport.pan(by: CGSize(width: dx, height: dy))
            apply(animated: false)
        case .none:
            break
        }
    }

    override func magnify(with event: NSEvent) {
        guard image != nil else { return }
        viewport.magnify(by: ZoomInput.pinchFactor(event.magnification), anchor: location(of: event))
        apply(animated: false)
        if event.phase == .ended || event.phase == .cancelled {
            window?.invalidateCursorRects(for: self)
        }
    }

    override func smartMagnify(with event: NSEvent) {
        toggleZoom(at: location(of: event))
    }

    override func mouseDown(with event: NSEvent) {
        guard image != nil else {
            super.mouseDown(with: event)
            return
        }
        if event.clickCount >= 2 {
            dragOrigin = nil
            toggleZoom(at: location(of: event))
            return
        }
        guard viewport.canPan else { return }
        dragOrigin = location(of: event)
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin else { return }
        let point = location(of: event)
        viewport.pan(by: CGSize(width: point.x - origin.x, height: point.y - origin.y))
        dragOrigin = point
        apply(animated: false)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragOrigin != nil else { return }
        dragOrigin = nil
        (viewport.canPan ? NSCursor.openHand : NSCursor.arrow).set()
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        if image != nil, viewport.canPan {
            addCursorRect(bounds, cursor: .openHand)
        }
    }

    private func location(of event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }
}
