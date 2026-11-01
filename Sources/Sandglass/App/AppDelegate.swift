import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The application: menus, the main window, Settings, and folders opened from
/// Finder, the Dock or the command line.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let settings = AppSettings()
    private(set) var mainWindowController: MainWindowController?
    private var settingsWindow: NSWindow?
    private var settingsHost: NSHostingController<SettingsView>?
    private var shortcutsWindow: NSWindow?
    private let recentMenu = NSMenu(title: "Open Recent")
    private var pendingURLs: [URL] = []
    private var hasLaunched = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build(recentMenu: recentMenu, recentDelegate: self)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = MainWindowController(settings: settings)
        mainWindowController = controller
        controller.showWindow(nil)
        NSApp.activate()
        hasLaunched = true

        if let url = pendingURLs.first ?? Self.pathFromArguments() {
            controller.open(url)
        } else if settings.reopenLastFolder, let path = settings.lastFolderPath,
                  FileManager.default.fileExists(atPath: path) {
            controller.open(URL(fileURLWithPath: path, isDirectory: true))
        }
        pendingURLs = []
    }

    /// Folders and photos dropped on the Dock icon or opened with "Open With".
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if hasLaunched, let controller = mainWindowController {
            controller.open(url)
            controller.showWindow(nil)
        } else {
            pendingURLs = urls
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        mainWindowController?.library.saveSessionNow()
    }

    /// `Sandglass ~/Pictures/Shoot` opens that folder. Arguments that are not
    /// existing paths (Xcode's `-NS…` flags and their values) are ignored.
    static func pathFromArguments() -> URL? {
        for argument in CommandLine.arguments.dropFirst() where !argument.hasPrefix("-") {
            let path = (argument as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    // MARK: Menu actions

    @objc func performMenuCommand(_ sender: NSMenuItem) {
        mainWindowController?.performMenuCommand(sender)
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: makeSettingsView())
            let window = NSWindow(contentViewController: host)
            window.title = "Sandglass Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsHost = host
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showShortcuts(_ sender: Any?) {
        if shortcutsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: ShortcutsView()))
            window.title = "Keyboard Shortcuts"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            shortcutsWindow = window
        }
        shortcutsWindow?.makeKeyAndOrderFront(nil)
    }

    private func makeSettingsView() -> SettingsView {
        SettingsView(
            settings: settings,
            choosePicture: { [weak self] in self?.chooseBackdropPicture() },
            removePicture: { [weak self] in self?.removeBackdropPicture() },
            hasPicture: BackdropPicture.exists
        )
    }

    private func chooseBackdropPicture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Picture"
        panel.message = "Choose a picture for the window backdrop"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try BackdropPicture.importPicture(from: url)
            settings.backdrop = .picture
            mainWindowController?.backdropPictureChanged()
        } catch {
            _ = NSAlert(error: error).runModal()
        }
        settingsHost?.rootView = makeSettingsView()
    }

    private func removeBackdropPicture() {
        BackdropPicture.remove()
        if settings.backdrop == .picture { settings.backdrop = .glass }
        mainWindowController?.backdropPictureChanged()
        settingsHost?.rootView = makeSettingsView()
    }

    // MARK: Open Recent

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentMenu else { return }
        menu.removeAllItems()
        let folders = settings.recentFolders
        for url in folders {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecentFolder(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.toolTip = url.path
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
        if !folders.isEmpty {
            menu.addItem(.separator())
        }
        let clear = NSMenuItem(title: "Clear Menu", action: #selector(clearRecentFolders(_:)), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = !folders.isEmpty
        menu.addItem(clear)
    }

    @objc private func openRecentFolder(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        mainWindowController?.open(url)
    }

    @objc private func clearRecentFolders(_ sender: Any?) {
        settings.clearRecentFolders()
    }
}

/// The menu bar. Every command is listed with its shortcut — including the
/// single-key ones, which are shown for discoverability and handled by
/// `KeyRouter` (their menu items only act while the main window has focus).
@MainActor
enum MainMenu {

    static func build(recentMenu: NSMenu, recentDelegate: NSMenuDelegate) -> NSMenu {
        let main = NSMenu()
        main.addItem(container(appMenu()))
        main.addItem(container(fileMenu(recentMenu: recentMenu, recentDelegate: recentDelegate)))
        main.addItem(container(editMenu()))
        main.addItem(container(photoMenu()))
        main.addItem(container(viewMenu()))
        let window = windowMenu()
        main.addItem(container(window))
        NSApp.windowsMenu = window
        let help = helpMenu()
        main.addItem(container(help))
        NSApp.helpMenu = help
        return main
    }

    // MARK: Menus

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "Sandglass")
        menu.addItem(withTitle: "About Sandglass", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        menu.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        menu.addItem(services)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide Sandglass", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = menu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Sandglass", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private static func fileMenu(recentMenu: NSMenu, recentDelegate: NSMenuDelegate) -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(item("Open Folder…", .openFolder, key: "o", symbol: "folder"))
        let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recentMenu.delegate = recentDelegate
        recentMenu.autoenablesItems = false
        recent.submenu = recentMenu
        menu.addItem(recent)
        menu.addItem(.separator())
        menu.addItem(item("Reload Folder", .reloadFolder, key: "r", symbol: "arrow.clockwise"))
        menu.addItem(item("Show in Finder", .revealInFinder, key: "r", modifiers: [.command, .shift], symbol: "folder"))
        menu.addItem(item("Open in Default App", .openInDefaultApp, key: "o", modifiers: [.command, .shift], symbol: "arrow.up.forward.app"))
        menu.addItem(.separator())
        menu.addItem(item("Export Flagged…", .exportFlagged, key: "e", symbol: "square.and.arrow.up.on.square"))
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: #selector(MainWindowController.undo(_:)), keyEquivalent: "z")
        let redo = menu.addItem(withTitle: "Redo", action: #selector(MainWindowController.redo(_:)), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(.separator())
        menu.addItem(item("Clear Flags", .clearFlags, key: "x", modifiers: [], symbol: "flag.slash"))
        menu.addItem(item("Clear All Flags", .clearAllFlags, key: "\u{8}", modifiers: [.command, .shift]))
        return menu
    }

    private static func photoMenu() -> NSMenu {
        let menu = NSMenu(title: "Photo")
        menu.addItem(item("Next Photo", .next, key: functionKey(NSRightArrowFunctionKey), modifiers: [], symbol: "chevron.right"))
        menu.addItem(item("Previous Photo", .previous, key: functionKey(NSLeftArrowFunctionKey), modifiers: [], symbol: "chevron.left"))
        menu.addItem(item("First Photo", .first, key: functionKey(NSHomeFunctionKey), modifiers: []))
        menu.addItem(item("Last Photo", .last, key: functionKey(NSEndFunctionKey), modifiers: []))
        menu.addItem(.separator())
        menu.addItem(item("Switch JPG / NEF", .toggleKind, key: "t", modifiers: [], symbol: "arrow.left.arrow.right"))
        menu.addItem(item("Show JPG", .showKind(.jpg), key: "j"))
        menu.addItem(item("Show NEF", .showKind(.nef), key: "k"))
        menu.addItem(.separator())
        menu.addItem(item("Flag Variant on Screen", .flagCurrent, key: "f", modifiers: [], symbol: "flag"))
        menu.addItem(item("Flag Both", .flagBoth, key: "b", modifiers: [], symbol: "flag.2.crossed"))
        menu.addItem(item("Keep Only the JPG", .flagOnly(.jpg), key: "1", modifiers: []))
        menu.addItem(item("Keep Only the NEF", .flagOnly(.nef), key: "2", modifiers: []))
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        for layout in BrowserLayout.allCases {
            menu.addItem(item(layout.title, .setLayout(layout), key: layout.menuKey, symbol: layout.systemImage))
        }
        menu.addItem(.separator())
        menu.addItem(item("Grid", .toggleGrid, key: "g", modifiers: [], symbol: "square.grid.3x3"))
        menu.addItem(item("Compare JPG & NEF", .toggleCompare, key: "c", modifiers: [], symbol: "rectangle.split.2x1"))
        menu.addItem(item("Hide Thumbnails", .toggleThumbnails, key: "\t", modifiers: []))
        menu.addItem(item("Show Inspector", .toggleInspector, key: "i", modifiers: [.command, .option], symbol: "info.circle"))
        menu.addItem(item("Show Photo Info", .toggleInfoOverlay, key: "h", modifiers: []))
        menu.addItem(.separator())
        menu.addItem(item("Zoom In", .zoomIn, key: "+", symbol: "plus.magnifyingglass"))
        // ⌘= zooms in too, the way most Mac apps allow; it stays out of sight.
        let zoomInAlias = item("Zoom In", .zoomIn, key: "=")
        zoomInAlias.isHidden = true
        zoomInAlias.allowsKeyEquivalentWhenHidden = true
        menu.addItem(zoomInAlias)
        menu.addItem(item("Zoom Out", .zoomOut, key: "-", symbol: "minus.magnifyingglass"))
        menu.addItem(item("Zoom to Fit", .zoomToFit, key: "0"))
        menu.addItem(item("Actual Size", .zoomToActualSize, key: "0", modifiers: [.command, .option]))
        menu.addItem(.separator())
        let fullScreen = NSMenuItem(title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        menu.addItem(fullScreen)
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        return menu
    }

    private static func helpMenu() -> NSMenu {
        let menu = NSMenu(title: "Help")
        let shortcuts = menu.addItem(withTitle: "Keyboard Shortcuts", action: #selector(AppDelegate.showShortcuts(_:)), keyEquivalent: "/")
        shortcuts.image = NSImage.symbol("keyboard")
        return menu
    }

    // MARK: Helpers

    private static func container(_ submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private static func item(
        _ title: String,
        _ command: Command,
        key: String = "",
        modifiers: NSEvent.ModifierFlags = [.command],
        symbol: String? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(MainWindowController.performMenuCommand(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.representedObject = CommandBox(command)
        if let symbol {
            item.image = NSImage.symbol(symbol)
        }
        return item
    }

    private static func functionKey(_ code: Int) -> String {
        guard let scalar = Unicode.Scalar(UInt32(code)) else { return "" }
        return String(Character(scalar))
    }
}
