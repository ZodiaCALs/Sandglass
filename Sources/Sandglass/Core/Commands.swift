import Foundation

/// Where the thumbnails go relative to the photo.
enum BrowserLayout: String, CaseIterable, Codable, Sendable, Identifiable {
    /// A strip of thumbnails under the photo — the classic culling layout.
    case filmstrip
    /// A sidebar of thumbnails to the left of the photo.
    case sidebarLeft
    /// A column of thumbnails to the right of the photo.
    case sidebarRight
    /// A contact sheet filling the window; open a photo to inspect it.
    case grid
    /// Just the photo.
    case photoOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .filmstrip: "Filmstrip"
        case .sidebarLeft: "Sidebar on Left"
        case .sidebarRight: "Sidebar on Right"
        case .grid: "Grid"
        case .photoOnly: "Photo Only"
        }
    }

    var shortTitle: String {
        switch self {
        case .filmstrip: "Filmstrip"
        case .sidebarLeft: "Left"
        case .sidebarRight: "Right"
        case .grid: "Grid"
        case .photoOnly: "Photo"
        }
    }

    var systemImage: String {
        switch self {
        case .filmstrip: "rectangle.bottomthird.inset.filled"
        case .sidebarLeft: "sidebar.left"
        case .sidebarRight: "sidebar.right"
        case .grid: "square.grid.3x3"
        case .photoOnly: "rectangle"
        }
    }

    /// The digit used with ⌘ to choose this layout.
    var menuKey: String {
        switch self {
        case .filmstrip: "1"
        case .sidebarLeft: "2"
        case .sidebarRight: "3"
        case .grid: "4"
        case .photoOnly: "5"
        }
    }

    var showsViewer: Bool { self != .grid }
    var showsThumbnails: Bool { self != .photoOnly }
}

/// Everything the user can ask Sandglass to do, from the keyboard, a menu, the
/// toolbar or a button. One enum keeps all of those routes in agreement.
enum Command: Hashable, Sendable {
    // Moving through the folder
    case next
    case previous
    case first
    case last
    case rowUp
    case rowDown

    // Variants
    case toggleKind
    case showKind(FileKind)

    // Flags
    case flagCurrent
    /// Flag or unflag one variant of the photo on screen.
    case toggleFlag(FileKind)
    case flagBoth
    case flagOnly(FileKind)
    case clearFlags
    case clearAllFlags

    // Zoom
    case zoomIn
    case zoomOut
    case zoomToFit
    case zoomToActualSize
    case toggleZoom

    // Layout
    case setLayout(BrowserLayout)
    case toggleGrid
    case toggleCompare
    case toggleInspector
    case toggleThumbnails
    case toggleInfoOverlay
    case openSelection
    case escape

    // Files
    case openFolder
    case reloadFolder
    case exportFlagged
    case revealInFinder
    case openInDefaultApp

    case showShortcuts
}

/// A key press, reduced to what the key map needs.
struct KeyPress: Hashable, Sendable {
    /// Hardware key code (arrows, space, return… are matched by code).
    var keyCode: UInt16
    /// `charactersIgnoringModifiers`, lower-cased. Shift is still applied, so
    /// Shift-= arrives as "+".
    var characters: String
    var modifiers: InputModifiers

    init(keyCode: UInt16, characters: String, modifiers: InputModifiers = []) {
        self.keyCode = keyCode
        self.characters = characters.lowercased()
        self.modifiers = modifiers
    }
}

/// Single-key shortcuts — the culling loop is driven from the keyboard.
///
/// Shortcuts with ⌘ belong to the menus; this map handles keys pressed without
/// ⌘, ⌃ or ⌥.
enum KeyMap {

    enum KeyCode {
        static let returnKey: UInt16 = 36
        static let tab: UInt16 = 48
        static let space: UInt16 = 49
        static let delete: UInt16 = 51
        static let escape: UInt16 = 53
        static let keypadEnter: UInt16 = 76
        static let home: UInt16 = 115
        static let pageUp: UInt16 = 116
        static let forwardDelete: UInt16 = 117
        static let end: UInt16 = 119
        static let pageDown: UInt16 = 121
        static let left: UInt16 = 123
        static let right: UInt16 = 124
        static let down: UInt16 = 125
        static let up: UInt16 = 126
    }

