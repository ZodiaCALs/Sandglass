import AppKit
import SwiftUI

/// The photo pane: one canvas — or two side by side in Compare — with the
/// floating glass controls above it and the navigator in the corner.
@MainActor
final class ViewerViewController: NSViewController {

    let model: ViewerModel
    /// Where the controls send their commands.
    var perform: (Command) -> Void = { _ in }

    private let library: Library
    private let previews: PreviewStore
    private let metadata: MetadataStore
    private let settings: AppSettings

    let primaryCanvas = ImageCanvasView()
    let secondaryCanvas = ImageCanvasView()
    private let stagePlate = NSView()
    private let navigator = NavigatorPanel()

    private var primaryPlaceholder: OverlayHostingView<PreviewPlaceholder>!
    private var secondaryPlaceholder: OverlayHostingView<PreviewPlaceholder>!
    private var photoOverlay: OverlayHostingView<PhotoOverlay>!
    private var compareOverlay: OverlayHostingView<PhotoOverlay>!
    private var controlBar: OverlayHostingView<ControlBar>!
    private var toastHost: OverlayHostingView<ToastHost>!

    private var observers: [ObservationLoop] = []
    private var shownPrimary: SlotIdentity?
    private var shownSecondary: SlotIdentity?
    private var isSyncing = false
    private var navigatorVisible = false

    private struct SlotIdentity: Equatable {
        let shotID: Shot.ID
        let kind: FileKind
    }

