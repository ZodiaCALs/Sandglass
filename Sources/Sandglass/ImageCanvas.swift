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
    /// Changes when the bitmap for the *same* photo is replaced — a sharper decode
    /// arriving after the prefetch. Distinct from `resetToken` so the framing is
    /// preserved while the image sharpens.
    var bitmapRevision: Int = 0
    /// Reports the zoom factor so the UI can display it. Display only — the
    /// canvas is the source of truth while a gesture is running.
    var onZoomChange: (CGFloat) -> Void = { _ in }
    /// Reports which part of the photo is visible, for the navigator, together
    /// with a monotonically increasing tick.
    var onViewportChange: (CGRect, Int) -> Void = { _, _ in }
    /// Hands the live canvas to the owner so controls can drive it.
    var onCanvasReady: (ImageCanvasView) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ImageCanvasView {
        let view = ImageCanvasView()
        view.onZoomChanged = onZoomChange
        view.onViewportChanged = onViewportChange
        view.setImage(image, resetZoom: true)
        context.coordinator.token = resetToken
        onCanvasReady(view)
        return view
    }

    func updateNSView(_ view: ImageCanvasView, context: Context) {
        // Refresh both handlers: SwiftUI recreates these closures on every update,
        // so keeping only the ones captured at creation can leave the zoom readout
        // listening to a stale closure and appearing frozen.
        view.onZoomChanged = onZoomChange
        view.onViewportChanged = onViewportChange

        let isNewPhoto = context.coordinator.token != resetToken
        let isNewBitmap = context.coordinator.revision != bitmapRevision
        context.coordinator.token = resetToken
        context.coordinator.revision = bitmapRevision

        // Reset the framing only for a different photo. A sharper decode of the
        // same photo swaps the pixels in place, so zoom is not disturbed. Passing
        // the bitmap unconditionally also guarantees SwiftUI cannot skip the
        // update when the image compares equal to itself.
        if isNewPhoto || isNewBitmap {
            view.setImage(image, resetZoom: isNewPhoto)
        }
    }

    final class Coordinator {
        var token: String = ""
        var revision: Int = -1
    }
}

/// The AppKit/Core Animation side of `ImageCanvas`.
///
/// The photo lives in a layer sized to the image's own pixels and is fitted to
/// the view by a single `CATransform3D`. Nothing rasterises the bitmap to the
/// view's size, so magnifying it shows real pixels instead of a stretched
/// screenshot of themselves.
///
/// The view state is deliberately expressed as *where the photo is* rather than
/// as accumulated movement:
///
/// - `zoom` — magnification on top of the fit.
/// - `centre` — the point of the image sitting at the middle of the pane, in
///   image pixels.
///
/// The transform is then derived from those two values. Storing a running pan
/// offset instead makes the framing depend on the history of every gesture, so
/// rounding accumulates and a resize can leave the photo pushed into a corner.
/// Deriving it means the framing is always exactly reproducible from the state.
final class ImageCanvasView: NSView {
    private let imageLayer = CALayer()

    private(set) var zoom: CGFloat = 1
    /// Image point shown at the centre of the pane, in image pixels.
    private var centre: CGPoint = .zero
    /// Scale that fits the image inside the view at zoom 1.
    private var fitScale: CGFloat = 1

    private let minimumZoom: CGFloat = 1
    private let maximumZoom: CGFloat = 12

    /// Called on the main thread whenever the zoom factor changes.
    var onZoomChanged: ((CGFloat) -> Void)?

    /// Called when the visible region changes, in normalised image coordinates
    /// (0…1, origin top-left). Drives the navigator thumbnail.
    ///
    /// The tick increments on every change. Comparing rectangles alone is not
    /// enough: SwiftUI can consider a value unchanged and skip the redraw, which
    /// leaves the navigator's rectangle frozen while the photo zooms.
    var onViewportChanged: ((CGRect, Int) -> Void)?
    private var viewportTick = 0

    /// The layer holding the photo. Exposed so tests can render and measure the
    /// actual output rather than trusting that it looks right.
    var imageContentsLayer: CALayer { imageLayer }

    /// Scale that fits the whole image in the pane.
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