    static func command(for key: KeyPress, layout: BrowserLayout) -> Command? {
        guard key.modifiers.intersection([.command, .control, .option]).isEmpty else { return nil }
        let shift = key.modifiers.contains(.shift)
        let inGrid = layout == .grid

        switch key.keyCode {
        case KeyCode.right: return .next
        case KeyCode.left: return .previous
        case KeyCode.down: return inGrid ? .rowDown : .next
        case KeyCode.up: return inGrid ? .rowUp : .previous
        case KeyCode.space: return shift ? .previous : .next
        case KeyCode.home: return .first
        case KeyCode.end: return .last
        case KeyCode.pageDown: return inGrid ? .rowDown : .next
        case KeyCode.pageUp: return inGrid ? .rowUp : .previous
        case KeyCode.returnKey, KeyCode.keypadEnter: return inGrid ? .openSelection : nil
        case KeyCode.escape: return .escape
        case KeyCode.tab: return shift ? nil : .toggleThumbnails
        case KeyCode.delete, KeyCode.forwardDelete: return .clearFlags
        default: break
        }

        switch key.characters {
        case "j": return .next
        case "k": return .previous
        case "t": return .toggleKind
        case "f": return .flagCurrent
        case "b": return .flagBoth
        case "1": return .flagOnly(.jpg)
        case "2": return .flagOnly(.nef)
        case "x", "u": return .clearFlags
        case "+", "=": return .zoomIn
        case "-", "_": return .zoomOut
        case "0": return .zoomToFit
        case "z": return .toggleZoom
        case "g": return .toggleGrid
        case "c": return .toggleCompare
        case "i", "m": return .toggleInspector
        case "h": return .toggleInfoOverlay
        case "?", "/": return .showShortcuts
        default: return nil
        }
    }

    /// The keyboard reference shown in the app, grouped by task.
    static let reference: [ShortcutGroup] = [
        ShortcutGroup(title: "Move", rows: [
            ShortcutRow("← →   J K   Space", "Previous / next photo"),
            ShortcutRow("↑ ↓", "Previous / next (rows in Grid)"),
            ShortcutRow("Home  End", "First / last photo"),
            ShortcutRow("G", "Grid ↔ previous layout"),
            ShortcutRow("Return", "Open the selected photo (Grid)")
        ]),
        ShortcutGroup(title: "Choose", rows: [
            ShortcutRow("T", "Switch between JPG and NEF"),
            ShortcutRow("F", "Flag the variant on screen"),
            ShortcutRow("B", "Flag both JPG and NEF"),
            ShortcutRow("1  2", "Keep only the JPG / only the NEF"),
            ShortcutRow("X  ⌫", "Clear this photo’s flags"),
            ShortcutRow("⌘Z", "Undo a flag change")
        ]),
        ShortcutGroup(title: "Look", rows: [
            ShortcutRow("Scroll wheel", "Zoom about the pointer"),
            ShortcutRow("Pinch  ⌘-scroll", "Zoom on a trackpad"),
            ShortcutRow("Drag  two-finger scroll", "Pan when zoomed in"),
            ShortcutRow("Double-click  Z", "Fit ↔ 100%"),
            ShortcutRow("+  −  0", "Zoom in / out / fit"),
            ShortcutRow("C", "Compare JPG and NEF side by side"),
            ShortcutRow("H", "Show or hide the photo info overlay")
        ]),
        ShortcutGroup(title: "Window", rows: [
            ShortcutRow("⌘1 … ⌘5", "Filmstrip · Left · Right · Grid · Photo only"),
            ShortcutRow("Tab", "Show or hide thumbnails"),
            ShortcutRow("I", "Show or hide the inspector"),
            ShortcutRow("⌘O  ⌘R", "Open folder / reload"),
            ShortcutRow("⌘E", "Export flagged photos"),
            ShortcutRow("⌃⌘F", "Full screen")
        ])
    ]
}

/// One line of the keyboard reference.
struct ShortcutRow: Hashable, Sendable {
    let keys: String
    let action: String

    init(_ keys: String, _ action: String) {
        self.keys = keys
        self.action = action
    }
}

/// A titled group of the keyboard reference.
struct ShortcutGroup: Hashable, Sendable, Identifiable {
    let title: String
    let rows: [ShortcutRow]

    var id: String { title }
}
