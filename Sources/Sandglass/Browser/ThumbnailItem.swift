import AppKit
import QuartzCore

/// One tile in the thumbnail browser.
@MainActor
final class ThumbnailItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ThumbnailItem")

    /// The file whose thumbnail this tile is showing (or loading).
    var representedURL: URL?
    var loadTask: Task<Void, Never>?

    var cell: ThumbnailCellView {
        if let cell = view as? ThumbnailCellView { return cell }
        let cell = ThumbnailCellView(frame: view.frame)
        view = cell
        return cell
    }

    override func loadView() {
        view = ThumbnailCellView(frame: NSRect(x: 0, y: 0, width: 120, height: 100))
    }

    override var isSelected: Bool {
        didSet { cell.isSelected = isSelected }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        representedURL = nil
        cell.setImage(nil, animated: false)
        cell.isUnavailable = false
    }
}

/// A tile: the photo on a soft plate, its name, which variants exist and which
/// are flagged. Hover and selection follow Fluent's conventions — a gentle lift
/// on hover, an accent ring around the selection.
@MainActor
final class ThumbnailCellView: NSView {

    enum Style {
        /// Photo above, name and variant chips below (sidebar, grid).
        case card
        /// Just the photo, with chips over it (filmstrip).
        case compact
    }

    var style: Style = .card {
        didSet {
            guard style != oldValue else { return }
            nameField.isHidden = style == .compact
            chips.drawsOnPhoto = style == .compact
            needsLayout = true
        }
    }

    var name = "" {
        didSet { nameField.stringValue = name }
    }

    var isSelected = false {
        didSet { if isSelected != oldValue { needsDisplay = true } }
    }

    var isUnavailable = false {
        didSet { placeholder.image = NSImage.symbol(isUnavailable ? "eye.slash" : "photo") }
    }

    var onDoubleClick: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?

    private let imageView = LayerImageView()
    private let placeholder = NSImageView()
    private let nameField = NSTextField(labelWithString: "")
    private let chips = KindChipsView()
    private let badge = FlagBadgeView()
    private var isHovered = false
    private var hoverArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous

        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 6
        imageView.layer?.cornerCurve = .continuous
        imageView.layer?.masksToBounds = true
        imageView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.22).cgColor

        placeholder.image = NSImage.symbol("photo")
        placeholder.contentTintColor = .tertiaryLabelColor
        placeholder.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)

        nameField.font = .systemFont(ofSize: 10.5, weight: .medium)
        nameField.textColor = .labelColor
        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.maximumNumberOfLines = 1

        addSubview(imageView)
        addSubview(placeholder)
        addSubview(nameField)
        addSubview(chips)
        addSubview(badge)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    func setImage(_ image: CGImage?, animated: Bool) {
        imageView.setImage(image, animated: animated)
        placeholder.isHidden = image != nil
    }

    func setFlags(available: [FileKind], flagged: FlagSelection) {
        chips.update(available: available, flagged: flagged)
        badge.selection = flagged
        needsLayout = true
    }

    override func updateLayer() {
        let accent = NSColor.controlAccentColor
        if isSelected {
            layer?.backgroundColor = accent.withAlphaComponent(0.2).cgColor
            layer?.borderColor = accent.cgColor
            layer?.borderWidth = 2.5
        } else {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(isHovered ? 0.09 : 0.035).cgColor
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(isHovered ? 0.16 : 0.07).cgColor
            layer?.borderWidth = 1
        }
    }

    override func layout() {
        super.layout()
        let bounds = self.bounds
        let chipSize = chips.intrinsicContentSize
        switch style {
        case .card:
            let inset: CGFloat = 6
            let footer: CGFloat = 22
            imageView.frame = CGRect(x: inset, y: inset, width: bounds.width - inset * 2, height: max(0, bounds.height - inset * 2 - footer))
            let footerY = imageView.frame.maxY + 4
            chips.frame = CGRect(x: bounds.width - inset - chipSize.width, y: footerY + 1, width: chipSize.width, height: chipSize.height)
            nameField.frame = CGRect(x: inset + 1, y: footerY, width: max(0, chips.frame.minX - inset - 5), height: 16)
        case .compact:
            imageView.frame = bounds.insetBy(dx: 4, dy: 4)
            chips.frame = CGRect(x: imageView.frame.minX + 4, y: imageView.frame.maxY - chipSize.height - 4, width: chipSize.width, height: chipSize.height)
        }
        badge.frame = CGRect(x: imageView.frame.maxX - 22, y: imageView.frame.minY + 4, width: 18, height: 18)
        placeholder.frame = CGRect(x: imageView.frame.midX - 12, y: imageView.frame.midY - 12, width: 24, height: 24)
    }

    // MARK: Events

    /// Clicks on the label or chips belong to the tile, so selection always works.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 {
            onDoubleClick?()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }
}

