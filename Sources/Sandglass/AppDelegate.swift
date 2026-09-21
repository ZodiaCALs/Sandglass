import AppKit
import SwiftUI

/// Owns the app lifecycle and installs a local key monitor.
///
/// Keyboard culling is the core loop, so shortcuts are handled with a local
/// event monitor: it keeps working no matter which control holds focus, which
/// is far more reliable here than per-view focus state.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var keyMonitor: Any?

    /// Commands the key monitor forwards to the SwiftUI layer.
    enum Command {
        case next
        case previous
        case toggleKind
        case setKind(FileKind)
        case flagCurrent
        case flagBoth
        case flagOnly(FileKind)
        case openFolder
        case export
        case toggleMetadata
        case background
        case zoomIn
        case zoomOut
        case zoomReset
    }

    static let commandNotification = Notification.Name("Sandglass.command")

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        let window = makeWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installKeyMonitor()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: Window

    private func makeWindow() -> NSWindow {
        let root = RootView()
        let hosting = NSHostingController(rootView: root)

        let window = NSWindow(contentViewController: hosting)
        window.title = "Sandglass"
        window.setContentSize(NSSize(width: 1180, height: 800))
        window.minSize = NSSize(width: 900, height: 620)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.isMovableByWindowBackground = false
        // Always open at a known size; folder and position are remembered by the
        // app itself, so AppKit state restoration would only add surprises.
        window.isRestorable = false
        window.delegate = self
        window.center()
        return window
    }

    // MARK: Keyboard

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    /// Returns true when the event was consumed as a Sandglass command.
    private func handle(_ event: NSEvent) -> Bool {
        // Never steal keys while the user is typing in a text field.
        if let responder = window?.firstResponder,
           responder is NSTextView || responder is NSTextField {
            return false
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // ⌘-shortcuts mirror the menu items.
        if modifiers.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "o":
                send(.openFolder)
                return true
            case "e":
                send(.export)
                return true
            case "j":
                send(.setKind(.jpg))
                return true
            case "k":
                send(.setKind(.nef))
                return true
            case "f":
                send(.flagCurrent)
                return true
            case "+", "=":
                send(.zoomIn)
                return true
            case "-":
                send(.zoomOut)
                return true
            case "0":
                send(.zoomReset)
                return true
            case "m":
                send(.toggleMetadata)
                return true
            case "b":
                send(.background)
                return true
            default:
                return false
            }
        }

        // Plain keys: ignore anything with control/option held.
        guard !modifiers.contains(.control), !modifiers.contains(.option) else { return false }

        switch event.keyCode {
        case 123: send(.previous); return true          // ←
        case 124: send(.next); return true              // →
        case 125: send(.next); return true              // ↓
        case 126: send(.previous); return true          // ↑
        case 49: send(.next); return true               // space
        case 53: return false                           // esc handled by sheets
        default: break
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "j": send(.next); return true
        case "k": send(.previous); return true
        case "t": send(.toggleKind); return true
        case "i": send(.toggleKind); return true
        case "f": send(.flagCurrent); return true
        case "b": send(.flagBoth); return true
        case "1": send(.flagOnly(.jpg)); return true
        case "2": send(.flagOnly(.nef)); return true
        case "+", "=": send(.zoomIn); return true
        case "-": send(.zoomOut); return true
        case "0": send(.zoomReset); return true
        case "m": send(.toggleMetadata); return true
        default: return false
        }
    }

    private func send(_ command: Command) {
        NotificationCenter.default.post(name: Self.commandNotification, object: command)
    }

    // MARK: Menu

    private func installMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Sandglass", action: #selector(showAbout), keyEquivalent: "")
            .target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Sandglass", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Sandglass", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open Folder…", action: #selector(openFolder), keyEquivalent: "o").target = self
        fileMenu.addItem(withTitle: "Reload Folder", action: #selector(reloadFolder), keyEquivalent: "r").target = self
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Export Flagged…", action: #selector(exportFlagged), keyEquivalent: "e").target = self
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Clear All Flags", action: #selector(clearFlags), keyEquivalent: "").target = self
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Sandglass",
            .applicationVersion: "1.0",
            .credits: NSAttributedString(
                string: "Fast JPG / NEF culling.\n\n← →  move    T  switch format    F  flag    B  flag both",
                attributes: [.font: NSFont.systemFont(ofSize: 11)]
            )
        ])
    }

    @objc private func openFolder() { send(.openFolder) }
    @objc private func reloadFolder() {
        NotificationCenter.default.post(name: .sandglassReload, object: nil)
    }
    @objc private func exportFlagged() { send(.export) }
    @objc private func clearFlags() {
        NotificationCenter.default.post(name: .sandglassClearFlags, object: nil)
    }
}

extension Notification.Name {
    static let sandglassReload = Notification.Name("Sandglass.reload")
    static let sandglassClearFlags = Notification.Name("Sandglass.clearFlags")
    static let sandglassHelp = Notification.Name("Sandglass.help")
    static let sandglassOpenFolder = Notification.Name("Sandglass.openFolder")
}
