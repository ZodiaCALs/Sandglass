import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// A selectable backdrop preset.
///
/// Every preset is deliberately dark or mid-toned so the glass panels and their
/// light text keep their contrast; a near-white backdrop would wash the whole
/// interface out.
struct BackgroundPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let top: Color
    let bottom: Color
    /// Whether this backdrop is light enough to need dark text.
    var isLight: Bool = false

    static let all: [BackgroundPreset] = [
        BackgroundPreset(
            id: "ember",
            name: "Ember",
            top: Color(red: 0.16, green: 0.10, blue: 0.09),
            bottom: Color(red: 0.06, green: 0.05, blue: 0.07)
        ),
        BackgroundPreset(
            id: "slate",
            name: "Slate",
            top: Color(red: 0.13, green: 0.15, blue: 0.19),
            bottom: Color(red: 0.05, green: 0.06, blue: 0.08)
        ),
        BackgroundPreset(
            id: "dusk",
            name: "Dusk",
            top: Color(red: 0.15, green: 0.11, blue: 0.22),
            bottom: Color(red: 0.06, green: 0.05, blue: 0.11)
        ),
        BackgroundPreset(
            id: "forest",
            name: "Forest",
            top: Color(red: 0.09, green: 0.16, blue: 0.14),
            bottom: Color(red: 0.04, green: 0.07, blue: 0.07)
        ),
        BackgroundPreset(
            id: "ocean",
            name: "Ocean",
            top: Color(red: 0.08, green: 0.14, blue: 0.22),
            bottom: Color(red: 0.03, green: 0.06, blue: 0.11)
        ),
        BackgroundPreset(
            id: "linen",
            name: "Linen",
            top: Color(red: 0.90, green: 0.88, blue: 0.85),
            bottom: Color(red: 0.74, green: 0.72, blue: 0.70),
            isLight: true
        )
    ]

    static func preset(id: String) -> BackgroundPreset {
        all.first { $0.id == id } ?? all[1]
    }
}

/// How the backdrop is chosen.
enum BackgroundMode: String, CaseIterable {
    case preset
    case image

    var label: String {
        switch self {
        case .preset: return "Colour"
        case .image: return "Picture"
        }
    }
}

/// Where the chosen background image lives on disk.
///
/// The file is copied into Application Support rather than referenced in place,
/// so the background keeps working if the original is moved or deleted, and the
/// app never needs a security-scoped bookmark.
enum BackgroundImageStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Sandglass", isDirectory: true)
    }

    static var currentImageURL: URL {
        directory.appendingPathComponent("background.jpg")
    }

    /// Copy a user-chosen image in, downscaled so it stays cheap to draw.
    @discardableResult
    static func importImage(from source: URL) throws -> URL {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        guard let image = NSImage(contentsOf: source) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        // Cap the long edge: a background never needs more than a screen's worth,
        // and this keeps memory and redraw cost predictable.
        let maxEdge: CGFloat = 2560
        let size = image.size
        let scale = min(1, maxEdge / max(size.width, size.height, 1))
        let target = NSSize(width: max(1, size.width * scale), height: max(1, size.height * scale))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(target.width),
            pixelsHigh: Int(target.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: false,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        rep.size = target

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: target),
            from: NSRect(origin: .zero, size: size),
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
            throw CocoaError(.fileWriteUnknown)
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: currentImageURL, options: .atomic)
        return currentImageURL
    }

    static func removeImage() {
        try? FileManager.default.removeItem(at: currentImageURL)
    }

    static var hasImage: Bool {
        FileManager.default.fileExists(atPath: currentImageURL.path)
    }
}

/// Loads and caches the background image, and reports its brightness so the
/// interface can pick a matching colour scheme.
@MainActor
final class BackgroundImageLoader: ObservableObject {
    @Published private(set) var image: NSImage?
    /// True when the picture is bright enough to need dark text over it.
    @Published private(set) var isLight = false

    private var loadedPath: String?

    func refresh() {
        let url = BackgroundImageStore.currentImageURL
        guard BackgroundImageStore.hasImage else {
            image = nil
            loadedPath = nil
            isLight = false
            return
        }
        guard loadedPath != url.path || image == nil else { return }

        guard let loaded = NSImage(contentsOf: url) else {
            image = nil
            loadedPath = nil
            isLight = false
            return
        }
        image = loaded
        loadedPath = url.path
        isLight = Self.averageLuminance(of: loaded) > 0.62
    }

    /// Mean luminance of a small sample, used only to choose light or dark text.
    private static func averageLuminance(of image: NSImage) -> Double {
        let side = 32
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: side,
            pixelsHigh: side,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return 0 }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy,
                   fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        var total = 0.0
        var samples = 0
        for y in 0..<side {
            for x in 0..<side {
                guard let colour = rep.colorAt(x: x, y: y) else { continue }
                total += 0.2126 * Double(colour.redComponent)
                    + 0.7152 * Double(colour.greenComponent)
                    + 0.0722 * Double(colour.blueComponent)
                samples += 1
            }
        }
        return samples > 0 ? total / Double(samples) : 0
    }
}

/// Turns the saved preferences into the actual backdrop view.
struct StageBackground: View {
    let mode: BackgroundMode
    let preset: BackgroundPreset
    let image: NSImage?
    /// Darkens or lightens the picture so the glass panels stay readable.
    let imageDim: Double

    var body: some View {
        ZStack {
            switch mode {
            case .preset:
                LinearGradient(
                    colors: [preset.top, preset.bottom],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

            case .image:
                if let image {
                    Color.black.ignoresSafeArea()
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .ignoresSafeArea()
                    // A gentle vignette keeps focus on the photo you are judging.
                    LinearGradient(
                        colors: [
                            Color.black.opacity(imageDim * 0.9),
                            Color.black.opacity(imageDim * 0.35),
                            Color.black.opacity(imageDim * 0.85)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea()
                } else {
                    LinearGradient(
                        colors: [preset.top, preset.bottom],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .ignoresSafeArea()
                }
            }
        }
    }
}