    // MARK: Setup

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        // Transparent, so whatever backdrop the user chose shows through the
        // letterbox area instead of a black band.
        layer?.backgroundColor = .clear
        // The view composites at the display's scale. Left at the default 1 the
        // whole pane gets rendered into a 1x backing store and then blown up to
        // fill a Retina screen, which softens every pixel of the photo.
        layer?.contentsScale = window?.backingScaleFactor ?? 2

        imageLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        // Pin the backing store to the bitmap's own resolution. Left at the
        // screen's scale (2 on Retina) the layer allocates a 2x backing store and
        // interpolates the photo up into it — softening it before the transform
        // even runs.
        imageLayer.contentsScale = 1
        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .nearest
        imageLayer.minificationFilter = .nearest
        layer?.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Event routing

    private var eventMonitor: Any?

    /// Watch for scroll and magnify events directly on the window.
    ///
    /// SwiftUI's hosting layer consumes scroll events in some configurations, so
    /// relying on `scrollWheel(with:)` alone can leave wheel zoom silently dead.
    /// The monitor fires first, and only acts when the pointer is actually over
    /// this view, so nothing else in the app is affected.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scale = window?.backingScaleFactor {
            layer?.contentsScale = scale
        }
        recomputeFit()
        if window == nil {
            removeEventMonitor()
        } else {
            installEventMonitor()
        }
    }

    private func installEventMonitor() {
        removeEventMonitor()
        guard let window else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
            guard let self, self.window === window else { return event }
            // Only handle events that land on this view.
            let point = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(point) else { return event }

            if event.type == .magnify {
                GestureTrace.log("monitor magnify \(event.magnification)")
                self.setZoom(self.zoom * (1 + event.magnification), anchor: point)
            } else {
                self.handleScroll(event, anchor: point, fromMonitor: true)
            }
            // Swallow it: the event was meant for the photo, and letting the
            // hosting view see it again would double-apply the gesture.
            return nil
        }
    }

    private func removeEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    /// The monitor is tied to the window, so it is installed and removed as the
    /// view moves between windows rather than in `deinit`, which cannot touch
    /// main-actor state.
    override func removeFromSuperview() {
        removeEventMonitor()
        super.removeFromSuperview()
    }

    override func layout() {
        super.layout()
        if let scale = window?.backingScaleFactor, layer?.contentsScale != scale {
            layer?.contentsScale = scale
        }
        recomputeFit()
    }

    // MARK: Content

    /// Replace the displayed bitmap.
    ///
    /// Zoom resets only when the photo changes, so sharpening in place does not
    /// jump the view.
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
            invalidateCentre()
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
        // A resize changes what is visible, so the centre must be re-validated;
        // this keeps the photo framed instead of letting it slide into a corner.
        centre = clampedCentre(centre)
        applyTransform()
    }

    /// Point of the image shown at the middle of the pane, clamped so the photo
    /// always covers the pane when zoomed in, and centred when it fits.
    private func clampedCentre(_ point: CGPoint) -> CGPoint {
        let size = sourcePixelSize
        guard size.width > 0, size.height > 0 else { return .zero }

        // How much of the image fits across the pane, in image pixels.
        let visibleWidth = min(size.width, bounds.width / max(fitScale * zoom, 0.0001))
        let visibleHeight = min(size.height, bounds.height / max(fitScale * zoom, 0.0001))

        let x = visibleWidth >= size.width
            ? size.width / 2
            : min(max(point.x, visibleWidth / 2), size.width - visibleWidth / 2)
        let y = visibleHeight >= size.height
            ? size.height / 2
            : min(max(point.y, visibleHeight / 2), size.height - visibleHeight / 2)
        return CGPoint(x: x, y: y)
    }

    /// Recentre on the image when nothing else dictates a position.
    private func invalidateCentre() {
        let size = sourcePixelSize
        centre = CGPoint(x: size.width / 2, y: size.height / 2)
    }

    private func applyTransform() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)

        let scale = fitScale * zoom
        let size = sourcePixelSize
        guard scale > 0, size.width > 0 else {
            imageLayer.transform = CATransform3DIdentity
            CATransaction.commit()
            return
        }

        // Offset that puts `centre` at the middle of the pane, in view points.
        let offsetX = (size.width / 2 - centre.x) * scale
        let offsetY = (size.height / 2 - centre.y) * scale

        var transform = CATransform3DIdentity
        // Translate in layer space so a point of cursor movement moves the image
        // by exactly one point on screen.
        transform = CATransform3DTranslate(transform, offsetX / scale, offsetY / scale, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        imageLayer.transform = transform
        CATransaction.commit()
        reportViewport()
    }

    // MARK: Zoom

    private func setZoom(_ newZoom: CGFloat, anchor: CGPoint) {
        let clamped = min(max(newZoom, minimumZoom), maximumZoom)
        guard abs(clamped - zoom) > 0.0001, clamped.isFinite else { return }

        let ratio = clamped / zoom
        guard ratio.isFinite, ratio > 0 else { return }

        let scale = fitScale * zoom
        let size = sourcePixelSize
        guard scale > 0, size.width > 0, size.height > 0 else { return }

        // The image point currently under the anchor must stay under it.
        let offset = CGPoint(x: anchor.x - bounds.midX, y: anchor.y - bounds.midY)
        let pointAtAnchor = CGPoint(
            x: centre.x + offset.x / scale,
            y: centre.y + offset.y / scale
        )

        zoom = clamped
        GestureTrace.log("setZoom -> \(zoom) willReport=\(onZoomChanged != nil)")
        let newScale = fitScale * zoom
        // Re-derive the centre so that same point maps back to the anchor.
        let candidate = CGPoint(
            x: pointAtAnchor.x - offset.x / newScale,
            y: pointAtAnchor.y - offset.y / newScale
        )
        centre = clampedCentre(candidate.x.isFinite && candidate.y.isFinite ? candidate : centre)
        applyTransform()
        onZoomChanged?(zoom)
    }

    func resetZoom() {
        zoom = 1
        invalidateCentre()
        applyTransform()
        onZoomChanged?(1)
    }

    /// Zoom from a control rather than a gesture, anchored on the pane centre.
    func setZoomFromUI(_ value: CGFloat) {
        setZoom(value, anchor: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    /// Zoom about a given point. Exposed so anchored zoom can be exercised
    /// directly, without synthesising gesture events.
    func setZoom(anchor: CGPoint, value: CGFloat) {
        setZoom(value, anchor: anchor)
    }

    /// Move the view so that `point` (normalised image coordinates, 0…1) sits at
    /// the centre of the pane. Used by the navigator.
    func centreOn(normalised point: CGPoint) {
        let size = sourcePixelSize
        guard size.width > 0, size.height > 0 else { return }
        centre = clampedCentre(CGPoint(x: point.x * size.width, y: point.y * size.height))
        applyTransform()
        reportViewport()
    }

    /// Pan by a delta in view points.
    private func panBy(dx: CGFloat, dy: CGFloat) {
        guard zoom > 1 else { return }
        let scale = fitScale * zoom
        guard scale > 0, dx.isFinite, dy.isFinite else { return }
        // Dragging moves the content, so the centre moves the opposite way.
        let candidate = CGPoint(x: centre.x - dx / scale, y: centre.y - dy / scale)
        centre = clampedCentre(candidate)
        applyTransform()
    }

    /// Which part of the photo is currently on screen, in normalised
    /// coordinates. Returns the whole image when it is fully visible.
    var visibleRegion: CGRect {
        let size = sourcePixelSize
        guard size.width > 0, size.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let scale = fitScale * zoom
        guard scale > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }

        let visibleWidth = min(size.width, bounds.width / scale)
        let visibleHeight = min(size.height, bounds.height / scale)
        return CGRect(
            x: (centre.x - visibleWidth / 2) / size.width,
            y: (centre.y - visibleHeight / 2) / size.height,
            width: visibleWidth / size.width,
            height: visibleHeight / size.height
        ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// Report the visible region, at most a few times a second.
    ///
    /// This feeds SwiftUI state, and a pinch produces far more frames than the
    /// navigator can usefully show. Reporting on every frame made the whole
    /// preview pane re-render mid-gesture, which is felt as stutter.
    private func reportViewport(force: Bool = false) {
        let now = CACurrentMediaTime()
        // The first report goes out immediately: making the navigator appear is
        // worth more than the throttle, and it keeps the change observable
        // without waiting on a timer.
        if force || previousReport == 0 || now - lastViewportReport >= Self.viewportReportInterval {
            pendingReport?.cancel()
            pendingReport = nil
            lastViewportReport = now
            previousReport += 1
            viewportTick &+= 1
            onViewportChanged?(visibleRegion, viewportTick)
            return
        }

        // Too soon to report again. Schedule the deferred one rather than
        // dropping it, so the navigator always catches up — and a rapid sequence
        // of changes still ends with a report that reflects the final state.
        guard pendingReport == nil else { return }
        let delay = Self.viewportReportInterval - (now - lastViewportReport)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingReport = nil
            self.reportViewport(force: true)
        }
        pendingReport = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Send any deferred report immediately, so the navigator agrees with the
    /// canvas the moment a gesture stops.
    private func flushPendingViewportReport() {
        reportViewport(force: true)
    }

    /// Force the pending report out now. Used when a gesture ends, and by tests
    /// that cannot wait for the throttle timer.
    func flushViewportReports() {
        reportViewport(force: true)
    }

    private static let viewportReportInterval: CFTimeInterval = 1.0 / 25.0
    private var lastViewportReport: CFTimeInterval = 0
    private var previousReport = 0
    private var pendingReport: DispatchWorkItem?

    // MARK: Events

    override func scrollWheel(with event: NSEvent) {
        handleScroll(event, anchor: convert(event.locationInWindow, from: nil), fromMonitor: false)
    }

    private func handleScroll(_ event: NSEvent, anchor: CGPoint, fromMonitor: Bool) {
        GestureTrace.log("scroll precision=\(event.hasPreciseScrollingDeltas) dy=\(event.scrollingDeltaY) mag=\(event.value(forKey: magnificationKey) as? CGFloat ?? 0) monitor=\(fromMonitor)")

        // A trackpad pinch arrives as a scroll event carrying `magnification`.
        if let magnification = event.value(forKey: magnificationKey) as? CGFloat,
           magnification.isFinite, abs(magnification) > 0 {
            setZoom(zoom * (1 + magnification), anchor: anchor)
            return
        }

        guard let action = Self.scrollAction(
            scrollingDeltaY: event.scrollingDeltaY,
            hasPreciseDeltas: event.hasPreciseScrollingDeltas,
            modifierFlags: event.modifierFlags
        ) else { return }

        GestureTrace.log("  -> action \(action)")
        switch action {
        case .zoom(let factor):
            setZoom(zoom * factor, anchor: anchor)
        case .pan:
            panBy(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY)
        }
    }

    /// What a scroll event should do.
    enum ScrollAction: Equatable {
        case zoom(factor: CGFloat)
        case pan
    }

    /// How much one wheel notch changes the zoom. Tuned so a few clicks move a
    /// useful amount without overshooting.
    static let wheelZoomRate: CGFloat = 0.06

    /// Decide what a scroll gesture means.
    ///
    /// A wheel with detents (`hasPreciseDeltas == false`) zooms — that is the
    /// gesture people reach for on a photo, and a mouse has no pinch. A trackpad
    /// reports precise deltas, so two-finger scrolling pans and ⌘/⌥-scroll zooms.
    /// Returns nil when the event carries nothing to act on.
    static func scrollAction(
        scrollingDeltaY: CGFloat,
        hasPreciseDeltas: Bool,
        modifierFlags: NSEvent.ModifierFlags
    ) -> ScrollAction? {
        let wantsZoom = !hasPreciseDeltas
            || modifierFlags.contains(.command)
            || modifierFlags.contains(.option)

        guard wantsZoom else { return .pan }
        guard scrollingDeltaY.isFinite, scrollingDeltaY != 0 else { return nil }
        return .zoom(factor: 1 + scrollingDeltaY * wheelZoomRate)
    }

    override func magnify(with event: NSEvent) {
        GestureTrace.log("magnify \(event.magnification)")
        setZoom(
            zoom * (1 + event.magnification),
            anchor: convert(event.locationInWindow, from: nil)
        )
    }

    override func mouseDragged(with event: NSEvent) {
        panBy(dx: event.deltaX, dy: event.deltaY)
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

    private let magnificationKey = "magnification"
}
