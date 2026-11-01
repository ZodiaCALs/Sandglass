import Foundation
import Observation

/// User preferences, persisted in `UserDefaults` and observable by the interface.
@MainActor
@Observable
final class AppSettings {

    /// What sits behind the interface.
    enum Backdrop: String, CaseIterable, Sendable {
        /// Translucent frosted glass: the desktop shows through, blurred and tinted.
        case glass
        /// A solid colour.
        case color
        /// A picture of your choosing, dimmed.
        case picture

        var label: String {
            switch self {
            case .glass: "Glass"
            case .color: "Colour"
            case .picture: "Picture"
            }
        }
    }

    /// What sits directly behind the photo. Neutral tones keep colour judgement honest.
    enum StageTone: String, CaseIterable, Sendable {
        case backdrop
        case black
        case charcoal
        case gray

        var label: String {
            switch self {
            case .backdrop: "Backdrop"
            case .black: "Black"
            case .charcoal: "Charcoal"
            case .gray: "Mid grey"
            }
        }
    }

    enum Appearance: String, CaseIterable, Sendable {
        case dark
        case light
        case system

        var label: String {
            switch self {
            case .dark: "Dark"
            case .light: "Light"
            case .system: "System"
            }
        }
    }

    /// What double-click, Z and smart magnify zoom to.
    enum ZoomTarget: String, CaseIterable, Sendable {
        case actualPixels
        case doublePixels

        var label: String {
            switch self {
            case .actualPixels: "100%"
            case .doublePixels: "200%"
            }
        }

        /// Device pixels per image pixel.
        var magnification: Double {
            switch self {
            case .actualPixels: 1
            case .doublePixels: 2
            }
        }
    }

    /// Ready-made backdrop colours: dark and mid tones that let photos speak.
    static let colorPresets: [(name: String, hex: String)] = [
        ("Graphite", "#1C1D21"),
        ("Midnight", "#141B2D"),
        ("Slate", "#2B3550"),
        ("Dusk", "#2D2440"),
        ("Forest", "#1B2B26"),
        ("Ember", "#33221D"),
        ("Stone", "#5A5D66"),
        ("Linen", "#E7E4DE")
    ]

    @ObservationIgnored private let defaults: UserDefaults

    var layout: BrowserLayout { didSet { defaults.set(layout.rawValue, forKey: Key.layout) } }
    /// The layout to go back to when leaving Grid.
    var viewerLayout: BrowserLayout { didSet { defaults.set(viewerLayout.rawValue, forKey: Key.viewerLayout) } }
    var showsInspector: Bool { didSet { defaults.set(showsInspector, forKey: Key.showsInspector) } }
    var showsInfoOverlay: Bool { didSet { defaults.set(showsInfoOverlay, forKey: Key.showsInfoOverlay) } }
    /// Thumbnail size in points, for the sidebar and grid.
    var tileSize: Double { didSet { defaults.set(tileSize, forKey: Key.tileSize) } }

