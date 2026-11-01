import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension NSToolbarItem.Identifier {
    static let openFolder = NSToolbarItem.Identifier("Sandglass.openFolder")
    static let layout = NSToolbarItem.Identifier("Sandglass.layout")
    static let compare = NSToolbarItem.Identifier("Sandglass.compare")
    static let inspector = NSToolbarItem.Identifier("Sandglass.inspector")
    static let export = NSToolbarItem.Identifier("Sandglass.export")
}

/// The main window: owns the culling session and the image stores, builds the
/// interface, and turns every command — from the keyboard, a menu, the toolbar
/// or a button — into a change of state.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation {

    let settings: AppSettings
    let library: Library
    let thumbnails: ThumbnailStore
    let previews: PreviewStore
    let metadata: MetadataStore
    let viewerModel: ViewerModel

    private let viewer: ViewerViewController
    private let browser: BrowserViewController
    private let stage: StageViewController
    private let split: MainSplitViewController
    private let root: RootViewController
    private let inspectorHost: NSHostingController<InspectorView>

    private let keyRouter = KeyRouter()
    private let memoryMonitor = MemoryPressureMonitor()
    private var observers: [ObservationLoop] = []
    private var appliedLayout: BrowserLayout?
    private var appliedInspector: Bool?
    private var appliedPreferredKind: FileKind?
    /// The last layout that showed thumbnails next to the photo, for Tab.
    private var thumbnailLayout: BrowserLayout = .filmstrip
    /// +1 when moving forward through the folder, −1 backward, for prefetching.
    private var direction = 1
    private var backdropImage: CGImage?
    private var backdropImageLoaded = false
    private var exportSheet: NSViewController?
    private var exportModel: ExportModel?

    private weak var layoutItem: NSToolbarItemGroup?
    private weak var compareItem: NSToolbarItemGroup?
    private weak var inspectorItem: NSToolbarItemGroup?
    private weak var exportItem: NSToolbarItem?

    init(settings: AppSettings) {
        let store = settings.rememberFlags ? SessionStore(directory: SessionStore.defaultDirectory) : nil
        let library = Library(sessionStore: store)
        let thumbnails = ThumbnailStore()
        let previews = PreviewStore()
        let metadata = MetadataStore()
        let viewerModel = ViewerModel()
        let viewer = ViewerViewController(library: library, previews: previews, metadata: metadata, settings: settings, model: viewerModel)
        let browser = BrowserViewController(library: library, thumbnails: thumbnails, settings: settings)
        let stage = StageViewController(viewer: viewer)
        let inspectorHost = NSHostingController(rootView: InspectorView(library: library, metadata: metadata, perform: { _ in }))
        let split = MainSplitViewController(stage: stage, inspector: inspectorHost)
        let root = RootViewController(split: split)

        self.settings = settings
        self.library = library
        self.thumbnails = thumbnails
        self.previews = previews
        self.metadata = metadata
        self.viewerModel = viewerModel
        self.viewer = viewer
        self.browser = browser
        self.stage = stage
        self.split = split
        self.root = root
        self.inspectorHost = inspectorHost

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1320, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        inspectorHost.sizingOptions = []
        inspectorHost.rootView = InspectorView(library: library, metadata: metadata) { [weak self] command in
            _ = self?.perform(command)
        }
        configure(window)
        wireUp(window)
        startObserving()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    // MARK: Setup

    private func configure(_ window: NSWindow) {
        window.contentViewController = root
        window.title = "Sandglass"
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 860, height: 560)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.delegate = self

        let toolbar = NSToolbar(identifier: "SandglassMainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar

        window.setContentSize(NSSize(width: 1320, height: 860))
        window.center()
        window.setFrameAutosaveName("SandglassMainWindow")
    }

    private func wireUp(_ window: NSWindow) {
        viewer.perform = { [weak self] command in _ = self?.perform(command) }
        browser.onOpen = { [weak self] index in self?.openFromBrowser(index) }
        browser.onAction = { [weak self] action, index in self?.handle(action, at: index) }
        root.onDrop = { [weak self] urls in self?.openDropped(urls) ?? false }

        keyRouter.window = window
        keyRouter.layout = { [weak self] in self?.settings.layout ?? .filmstrip }
        keyRouter.handler = { [weak self] command in self?.perform(command) ?? false }
        keyRouter.install()

        memoryMonitor.start { [weak self] in
            self?.previews.purge(keepingVisible: true)
            self?.thumbnails.trim(keeping: 0.25)
            self?.metadata.removeAll()
        }
    }

    private func startObserving() {
        observers = [
            ObservationLoop { [weak self] in self?.updateChrome() },
            ObservationLoop { [weak self] in self?.drivePreviews() },
            ObservationLoop { [weak self] in self?.applyLayout() },
            ObservationLoop { [weak self] in self?.applyAppearance() },
            ObservationLoop { [weak self] in self?.applyBehaviour() },
            ObservationLoop { [weak self] in self?.loadInspectorMetadata() }
        ]
    }

    // MARK: Following state

    private func updateChrome() {
        guard let window else { return }
        if let folder = library.folder {
            window.title = folder.lastPathComponent
            window.representedURL = folder
            var parts = ["\(library.position) of \(library.count)"]
            let flagged = library.flaggedShotCount
            if flagged > 0 {
                let files = library.flaggedFileCount
                parts.append("\(flagged) flagged (\(files) file\(files == 1 ? "" : "s"))")
            }
            parts.append("\(Int((library.reviewedFraction * 100).rounded()))% seen")
            window.subtitle = parts.joined(separator: " · ")
            root.showWelcome(nil)
        } else {
            window.title = "Sandglass"
            window.subtitle = ""
            window.representedURL = nil
            root.showWelcome(WelcomeView(
                recentFolders: settings.recentFolders,
                openFolder: { [weak self] in self?.chooseFolder() },
                openRecent: { [weak self] url in self?.open(url) }
            ))
        }
        if case .scanning(let url) = library.phase {
            root.showScanning(folderName: url.lastPathComponent)
        } else {
            root.showScanning(folderName: nil)
        }
        exportItem?.isEnabled = library.flaggedShotCount > 0
        let canCompare = library.currentShot?.isPaired == true || viewerModel.isComparing
        compareItem?.isEnabled = canCompare
        compareItem?.setSelected(viewerModel.isComparing, at: 0)
    }

    private func drivePreviews() {
        _ = library.generation
        previews.preloadFullResolution = settings.preloadFullResolution
        previews.decodeRawWhenZooming = settings.decodeRawWhenZooming
        guard settings.layout.showsViewer, let shot = library.currentShot else {
            previews.show(nil, kind: library.kind, compare: false, next: [])
            return
        }
        previews.show(
            shot,
            kind: library.kind,
            compare: viewerModel.isComparing && shot.isPaired,
            next: upcomingURLs()
        )
    }

    /// What is likely to be shown next: the other variant (T is instant) and the
    /// neighbours, mostly in the direction of travel.
    private func upcomingURLs() -> [URL] {
        var urls: [URL] = []
        if let other = library.currentShot?.url(for: library.kind.other) {
            urls.append(other)
        }
        let shots = library.shots
        let offsets = direction >= 0 ? [1, 2, -1, 3] : [-1, -2, 1, -3]
        for offset in offsets {
            let index = library.index + offset
            guard shots.indices.contains(index) else { continue }
            let shot = shots[index]
            if let url = shot.url(for: shot.kind(preferring: library.preferredKind)) {
                urls.append(url)
            }
        }
        return urls
    }

    private func applyLayout() {
        let layout = settings.layout
        let inspector = settings.showsInspector
        stage.filmstripHeight = CGFloat(min(max(settings.tileSize * 0.7 + 30, 96), 176))

        if appliedLayout != layout {
            let animated = appliedLayout != nil && window?.isVisible == true
            appliedLayout = layout
            if layout != .grid { settings.viewerLayout = layout }
            if layout == .filmstrip || layout == .sidebarLeft || layout == .sidebarRight {
                thumbnailLayout = layout
            }
            rehostBrowser(for: layout)
            stage.layoutMode = layout
            split.setPanels(leading: layout == .sidebarLeft, trailing: layout == .sidebarRight, inspector: inspector, animated: animated)
            if layout == .grid {
                browser.focus()
            } else {
                _ = window?.makeFirstResponder(viewer.primaryCanvas)
            }
        } else if appliedInspector != inspector {
            split.setPanels(leading: layout == .sidebarLeft, trailing: layout == .sidebarRight, inspector: inspector, animated: true)
        }
        appliedInspector = inspector
        layoutItem?.selectedIndex = BrowserLayout.allCases.firstIndex(of: layout) ?? 0
        inspectorItem?.setSelected(inspector, at: 0)
    }

    private func rehostBrowser(for layout: BrowserLayout) {
        split.leadingHost.host(nil)
        split.trailingHost.host(nil)
        stage.filmstrip.host(nil)
        stage.grid.host(nil)
        switch layout {
        case .filmstrip:
            stage.filmstrip.host(browser)
            browser.setPlacement(.filmstrip)
        case .sidebarLeft:
            split.leadingHost.host(browser)
            browser.setPlacement(.sidebar)
        case .sidebarRight:
            split.trailingHost.host(browser)
            browser.setPlacement(.sidebar)
        case .grid:
            stage.grid.host(browser)
            browser.setPlacement(.grid)
        case .photoOnly:
            break
        }
    }

    private func applyAppearance() {
        let appearance: NSAppearance? = switch settings.appearance {
        case .dark: NSAppearance(named: .darkAqua)
        case .light: NSAppearance(named: .aqua)
        case .system: nil
        }
        NSApp.appearance = appearance
        let colour = RGBColor(hex: settings.backdropColorHex) ?? RGBColor(red: 0.08, green: 0.1, blue: 0.18)
        if settings.backdrop == .picture, !backdropImageLoaded {
            backdropImage = BackdropPicture.load()
            backdropImageLoaded = true
        }
        root.backdrop.apply(
            style: settings.backdrop,
            tint: settings.glassTint,
            color: colour,
            picture: settings.backdrop == .picture ? backdropImage : nil,
            dim: settings.pictureDim
        )
    }

    /// A new backdrop picture was chosen or removed.
    func backdropPictureChanged() {
        backdropImage = BackdropPicture.load()
        backdropImageLoaded = true
        applyAppearance()
    }

    private func applyBehaviour() {
        if settings.rememberFlags {
            if library.sessionStore == nil {
                library.sessionStore = SessionStore(directory: SessionStore.defaultDirectory)
            }
        } else {
            library.sessionStore = nil
        }
        let preferred = settings.preferredKind
        if appliedPreferredKind != preferred {
            appliedPreferredKind = preferred
            library.setPreferredKind(preferred)
        }
    }

    private func loadInspectorMetadata() {
        guard settings.showsInspector, let url = library.currentURL else { return }
        metadata.load(url)
    }

    // MARK: Commands

    /// Carry out a command. Returns false when it does not apply right now, so
    /// the key that asked for it can be handled elsewhere.
    @discardableResult
    func perform(_ command: Command) -> Bool {
        let hasShot = library.currentShot != nil
        switch command {
        case .next:
            direction = 1
            library.next()
        case .previous:
            direction = -1
            library.previous()
        case .first:
            direction = 1
            library.first()
        case .last:
            direction = -1
            library.last()
        case .rowDown:
            direction = 1
            library.move(by: browser.columnsPerRow)
        case .rowUp:
            direction = -1
            library.move(by: -browser.columnsPerRow)

        case .toggleKind:
            guard let shot = library.currentShot else { return false }
            if !library.toggleKind() {
                viewerModel.show("Only the \(shot.availableKinds.first?.label ?? "one file") exists for this photo", symbol: "info.circle")
            }
        case .showKind(let kind):
            guard hasShot else { return false }
            if !library.setKind(kind) {
                viewerModel.show("No \(kind.label) for this photo", symbol: "exclamationmark.triangle")
            }

        case .flagCurrent:
            handleFlag(library.toggleFlag(), advances: true)
        case .toggleFlag(let kind):
            handleFlag(library.toggleFlag(kind), advances: false)
        case .flagBoth:
            handleFlag(library.toggleFlagBoth(), advances: true)
        case .flagOnly(let kind):
            handleFlag(library.flagOnly(kind), advances: true)
        case .clearFlags:
            handleFlag(library.clearFlags(), advances: false)
        case .clearAllFlags:
            clearAllFlags()

        case .zoomIn, .zoomOut, .zoomToFit, .zoomToActualSize, .toggleZoom:
            guard settings.layout.showsViewer, hasShot else { return false }
            switch command {
            case .zoomIn: viewer.zoomIn()
            case .zoomOut: viewer.zoomOut()
            case .zoomToFit: viewer.zoomToFit()
            case .zoomToActualSize: viewer.zoomToActualSize()
            default: viewer.toggleZoom()
            }

        case .setLayout(let layout):
            settings.layout = layout
        case .toggleGrid:
            guard library.folder != nil else { return false }
            settings.layout = settings.layout == .grid ? settings.viewerLayout : .grid
        case .openSelection:
            guard settings.layout == .grid else { return false }
            settings.layout = settings.viewerLayout
        case .toggleThumbnails:
            switch settings.layout {
            case .grid: return false
            case .photoOnly: settings.layout = thumbnailLayout
            default: settings.layout = .photoOnly
            }
        case .toggleCompare:
            guard viewerModel.isComparing || library.currentShot?.isPaired == true else {
                viewerModel.show("Compare needs both a JPG and a NEF", symbol: "rectangle.split.2x1")
                return true
            }
            viewerModel.isComparing.toggle()
            if viewerModel.isComparing, settings.layout == .grid {
                settings.layout = settings.viewerLayout
            }
        case .toggleInspector:
            settings.showsInspector.toggle()
        case .toggleInfoOverlay:
            settings.showsInfoOverlay.toggle()
        case .escape:
            if viewerModel.isComparing {
                viewerModel.isComparing = false
            } else if settings.layout == .grid {
                settings.layout = settings.viewerLayout
            } else if viewer.isZoomedIn {
                viewer.zoomToFit()
            } else {
                return false
            }

        case .openFolder:
            chooseFolder()
        case .reloadFolder:
            guard library.folder != nil else { return false }
            reload()
        case .exportFlagged:
            beginExport()
        case .revealInFinder:
            guard let url = library.currentURL else { return false }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .openInDefaultApp:
            guard let url = library.currentURL else { return false }
            _ = NSWorkspace.shared.open(url)
        case .showShortcuts:
            (NSApp.delegate as? AppDelegate)?.showShortcuts(nil)
        }
        return true
    }

    private func handleFlag(_ outcome: FlagOutcome, advances: Bool) {
        if case .changed(let id, let before, let after) = outcome, before != after {
            registerUndo(shotID: id, restoring: before)
            if advances, settings.advanceAfterFlag, outcome.addedFlag, !library.isAtEnd {
                direction = 1
                library.next()
            }
        }
        if let message = outcome.message {
            viewerModel.show(message.text, symbol: message.symbol)
        }
    }

    private func registerUndo(shotID: Shot.ID, restoring selection: FlagSelection) {
        guard let undoManager = window?.undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                let current = target.library.flags[shotID] ?? []
                target.library.setSelection(selection, forShotID: shotID)
                target.registerUndo(shotID: shotID, restoring: current)
                if let index = target.library.index(of: shotID) {
                    target.library.go(to: index)
                }
            }
        }
        undoManager.setActionName("Flag")
    }

    private func clearAllFlags() {
        let saved = library.clearAllFlags()
        guard !saved.isEmpty else { return }
        if let undoManager = window?.undoManager {
            undoManager.registerUndo(withTarget: self) { target in
                MainActor.assumeIsolated {
                    target.library.restoreFlags(saved)
                }
            }
            undoManager.setActionName("Clear All Flags")
        }
        viewerModel.show("All flags cleared · ⌘Z to undo", symbol: "flag.slash")
    }

    private func handle(_ action: BrowserAction, at index: Int) {
        switch action {
        case .show:
            openFromBrowser(index)
        case .toggleFlag(let kind):
            handleFlag(library.toggleFlag(kind, at: index), advances: false)
        case .flagBoth:
            handleFlag(library.toggleFlagBoth(at: index), advances: false)
        case .clearFlags:
            handleFlag(library.clearFlags(at: index), advances: false)
        case .revealInFinder:
            if let url = url(at: index) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        case .openInDefaultApp:
            if let url = url(at: index) { _ = NSWorkspace.shared.open(url) }
        }
    }

    private func url(at index: Int) -> URL? {
        guard library.shots.indices.contains(index) else { return nil }
        let shot = library.shots[index]
        return shot.url(for: index == library.index ? library.kind : shot.kind(preferring: library.preferredKind))
    }

    private func openFromBrowser(_ index: Int) {
        library.go(to: index)
        if settings.layout == .grid {
            settings.layout = settings.viewerLayout
        }
    }

    // MARK: Folders

    func chooseFolder() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a folder of JPG and NEF photos"
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                self?.open(url)
            }
        }
    }

    /// Open a folder — or a photo, which opens its folder with that photo selected.
    func open(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            presentProblem("“\(url.lastPathComponent)” could not be found.")
            return
        }
        let folder = isDirectory.boolValue ? url : url.deletingLastPathComponent()
        let selecting = isDirectory.boolValue ? nil : url
        let isSameFolder = library.folder?.standardizedFileURL == folder.standardizedFileURL
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.library.open(folder: folder, selecting: selecting)
                if !isSameFolder {
                    self.previews.reset()
                    self.thumbnails.removeAll()
                    self.metadata.removeAll()
                }
                self.settings.noteOpenedFolder(folder)
                self.viewerModel.isComparing = false
            } catch is CancellationError {
            } catch {
                self.presentProblem(error.localizedDescription)
            }
        }
    }

    private func reload() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.library.reload()
                // Files may have been edited in place, so start the caches afresh.
                self.previews.reset()
                self.thumbnails.removeAll()
                self.metadata.removeAll()
            } catch is CancellationError {
            } catch {
                self.presentProblem(error.localizedDescription)
            }
        }
    }

    private func openDropped(_ urls: [URL]) -> Bool {
        guard let url = urls.first else { return false }
        open(url)
        return true
    }

    private func presentProblem(_ text: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Couldn’t open the folder"
        alert.informativeText = text
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window)
    }

    // MARK: Export

    private func beginExport() {
        guard exportSheet == nil else { return }
        let plan = library.exportPlan()
        guard !plan.isEmpty else {
            viewerModel.show("Flag some photos first", symbol: "flag")
            return
        }
        let entries: [ExportEntry] = library.shots.compactMap { shot in
            let selection = library.selection(for: shot)
            guard !selection.isEmpty else { return nil }
            return ExportEntry(id: shot.id, name: shot.displayName, available: shot.availableKinds, flagged: selection)
        }
        let model = ExportModel(plan: plan, entries: entries, mode: settings.exportMode)
        let fileCount = plan.files.count
        let sheet = ExportSheetView(
            model: model,
            chooseDestination: { [weak self] in self?.chooseExportDestination(fileCount: fileCount) },
            reveal: { url in NSWorkspace.shared.activateFileViewerSelecting([url]) },
            close: { [weak self] in self?.endExport() }
        )
        let controller = NSHostingController(rootView: sheet)
        exportModel = model
        exportSheet = controller
        root.presentAsSheet(controller)
    }

    private func endExport() {
        if let model = exportModel {
            model.cancel()
            settings.exportMode = model.mode
            if model.didMoveFiles { reload() }
        }
        if let sheet = exportSheet {
            root.dismiss(sheet)
        }
        exportSheet = nil
        exportModel = nil
    }

    private func chooseExportDestination(fileCount: Int) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export Here"
        panel.message = "Choose where to save \(fileCount) flagged file\(fileCount == 1 ? "" : "s")"
        if let path = settings.lastExportFolderPath {
            panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        settings.lastExportFolderPath = url.path
        return url
    }

    // MARK: Menus

    @objc func performMenuCommand(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? CommandBox else { return }
        _ = perform(box.command)
    }

    @objc func undo(_ sender: Any?) {
        window?.undoManager?.undo()
    }

    @objc func redo(_ sender: Any?) {
        window?.undoManager?.redo()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(undo(_:)) {
            menuItem.title = window?.undoManager?.undoMenuItemTitle ?? "Undo"
            return window?.undoManager?.canUndo ?? false
        }
        if menuItem.action == #selector(redo(_:)) {
            menuItem.title = window?.undoManager?.redoMenuItemTitle ?? "Redo"
            return window?.undoManager?.canRedo ?? false
        }
        guard let command = (menuItem.representedObject as? CommandBox)?.command else { return true }

        // Single-key shortcuts are shown in the menus but only act on this window,
        // and never while text is being typed somewhere.
        let usesPlainKey = !menuItem.keyEquivalent.isEmpty
            && menuItem.keyEquivalentModifierMask.intersection([.command, .control, .option]).isEmpty
        if usesPlainKey {
            guard let window, window.isKeyWindow, window.attachedSheet == nil,
                  !(window.firstResponder is NSText) else { return false }
        }
        return validate(command, menuItem)
    }

    private func validate(_ command: Command, _ item: NSMenuItem) -> Bool {
        let shot = library.currentShot
        switch command {
        case .openFolder, .showShortcuts:
            return true
        case .setLayout(let layout):
            item.state = settings.layout == layout ? .on : .off
            return true
        case .toggleGrid:
            item.state = settings.layout == .grid ? .on : .off
            return library.folder != nil
        case .toggleCompare:
            item.state = viewerModel.isComparing ? .on : .off
            return viewerModel.isComparing || shot?.isPaired == true
        case .toggleInspector:
            item.title = settings.showsInspector ? "Hide Inspector" : "Show Inspector"
            return true
        case .toggleThumbnails:
            item.title = settings.layout == .photoOnly ? "Show Thumbnails" : "Hide Thumbnails"
            return settings.layout != .grid
        case .toggleInfoOverlay:
            item.title = settings.showsInfoOverlay ? "Hide Photo Info" : "Show Photo Info"
            return true
        case .showKind(let kind):
            item.state = shot != nil && library.kind == kind ? .on : .off
            return shot?.url(for: kind) != nil
        case .toggleKind, .flagBoth:
            return shot?.isPaired == true
        case .flagOnly(let kind), .toggleFlag(let kind):
            return shot?.url(for: kind) != nil
        case .clearFlags:
            return !library.currentSelection.isEmpty
        case .clearAllFlags, .exportFlagged:
            return library.flaggedShotCount > 0
        case .zoomIn, .zoomOut, .zoomToFit, .zoomToActualSize, .toggleZoom:
            return shot != nil && settings.layout.showsViewer
        case .reloadFolder:
            return library.folder != nil
        case .revealInFinder, .openInDefaultApp:
            return library.currentURL != nil
        case .next:
            return !library.isAtEnd
        case .previous:
            return !library.isAtStart
        default:
            return shot != nil
        }
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.openFolder, .flexibleSpace, .layout, .compare, .inspector, .export]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.openFolder, .layout, .compare, .inspector, .export, .flexibleSpace, .space]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .openFolder:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Open"
            item.paletteLabel = "Open Folder"
            item.toolTip = "Open a folder of photos  ⌘O"
            item.image = NSImage.symbol("folder", description: "Open Folder")
            item.target = self
            item.action = #selector(toolbarOpenFolder(_:))
            item.isBordered = true
            return item

        case .layout:
            let layouts = BrowserLayout.allCases
            let group = NSToolbarItemGroup(
                itemIdentifier: itemIdentifier,
                images: layouts.map { NSImage.symbol($0.systemImage, description: $0.title) },
                selectionMode: .selectOne,
                labels: layouts.map(\.shortTitle),
                target: self,
                action: #selector(toolbarLayoutChanged(_:))
            )
            group.label = "Layout"
            group.paletteLabel = "Layout"
            group.toolTip = "Where the thumbnails go  ⌘1 – ⌘5"
            group.selectedIndex = layouts.firstIndex(of: settings.layout) ?? 0
            layoutItem = group
            return group

        case .compare:
            let group = NSToolbarItemGroup(
                itemIdentifier: itemIdentifier,
                images: [NSImage.symbol("rectangle.split.2x1", description: "Compare")],
                selectionMode: .selectAny,
                labels: ["Compare"],
                target: self,
                action: #selector(toolbarToggleCompare(_:))
            )
            group.label = "Compare"
            group.paletteLabel = "Compare JPG & NEF"
            group.toolTip = "Compare JPG and NEF side by side  C"
            group.setSelected(viewerModel.isComparing, at: 0)
            compareItem = group
            return group

        case .inspector:
            let group = NSToolbarItemGroup(
                itemIdentifier: itemIdentifier,
                images: [NSImage.symbol("info.circle", description: "Inspector")],
                selectionMode: .selectAny,
                labels: ["Inspector"],
                target: self,
                action: #selector(toolbarToggleInspector(_:))
            )
            group.label = "Inspector"
            group.paletteLabel = "Inspector"
            group.toolTip = "Show or hide the inspector  I"
            group.setSelected(settings.showsInspector, at: 0)
            inspectorItem = group
            return group

        case .export:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Export"
            item.paletteLabel = "Export Flagged"
            item.toolTip = "Export flagged photos  ⌘E"
            item.image = NSImage.symbol("square.and.arrow.up.on.square", description: "Export")
            item.target = self
            item.action = #selector(toolbarExport(_:))
            item.isBordered = true
            item.autovalidates = false
            item.isEnabled = library.flaggedShotCount > 0
            exportItem = item
            return item

        default:
            return nil
        }
    }

    @objc private func toolbarOpenFolder(_ sender: Any?) {
        chooseFolder()
    }

    @objc private func toolbarLayoutChanged(_ sender: NSToolbarItemGroup) {
        let layouts = BrowserLayout.allCases
        guard layouts.indices.contains(sender.selectedIndex) else { return }
        settings.layout = layouts[sender.selectedIndex]
    }

    @objc private func toolbarToggleCompare(_ sender: NSToolbarItemGroup) {
        perform(.toggleCompare)
        sender.setSelected(viewerModel.isComparing, at: 0)
    }

    @objc private func toolbarToggleInspector(_ sender: NSToolbarItemGroup) {
        perform(.toggleInspector)
        sender.setSelected(settings.showsInspector, at: 0)
    }

    @objc private func toolbarExport(_ sender: Any?) {
        perform(.exportFlagged)
    }

    // MARK: Window

    func windowWillClose(_ notification: Notification) {
        library.saveSessionNow()
    }
}