    init(library: Library, previews: PreviewStore, metadata: MetadataStore, settings: AppSettings, model: ViewerModel) {
        self.library = library
        self.previews = previews
        self.metadata = metadata
        self.settings = settings
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func loadView() {
        let root = LayoutReportingView()
        root.onLayout = { [weak self] in self?.layoutContent() }
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        stagePlate.wantsLayer = true
        view.addSubview(stagePlate)

        for canvas in [primaryCanvas, secondaryCanvas] {
            canvas.onViewportChange = { [weak self] canvas in self?.canvasDidChange(canvas) }
            view.addSubview(canvas)
        }
        secondaryCanvas.isHidden = true

        let send: (Command) -> Void = { [weak self] command in self?.perform(command) }

        primaryPlaceholder = OverlayHostingView(rootView: PreviewPlaceholder(status: .loading, kind: .jpg, alternative: nil, perform: send))
        secondaryPlaceholder = OverlayHostingView(rootView: PreviewPlaceholder(status: .loading, kind: .nef, alternative: nil, perform: send))
        photoOverlay = OverlayHostingView(rootView: PhotoOverlay(library: library, metadata: metadata))
        compareOverlay = OverlayHostingView(rootView: PhotoOverlay(library: library, metadata: metadata, kindOverride: .nef))
        controlBar = OverlayHostingView(rootView: ControlBar(library: library, viewer: model, previews: previews, perform: send))
        toastHost = OverlayHostingView(rootView: ToastHost(model: model))

        primaryPlaceholder.isHidden = true
        secondaryPlaceholder.isHidden = true
        compareOverlay.isHidden = true
        photoOverlay.passesEventsThrough = true
        compareOverlay.passesEventsThrough = true
        toastHost.passesEventsThrough = true

        let relayout: () -> Void = { [weak self] in self?.view.needsLayout = true }
        photoOverlay.onSizeChange = relayout
        compareOverlay.onSizeChange = relayout
        controlBar.onSizeChange = relayout

        view.addSubview(primaryPlaceholder)
        view.addSubview(secondaryPlaceholder)
        view.addSubview(photoOverlay)
        view.addSubview(compareOverlay)

        navigator.map.onMove = { [weak self] point in self?.primaryCanvas.centre(on: point) }
        navigator.map.onFit = { [weak self] in self?.primaryCanvas.zoomToFit() }
        navigator.map.onScroll = { [weak self] event in self?.zoomFromNavigator(event) }
        navigator.alphaValue = 0
        navigator.isHidden = true
        view.addSubview(navigator)

        view.addSubview(controlBar)
        view.addSubview(toastHost)

        observers.append(ObservationLoop { [weak self] in self?.applySlots() })
        observers.append(ObservationLoop { [weak self] in self?.applyPreferences() })
        observers.append(ObservationLoop { [weak self] in self?.loadMetadataForCurrentPhoto() })
    }

    // MARK: Commands

    func zoomIn() { primaryCanvas.zoomIn() }
    func zoomOut() { primaryCanvas.zoomOut() }
    func zoomToFit() { primaryCanvas.zoomToFit() }
    func zoomToActualSize() { primaryCanvas.zoomToActualPixels() }
    func toggleZoom() { primaryCanvas.toggleZoom() }

    var isZoomedIn: Bool { primaryCanvas.viewport.isZoomedIn }

    // MARK: Following the model

    private func applySlots() {
        let primary = previews.primary
        let secondary = previews.secondary
        let comparing = model.isComparing && secondary != nil

        shownPrimary = apply(primary, to: primaryCanvas, placeholder: primaryPlaceholder, shown: shownPrimary)

        if comparing {
            let wasShowing = shownSecondary
            shownSecondary = apply(secondary, to: secondaryCanvas, placeholder: secondaryPlaceholder, shown: shownSecondary)
            if wasShowing != shownSecondary, secondaryCanvas.image != nil, primaryCanvas.image != nil {
                // Join Compare at the main pane's framing, not at fit.
                secondaryCanvas.adopt(zoom: primaryCanvas.viewport.zoom, centre: primaryCanvas.viewport.centre)
            }
            compareOverlay.rootView = PhotoOverlay(library: library, metadata: metadata, kindOverride: secondary?.kind ?? .nef)
            photoOverlay.rootView = PhotoOverlay(library: library, metadata: metadata, kindOverride: primary?.kind)
        } else {
            if shownSecondary != nil {
                secondaryCanvas.setImage(nil, allPixels: false, resetFraming: true)
                shownSecondary = nil
            }
            secondaryPlaceholder.isHidden = true
            photoOverlay.rootView = PhotoOverlay(library: library, metadata: metadata)
        }

        if secondaryCanvas.isHidden == comparing {
            secondaryCanvas.isHidden = !comparing
            compareOverlay.isHidden = !comparing
            view.needsLayout = true
        }

        let mapImage = (primary?.display ?? primary?.full)?.cgImage
        if navigator.map.image !== mapImage {
            navigator.map.image = mapImage
            view.needsLayout = true
        }
        primaryCanvas.setAccessibilityLabel(library.currentShot.map { "\($0.displayName), \(library.kind.label)" })
        updateSharpening()
    }

    /// Put a slot's best bitmap on a canvas. Returns what is now shown.
    private func apply(
        _ slot: PreviewStore.Slot?,
        to canvas: ImageCanvasView,
        placeholder: OverlayHostingView<PreviewPlaceholder>,
        shown: SlotIdentity?
    ) -> SlotIdentity? {
        guard let slot else {
            if canvas.image != nil { canvas.setImage(nil, allPixels: false, resetFraming: true) }
            placeholder.isHidden = true
            return nil
        }
        let identity = SlotIdentity(shotID: slot.shotID, kind: slot.kind)
        let isNewPhoto = identity != shown
        let bitmap = isNewPhoto
            ? (slot.display ?? slot.full)
            : preferredBitmap(for: slot, on: canvas)

        if let bitmap {
            if isNewPhoto || canvas.image !== bitmap.cgImage {
                canvas.setImage(
                    bitmap.cgImage,
                    logicalSize: bitmap.sourceSize,
                    allPixels: bitmap.isFullResolution,
                    resetFraming: isNewPhoto
                )
            }
            placeholder.isHidden = true
        } else {
            if canvas.image != nil { canvas.setImage(nil, allPixels: false, resetFraming: true) }
            let alternative = slot.kind.other
            let shot = library.shots.first { $0.id == slot.shotID }
            placeholder.rootView = PreviewPlaceholder(
                status: slot.status,
                kind: slot.kind,
                alternative: shot?.url(for: alternative) != nil ? alternative : nil,
                perform: { [weak self] command in self?.perform(command) }
            )
            placeholder.isHidden = false
        }
        return identity
    }

    /// The screen-sized rendition at fit — it is downsampled with care, and
    /// already matches the display pixel for pixel — and every pixel once zoom
    /// magnifies past it. A little hysteresis stops flicker at the boundary.
    private func preferredBitmap(for slot: PreviewStore.Slot, on canvas: ImageCanvasView) -> DecodedImage? {
        guard let display = slot.display else { return slot.full }
        guard let full = slot.full, full.cgImage !== display.cgImage else { return display }
        let density = displayDensity(of: display, on: canvas)
        let threshold: CGFloat = canvas.image === full.cgImage ? 0.95 : 1.02
        return density > threshold ? full : display
    }

    /// Device pixels per pixel of `bitmap` at the canvas's current zoom.
    private func displayDensity(of bitmap: DecodedImage, on canvas: ImageCanvasView) -> CGFloat {
        let viewport = canvas.viewport
        return viewport.displayedSize.width * viewport.backingScale / CGFloat(max(bitmap.cgImage.width, 1))
    }

    private func slot(for canvas: ImageCanvasView) -> PreviewStore.Slot? {
        canvas === primaryCanvas ? previews.primary : previews.secondary
    }

    private func canvasDidChange(_ canvas: ImageCanvasView) {
        if let slot = slot(for: canvas) {
            // Swap between the screen-sized rendition and every pixel as zoom crosses over.
            if let preferred = preferredBitmap(for: slot, on: canvas), preferred.cgImage !== canvas.image, canvas.image != nil {
                canvas.setImage(preferred.cgImage, logicalSize: preferred.sourceSize, allPixels: preferred.isFullResolution, resetFraming: false)
                return
            }
            // Zoomed past what the rendition holds: fetch the real pixels.
            if let display = slot.display, !slot.hasAllPixels, displayDensity(of: display, on: canvas) > 1.0 {
                previews.requestFullResolution()
            }
        }

        if canvas === primaryCanvas {
            model.update(with: canvas.viewport, hasImage: canvas.image != nil)
            updateNavigator()
            updateSharpening()
        }

        if model.isComparing, !isSyncing {
            isSyncing = true
            let other = canvas === primaryCanvas ? secondaryCanvas : primaryCanvas
            if other.image != nil {
                other.adopt(zoom: canvas.viewport.zoom, centre: canvas.viewport.centre)
            }
            isSyncing = false
        }
    }

    private func updateSharpening() {
        guard let slot = previews.primary, let display = slot.display, !slot.hasAllPixels else {
            model.setSharpening(false)
            return
        }
        model.setSharpening(previews.isLoadingFullResolution && displayDensity(of: display, on: primaryCanvas) > 1.02)
    }

    private func applyPreferences() {
        let tone: NSColor? = switch settings.stageTone {
        case .backdrop: nil
        case .black: .black
        case .charcoal: NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
        case .gray: NSColor(srgbRed: 0.46, green: 0.46, blue: 0.46, alpha: 1)
        }
        stagePlate.layer?.backgroundColor = tone?.cgColor
        stagePlate.isHidden = tone == nil
        let showsOverlay = settings.showsInfoOverlay
        photoOverlay.alphaValue = showsOverlay ? 1 : 0
        compareOverlay.alphaValue = showsOverlay ? 1 : 0
        let magnification = CGFloat(settings.zoomTarget.magnification)
        primaryCanvas.toggleMagnification = magnification
        secondaryCanvas.toggleMagnification = magnification
    }

    private func loadMetadataForCurrentPhoto() {
        // The overlay shows exposure details, so read them as each photo arrives.
        guard settings.showsInfoOverlay, let url = library.currentURL else { return }
        metadata.load(url)
    }

    // MARK: Navigator

    private func updateNavigator() {
        let viewport = primaryCanvas.viewport
        navigator.map.region = viewport.visibleRegion
        navigator.percentText = Format.percent(viewport.pixelMagnification)

        let shouldShow = viewport.isZoomedIn && primaryCanvas.image != nil
        guard shouldShow != navigatorVisible else { return }
        navigatorVisible = shouldShow
        if shouldShow {
            navigator.isHidden = false
            view.needsLayout = true
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            navigator.animator().alphaValue = shouldShow ? 1 : 0
        }
        if !shouldShow {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(220))
                guard let self, !self.navigatorVisible else { return }
                self.navigator.isHidden = true
            }
        }
    }

    private func zoomFromNavigator(_ event: NSEvent) {
        let intent = ZoomInput.interpret(
            deltaX: 0,
            deltaY: event.scrollingDeltaY,
            hasPreciseDeltas: event.hasPreciseScrollingDeltas,
            isDirectionInverted: event.isDirectionInvertedFromDevice,
            modifiers: .command
        )
        if case .zoom(let factor) = intent {
            primaryCanvas.zoom(to: primaryCanvas.viewport.zoom * factor, animated: false)
        }
    }

    // MARK: Layout

    private func layoutContent() {
        let bounds = view.bounds
        let top = view.safeAreaInsets.top
        let area = CGRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
        stagePlate.frame = area

        let comparing = !secondaryCanvas.isHidden
        if comparing {
            let gap: CGFloat = 2
            let half = ((area.width - gap) / 2).rounded(.down)
            primaryCanvas.frame = CGRect(x: area.minX, y: area.minY, width: half, height: area.height)
            secondaryCanvas.frame = CGRect(x: area.minX + half + gap, y: area.minY, width: area.width - half - gap, height: area.height)
        } else {
            primaryCanvas.frame = area
        }
        primaryPlaceholder.frame = primaryCanvas.frame
        secondaryPlaceholder.frame = secondaryCanvas.frame

        let compact = area.width < 780
        if model.isCompact != compact { model.isCompact = compact }

        let barSize = controlBar.fittingSize
        let barWidth = min(barSize.width, max(area.width - 24, 0))
        controlBar.frame = CGRect(
            x: (area.midX - barWidth / 2).rounded(),
            y: area.maxY - barSize.height - 16,
            width: barWidth,
            height: barSize.height
        )

        let overlaySize = photoOverlay.fittingSize
        photoOverlay.frame = CGRect(
            x: primaryCanvas.frame.minX + 14,
            y: area.minY + 14,
            width: min(overlaySize.width, max(primaryCanvas.frame.width - 28, 0)),
            height: overlaySize.height
        )
        if comparing {
            let size = compareOverlay.fittingSize
            compareOverlay.frame = CGRect(
                x: secondaryCanvas.frame.minX + 14,
                y: area.minY + 14,
                width: min(size.width, max(secondaryCanvas.frame.width - 28, 0)),
                height: size.height
            )
        }

        let toastWidth = min(520, area.width)
        toastHost.frame = CGRect(
            x: (area.midX - toastWidth / 2).rounded(),
            y: controlBar.frame.minY - 56,
            width: toastWidth,
            height: 48
        )

        let aspect = navigator.map.image.map { CGFloat($0.width) / CGFloat(max($0.height, 1)) } ?? 1.5
        let size = navigator.preferredSize(forAspectRatio: aspect)
        var frame = CGRect(x: area.maxX - size.width - 16, y: area.maxY - size.height - 16, width: size.width, height: size.height)
        if frame.minX < controlBar.frame.maxX + 12 {
            // Not enough room beside the control bar: sit above it instead.
            frame.origin.y = controlBar.frame.minY - size.height - 12
        }
        navigator.frame = frame

        let scale = view.window?.backingScaleFactor ?? 2
        previews.updatePane(size: primaryCanvas.bounds.size, backingScale: scale)
    }
}

/// Floats the current toast, animating it in and out.
struct ToastHost: View {
    let model: ViewerModel

    var body: some View {
        ZStack {
            if let toast = model.toast {
                ToastView(toast: toast)
                    .id(toast.id)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: model.toast)
    }
}

/// A view that tells its controller when it lays out, for manual layout.
final class LayoutReportingView: FlippedView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }
}