    var backdrop: Backdrop { didSet { defaults.set(backdrop.rawValue, forKey: Key.backdrop) } }
    /// How strongly the glass is tinted, 0 (clear) … 1 (opaque).
    var glassTint: Double { didSet { defaults.set(glassTint, forKey: Key.glassTint) } }
    var backdropColorHex: String { didSet { defaults.set(backdropColorHex, forKey: Key.backdropColor) } }
    var pictureDim: Double { didSet { defaults.set(pictureDim, forKey: Key.pictureDim) } }
    var stageTone: StageTone { didSet { defaults.set(stageTone.rawValue, forKey: Key.stageTone) } }
    var appearance: Appearance { didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) } }

    var reopenLastFolder: Bool { didSet { defaults.set(reopenLastFolder, forKey: Key.reopenLastFolder) } }
    var rememberFlags: Bool { didSet { defaults.set(rememberFlags, forKey: Key.rememberFlags) } }
    var preloadFullResolution: Bool { didSet { defaults.set(preloadFullResolution, forKey: Key.preloadFull) } }
    var decodeRawWhenZooming: Bool { didSet { defaults.set(decodeRawWhenZooming, forKey: Key.decodeRaw) } }
    var advanceAfterFlag: Bool { didSet { defaults.set(advanceAfterFlag, forKey: Key.advanceAfterFlag) } }
    var zoomTarget: ZoomTarget { didSet { defaults.set(zoomTarget.rawValue, forKey: Key.zoomTarget) } }
    var preferredKind: FileKind { didSet { defaults.set(preferredKind.rawValue, forKey: Key.preferredKind) } }

    var exportMode: ExportMode { didSet { defaults.set(exportMode.rawValue, forKey: Key.exportMode) } }
    var lastExportFolderPath: String? { didSet { defaults.set(lastExportFolderPath, forKey: Key.lastExportFolder) } }
    var lastFolderPath: String? { didSet { defaults.set(lastFolderPath, forKey: Key.lastFolder) } }
    private(set) var recentFolderPaths: [String] { didSet { defaults.set(recentFolderPaths, forKey: Key.recentFolders) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        layout = BrowserLayout(rawValue: defaults.string(forKey: Key.layout) ?? "") ?? .filmstrip
        viewerLayout = BrowserLayout(rawValue: defaults.string(forKey: Key.viewerLayout) ?? "") ?? .filmstrip
        showsInspector = defaults.object(forKey: Key.showsInspector) as? Bool ?? false
        showsInfoOverlay = defaults.object(forKey: Key.showsInfoOverlay) as? Bool ?? true
        tileSize = defaults.object(forKey: Key.tileSize) as? Double ?? 132
        backdrop = Backdrop(rawValue: defaults.string(forKey: Key.backdrop) ?? "") ?? .glass
        glassTint = defaults.object(forKey: Key.glassTint) as? Double ?? 0.55
        backdropColorHex = defaults.string(forKey: Key.backdropColor) ?? "#141B2D"
        pictureDim = defaults.object(forKey: Key.pictureDim) as? Double ?? 0.35
        stageTone = StageTone(rawValue: defaults.string(forKey: Key.stageTone) ?? "") ?? .backdrop
        appearance = Appearance(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .dark
        reopenLastFolder = defaults.object(forKey: Key.reopenLastFolder) as? Bool ?? true
        rememberFlags = defaults.object(forKey: Key.rememberFlags) as? Bool ?? true
        preloadFullResolution = defaults.object(forKey: Key.preloadFull) as? Bool ?? true
        decodeRawWhenZooming = defaults.object(forKey: Key.decodeRaw) as? Bool ?? true
        advanceAfterFlag = defaults.object(forKey: Key.advanceAfterFlag) as? Bool ?? false
        zoomTarget = ZoomTarget(rawValue: defaults.string(forKey: Key.zoomTarget) ?? "") ?? .actualPixels
        preferredKind = FileKind(rawValue: defaults.string(forKey: Key.preferredKind) ?? "") ?? .jpg
        exportMode = ExportMode(rawValue: defaults.string(forKey: Key.exportMode) ?? "") ?? .copy
        lastExportFolderPath = defaults.string(forKey: Key.lastExportFolder)
        lastFolderPath = defaults.string(forKey: Key.lastFolder)
        recentFolderPaths = defaults.stringArray(forKey: Key.recentFolders) ?? []
    }

    /// Remember a folder for File ▸ Open Recent and for reopening at launch.
    func noteOpenedFolder(_ url: URL) {
        let path = url.standardizedFileURL.path
        lastFolderPath = path
        var paths = recentFolderPaths.filter { $0 != path }
        paths.insert(path, at: 0)
        recentFolderPaths = Array(paths.prefix(10))
    }

    func clearRecentFolders() {
        recentFolderPaths = []
    }

    /// Recent folders that still exist.
    var recentFolders: [URL] {
        recentFolderPaths
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private enum Key {
        static let layout = "browserLayout"
        static let viewerLayout = "viewerLayout"
        static let showsInspector = "showsInspector"
        static let showsInfoOverlay = "showsInfoOverlay"
        static let tileSize = "tileSize"
        static let backdrop = "backdrop"
        static let glassTint = "glassTint"
        static let backdropColor = "backdropColor"
        static let pictureDim = "pictureDim"
        static let stageTone = "stageTone"
        static let appearance = "appearance"
        static let reopenLastFolder = "reopenLastFolder"
        static let rememberFlags = "rememberFlags"
        static let preloadFull = "preloadFullResolution"
        static let decodeRaw = "decodeRawWhenZooming"
        static let advanceAfterFlag = "advanceAfterFlag"
        static let zoomTarget = "zoomTarget"
        static let preferredKind = "preferredKind"
        static let exportMode = "exportMode"
        static let lastExportFolder = "lastExportFolder"
        static let lastFolder = "lastFolder"
        static let recentFolders = "recentFolders"
    }
}

/// An sRGB colour parsed from `#RRGGBB`, independent of AppKit.
struct RGBColor: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        red = Double((value >> 16) & 0xFF) / 255
        green = Double((value >> 8) & 0xFF) / 255
        blue = Double(value & 0xFF) / 255
    }

    var hex: String {
        func component(_ value: Double) -> String {
            let byte = Int((min(max(value, 0), 1) * 255).rounded())
            let text = String(byte, radix: 16, uppercase: true)
            return byte < 16 ? "0" + text : text
        }
        return "#" + component(red) + component(green) + component(blue)
    }

    /// Relative luminance (Rec. 709 weights), used to pick legible text.
    var luminance: Double { 0.2126 * red + 0.7152 * green + 0.0722 * blue }
    var isLight: Bool { luminance > 0.6 }
}
