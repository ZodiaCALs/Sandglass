import AppKit
import ImageIO
import UniformTypeIdentifiers

/// What sits behind the whole interface.
///
/// The default is translucent glass: the desktop shows through, blurred and
/// tinted — Fluent's Acrylic, done with macOS's behind-window vibrancy. A solid
/// colour or a picture of your own are the alternatives. None of this ever
/// touches the photos themselves.
@MainActor
final class BackdropView: NSView {
    private let effect = NSVisualEffectView()
    private let tint = NSView()
    private let picture = LayerImageView()
    private let dim = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        effect.material = .underWindowBackground
        effect.blendingMode = .behindWindow
        effect.state = .active
        tint.wantsLayer = true
        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor.black.cgColor
        picture.gravity = .resizeAspectFill
        for view in [effect, tint, picture, dim] {
            view.autoresizingMask = [.width, .height]
            view.frame = bounds
            addSubview(view)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func apply(style: AppSettings.Backdrop, tint strength: Double, color: RGBColor, picture image: CGImage?, dim amount: Double) {
        let resolved: AppSettings.Backdrop = style == .picture && image == nil ? .glass : style
        switch resolved {
        case .glass:
            effect.isHidden = false
            tint.isHidden = false
            tint.layer?.backgroundColor = NSColor(color, alpha: CGFloat(min(max(strength, 0), 1))).cgColor
            picture.isHidden = true
            dim.isHidden = true
        case .color:
            effect.isHidden = true
            tint.isHidden = false
            tint.layer?.backgroundColor = NSColor(color).cgColor
            picture.isHidden = true
            dim.isHidden = true
        case .picture:
            effect.isHidden = true
            tint.isHidden = true
            picture.isHidden = false
            picture.setImage(image, animated: false)
            dim.isHidden = false
            dim.alphaValue = CGFloat(min(max(amount, 0), 0.9))
        }
    }
}

/// The picture used as a backdrop, copied into Application Support and scaled
/// to a screen's worth so it keeps working if the original moves, and stays
/// cheap to draw.
enum BackdropPicture {
    static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Sandglass", isDirectory: true).appendingPathComponent("Backdrop.jpg")
    }

    static var exists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    static func load() -> CGImage? {
        guard exists, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    static func importPicture(from source: URL) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 2560
        ]
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    static func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// A rounded Liquid Glass panel with content inside.
@MainActor
final class GlassContainerView: NSView {
    let content = FlippedView()
    private let glass = NSGlassEffectView()

    init(cornerRadius: CGFloat) {
        super.init(frame: .zero)
        glass.cornerRadius = cornerRadius
        glass.contentView = content
        addSubview(glass)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        glass.frame = bounds
        content.frame = glass.bounds
        for child in content.subviews {
            child.frame = content.bounds
        }
    }
}

/// Accepts folders and photos dropped anywhere on the window.
@MainActor
final class DropTargetView: NSView {
    var onDrop: (([URL]) -> Bool)?
    var onHighlight: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let acceptable = !Self.urls(from: sender).isEmpty
        onHighlight?(acceptable)
        return acceptable ? .copy : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onHighlight?(false)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        onHighlight?(false)
        return onDrop?(Self.urls(from: sender)) ?? false
    }

    /// Folders, and JPG / NEF files (which open their folder).
    private static func urls(from info: any NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        return urls.filter { url in
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            return exists && (isDirectory.boolValue || FileKind.from(url: url) != nil)
        }
    }
}
