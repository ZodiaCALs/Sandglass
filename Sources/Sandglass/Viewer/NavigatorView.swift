import AppKit
import QuartzCore

/// The map in the navigator: the whole photo, with everything outside the
/// visible region shaded and the region itself outlined.
///
/// It is drawn with layers and updated directly by the canvas on every frame —
/// no SwiftUI state, no throttling — so the rectangle tracks zooming and panning
/// exactly. The map always has the photo's own aspect ratio, so the rectangle
/// maps onto the photo one-to-one.
@MainActor
final class NavigatorMapView: NSView {

    /// The whole photo.
    var image: CGImage? {
        didSet {
            guard image !== oldValue else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            mapLayer.contents = image
            CATransaction.commit()
        }
    }

    /// The visible part of the photo, normalised.
    var region = CGRect(x: 0, y: 0, width: 1, height: 1) {
        didSet {
            guard region != oldValue else { return }
            updateOverlay()
        }
    }

    /// Centre the photo on a normalised point.
    var onMove: ((CGPoint) -> Void)?
    /// A scroll over the map, to zoom the photo.
    var onScroll: ((NSEvent) -> Void)?
    /// Double-click: back to fit.
    var onFit: (() -> Void)?

    private let mapLayer = CALayer()
    private let shadeLayer = CAShapeLayer()
    private let frameLayer = CAShapeLayer()
    private var drag: NavigatorDrag?

    private var geometry: NavigatorGeometry { NavigatorGeometry(mapRect: bounds) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        mapLayer.contentsGravity = .resize
        mapLayer.minificationFilter = .trilinear
        mapLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]

        shadeLayer.fillRule = .evenOdd
        shadeLayer.fillColor = NSColor.black.withAlphaComponent(0.5).cgColor

        frameLayer.fillColor = nil
        frameLayer.strokeColor = NSColor.white.cgColor
        frameLayer.lineWidth = 1.5
        frameLayer.shadowColor = NSColor.black.cgColor
        frameLayer.shadowOpacity = 0.7
        frameLayer.shadowRadius = 1.5
        frameLayer.shadowOffset = .zero

        layer?.addSublayer(mapLayer)
        layer?.addSublayer(shadeLayer)
        layer?.addSublayer(frameLayer)

        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Navigator")
        toolTip = "Drag the rectangle to move around the photo · double-click to fit"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mapLayer.frame = bounds
        shadeLayer.frame = bounds
        frameLayer.frame = bounds
        CATransaction.commit()
        updateOverlay()
    }

    private func updateOverlay() {
        let rect = geometry.viewportRect(for: region)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let shade = CGMutablePath()
        shade.addRect(bounds)
        shade.addRect(rect)
        shadeLayer.path = shade
        let outline = rect.insetBy(dx: 0.75, dy: 0.75)
        if outline.width > 0, outline.height > 0 {
            let radius = min(2, outline.width / 2, outline.height / 2)
            frameLayer.path = CGPath(roundedRect: outline, cornerWidth: radius, cornerHeight: radius, transform: nil)
        } else {
            frameLayer.path = nil
        }
        CATransaction.commit()
        window?.invalidateCursorRects(for: self)
    }

    // MARK: Events

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount >= 2 {
            drag = nil
            onFit?()
            return
        }
        let begun = NavigatorDrag.begin(at: point, viewportRect: geometry.viewportRect(for: region))
        drag = begun
        onMove?(begun.targetCentre(for: point, in: geometry))
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        onMove?(drag.targetCentre(for: convert(event.locationInWindow, from: nil), in: geometry))
    }

    override func mouseUp(with event: NSEvent) {
        drag = nil
        NSCursor.openHand.set()
        window?.invalidateCursorRects(for: self)
    }

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
        addCursorRect(geometry.viewportRect(for: region).intersection(bounds), cursor: .openHand)
    }
}

/// The navigator as it appears in the corner: a Liquid Glass panel holding the
/// map and the current zoom percentage.
@MainActor
final class NavigatorPanel: NSView {

    let map = NavigatorMapView()

    var percentText = "" {
        didSet { label.stringValue = percentText }
    }

    private let glass = NSGlassEffectView()
    private let content = FlippedView()
    private let label = NSTextField(labelWithString: "")

    private static let padding: CGFloat = 6
    private static let labelHeight: CGFloat = 18
    private static let maxMapSize = CGSize(width: 184, height: 132)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        glass.cornerRadius = 14
        glass.contentView = content
        addSubview(glass)

        label.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.lineBreakMode = .byClipping
        content.addSubview(map)
        content.addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isFlipped: Bool { true }

    /// The panel size for a photo of this aspect ratio: the map keeps the
    /// photo's shape exactly, landscape or portrait or panorama.
    func preferredSize(forAspectRatio aspect: CGFloat) -> NSSize {
        let mapSize = NavigatorGeometry.mapSize(
            forAspectRatio: aspect,
            maxWidth: Self.maxMapSize.width,
            maxHeight: Self.maxMapSize.height
        )
        let width = max(mapSize.width, 84) + Self.padding * 2
        return NSSize(width: width, height: mapSize.height + Self.padding * 2 + Self.labelHeight)
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        content.frame = glass.bounds
        let mapHeight = max(1, bounds.height - Self.padding * 2 - Self.labelHeight)
        let aspect = map.image.map { CGFloat($0.width) / CGFloat(max($0.height, 1)) } ?? 1.5
        let mapWidth = min(bounds.width - Self.padding * 2, (mapHeight * aspect).rounded())
        map.frame = NSRect(
            x: ((bounds.width - mapWidth) / 2).rounded(),
            y: Self.padding,
            width: mapWidth,
            height: mapHeight
        )
        label.frame = NSRect(x: Self.padding, y: Self.padding + mapHeight + 1, width: bounds.width - Self.padding * 2, height: Self.labelHeight - 2)
    }
}