/// A view whose layer shows a bitmap directly, scaled to fit.
@MainActor
final class LayerImageView: NSView {
    var gravity: CALayerContentsGravity = .resizeAspect {
        didSet { layer?.contentsGravity = gravity }
    }

    private(set) var image: CGImage?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.contentsGravity = gravity
        layer?.minificationFilter = .trilinear
        layer?.magnificationFilter = .linear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func setImage(_ newImage: CGImage?, animated: Bool) {
        guard newImage !== image else { return }
        image = newImage
        if animated, newImage != nil {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.18
            layer?.add(fade, forKey: "contents")
        }
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        layer?.contents = newImage
        CATransaction.commit()
    }
}

/// "JPG" "NEF" chips, amber when flagged.
@MainActor
final class KindChipsView: NSView {
    var drawsOnPhoto = false {
        didSet { needsDisplay = true }
    }

    private var available: [FileKind] = []
    private var flagged: FlagSelection = []
    private static let font = NSFont.systemFont(ofSize: 8.5, weight: .bold)
    private static let height: CGFloat = 14

    override var isFlipped: Bool { true }

    func update(available: [FileKind], flagged: FlagSelection) {
        guard available != self.available || flagged != self.flagged else { return }
        self.available = available
        self.flagged = flagged
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        var width: CGFloat = 0
        for kind in available {
            width += Self.chipWidth(kind.label) + 3
        }
        return NSSize(width: max(0, width - 3), height: Self.height)
    }

    private static func attributes(color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: font, .kern: 0.4, .foregroundColor: color]
    }

    private static func chipWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: attributes(color: .white)).width) + 9
    }

    override func draw(_ dirtyRect: NSRect) {
        var x: CGFloat = 0
        for kind in available {
            let isFlagged = flagged.contains(.kind(kind))
            let width = Self.chipWidth(kind.label)
            let chip = NSRect(x: x, y: 0, width: width, height: Self.height)
            let fill: NSColor = isFlagged
                ? Theme.flagNS
                : (drawsOnPhoto ? NSColor.black.withAlphaComponent(0.55) : NSColor.labelColor.withAlphaComponent(0.13))
            fill.setFill()
            NSBezierPath(roundedRect: chip, xRadius: Self.height / 2, yRadius: Self.height / 2).fill()
            let textColor: NSColor = isFlagged || drawsOnPhoto ? .white : NSColor.labelColor.withAlphaComponent(0.85)
            let text = kind.label as NSString
            let attributes = Self.attributes(color: textColor)
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: chip.minX + (width - size.width) / 2, y: chip.midY - size.height / 2), withAttributes: attributes)
            x = chip.maxX + 3
        }
    }
}

/// The round amber flag badge in a tile's corner — one flag, or two crossed for both.
@MainActor
final class FlagBadgeView: NSView {
    var selection: FlagSelection = [] {
        didSet {
            isHidden = selection.isEmpty
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.75, dy: 0.75))
        Theme.flagNS.setFill()
        circle.fill()
        NSColor.white.withAlphaComponent(0.85).setStroke()
        circle.lineWidth = 1
        circle.stroke()

        let name = selection.kinds.count > 1 ? "flag.2.crossed.fill" : "flag.fill"
        let configuration = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        guard let symbol = NSImage.symbol(name, fallback: "flag.fill").withSymbolConfiguration(configuration) else { return }
        let size = symbol.size
        let rect = NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
        symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
