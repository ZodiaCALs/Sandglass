import AppKit
import SwiftUI

/// Something to do to one tile, from its context menu.
enum BrowserAction: Sendable {
    case show
    case toggleFlag(FileKind)
    case flagBoth
    case clearFlags
    case revealInFinder
    case openInDefaultApp
}

/// The thumbnail browser — a filmstrip, a sidebar or a full grid depending on
/// the layout.
///
/// Built on `NSCollectionView`, which only creates views for tiles on screen and
/// recycles them, so a folder of thousands of photos costs no more than the
/// handful visible. Each tile requests its thumbnail when it appears and cancels
/// the request when it scrolls away.
@MainActor
final class BrowserViewController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate {

    enum Placement: Equatable {
        case sidebar
        case filmstrip
        case grid
    }

    /// Double-click or Return on a tile.
    var onOpen: ((Int) -> Void)?
    /// A context-menu action on a tile.
    var onAction: ((BrowserAction, Int) -> Void)?

    private(set) var placement: Placement = .filmstrip

    private let library: Library
    private let thumbnails: ThumbnailStore
    private let settings: AppSettings
    private let scrollView = BrowserScrollView()
    private let collectionView = NSCollectionView()
    private let flowLayout = NSCollectionViewFlowLayout()
    private var sizeControl: OverlayHostingView<TileSizeControl>!
    private var observers: [ObservationLoop] = []
    private var shownGeneration = -1
    private var isApplyingSelection = false

    private static let spacing: CGFloat = 8

    init(library: Library, thumbnails: ThumbnailStore, settings: AppSettings) {
        self.library = library
        self.thumbnails = thumbnails
        self.settings = settings
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

        flowLayout.minimumInteritemSpacing = Self.spacing
        flowLayout.minimumLineSpacing = Self.spacing
        collectionView.collectionViewLayout = flowLayout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.allowsEmptySelection = false
        collectionView.backgroundColors = [.clear]
        collectionView.register(ThumbnailItem.self, forItemWithIdentifier: ThumbnailItem.identifier)
        collectionView.setDraggingSourceOperationMask(.copy, forLocal: false)
        collectionView.setAccessibilityLabel("Photos")

        scrollView.documentView = collectionView
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.hasVerticalScroller = true
        view.addSubview(scrollView)

        sizeControl = OverlayHostingView(rootView: TileSizeControl(settings: settings, library: library))
        sizeControl.isHidden = true
        view.addSubview(sizeControl)

        observers.append(ObservationLoop { [weak self] in self?.syncShots() })
        observers.append(ObservationLoop { [weak self] in self?.syncSelection() })
        observers.append(ObservationLoop { [weak self] in self?.syncFlags() })
        observers.append(ObservationLoop { [weak self] in self?.syncTileSize() })
    }

    // MARK: Placement

    func setPlacement(_ newPlacement: Placement) {
        placement = newPlacement
        flowLayout.scrollDirection = newPlacement == .filmstrip ? .horizontal : .vertical
        scrollView.hasHorizontalScroller = newPlacement == .filmstrip
        scrollView.hasVerticalScroller = newPlacement != .filmstrip
        scrollView.scrollsHorizontally = newPlacement == .filmstrip
        sizeControl.isHidden = newPlacement != .grid
        view.needsLayout = true
        updateItemSize(force: true)
        collectionView.reloadData()
        applySelection(library.index, animated: false)
    }

    /// Tiles per row, for moving up and down in the grid.
    var columnsPerRow: Int {
        guard placement != .filmstrip else { return 1 }
        let inset = flowLayout.sectionInset
        let available = scrollView.contentView.bounds.width - inset.left - inset.right
        let width = flowLayout.itemSize.width
        guard width > 0 else { return 1 }
        return max(1, Int((available + Self.spacing) / (width + Self.spacing)))
    }

    /// Give keyboard focus to the tiles (used when entering the grid).
    func focus() {
        _ = view.window?.makeFirstResponder(collectionView)
    }

    // MARK: Layout

    private func layoutContent() {
        scrollView.frame = view.bounds
        if placement == .grid {
            let size = sizeControl.fittingSize
            sizeControl.frame = CGRect(
                x: view.bounds.maxX - size.width - 16,
                y: view.bounds.maxY - size.height - 14,
                width: size.width,
                height: size.height
            )
        }
        updateItemSize(force: false)
    }

    private func updateItemSize(force: Bool) {
        let visible = scrollView.contentView.bounds.size
        guard visible.width > 1, visible.height > 1 else { return }
        let spacing = Self.spacing
        var size: NSSize
        let insets: NSEdgeInsets
        switch placement {
        case .filmstrip:
            insets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
            let height = max(44, visible.height - insets.top - insets.bottom)
            size = NSSize(width: (height * 1.4).rounded(), height: height)
        case .sidebar, .grid:
            insets = placement == .grid
                ? NSEdgeInsets(top: 14, left: 14, bottom: 64, right: 14)
                : NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
            let target = CGFloat(placement == .grid ? settings.tileSize : min(settings.tileSize, 160))
            let available = visible.width - insets.left - insets.right
            let columns = max(1, Int((available + spacing) / (target + spacing)))
            let width = max(64, ((available - spacing * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down))
            size = NSSize(width: width, height: (width * 0.8 + 28).rounded())
        }
        let current = flowLayout.sectionInset
        let sameInsets = current.top == insets.top && current.left == insets.left
            && current.bottom == insets.bottom && current.right == insets.right
        guard force || size != flowLayout.itemSize || !sameInsets else { return }
        flowLayout.itemSize = size
        flowLayout.sectionInset = insets
        flowLayout.invalidateLayout()
    }

    private var thumbnailPixels: Int {
        let scale = view.window?.backingScaleFactor ?? 2
        return Int((max(flowLayout.itemSize.width, flowLayout.itemSize.height) * scale).rounded(.up))
    }

    // MARK: Following the model

    private func syncShots() {
        let generation = library.generation
        guard generation != shownGeneration else { return }
        shownGeneration = generation
        collectionView.reloadData()
        applySelection(library.index, animated: false)
    }

    private func syncSelection() {
        let index = library.index
        _ = library.generation
        applySelection(index, animated: true)
    }

    private func syncFlags() {
        _ = library.flags
        for case let item as ThumbnailItem in collectionView.visibleItems() {
            guard let path = collectionView.indexPath(for: item), library.shots.indices.contains(path.item) else { continue }
            let shot = library.shots[path.item]
            item.cell.setFlags(available: shot.availableKinds, flagged: library.selection(for: shot))
        }
    }

    private func syncTileSize() {
        _ = settings.tileSize
        updateItemSize(force: false)
    }

    private func applySelection(_ index: Int, animated: Bool) {
        guard index >= 0, index < collectionView.numberOfItems(inSection: 0) else { return }
        let path = IndexPath(item: index, section: 0)
        if collectionView.selectionIndexPaths != [path] {
            isApplyingSelection = true
            collectionView.selectionIndexPaths = [path]
            isApplyingSelection = false
        }
        let position: NSCollectionView.ScrollPosition = switch placement {
        case .filmstrip: .centeredHorizontally
        case .sidebar: .centeredVertically
        case .grid: .nearestHorizontalEdge
        }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                collectionView.animator().scrollToItems(at: [path], scrollPosition: position)
            }
        } else {
            collectionView.scrollToItems(at: [path], scrollPosition: position)
        }
    }

    // MARK: Data source

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        library.shots.count
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: ThumbnailItem.identifier, for: indexPath)
        if let tile = item as? ThumbnailItem {
            configure(tile, at: indexPath.item)
        }
        return item
    }

    private func configure(_ item: ThumbnailItem, at index: Int) {
        guard library.shots.indices.contains(index) else { return }
        let shot = library.shots[index]
        let cell = item.cell
        cell.style = placement == .filmstrip ? .compact : .card
        cell.name = shot.displayName
        cell.setFlags(available: shot.availableKinds, flagged: library.selection(for: shot))
        cell.toolTip = "\(shot.displayName) — \(shot.variantSummary)"
        cell.setAccessibilityLabel("\(shot.displayName), \(shot.variantSummary)")
        cell.onDoubleClick = { [weak self] in self?.onOpen?(index) }
        cell.menuProvider = { [weak self] in self?.menu(forItemAt: index) }

        // The JPG when there is one: it is what the camera rendered, and it keeps
        // the strip steady while switching variants.
        guard let url = shot.url(for: shot.defaultKind) else { return }
        item.loadTask?.cancel()
        item.representedURL = url
        let pixels = thumbnailPixels
        if let cached = thumbnails.cachedImage(for: url, pixels: pixels) {
            cell.setImage(cached, animated: false)
            cell.isUnavailable = false
            return
        }
        cell.setImage(nil, animated: false)
        cell.isUnavailable = thumbnails.hasFailed(url)
        guard !cell.isUnavailable else { return }
        item.loadTask = Task { [weak self, weak item] in
            guard let self else { return }
            let image = await self.thumbnails.image(for: url, pixels: pixels)
            guard !Task.isCancelled, let item, item.representedURL == url else { return }
            if let image {
                item.cell.setImage(image, animated: true)
            } else {
                item.cell.isUnavailable = true
            }
        }
    }

    // MARK: Delegate

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard !isApplyingSelection, let index = indexPaths.first?.item else { return }
        library.go(to: index)
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        didEndDisplaying item: NSCollectionViewItem,
        forRepresentedObjectAt indexPath: IndexPath
    ) {
        (item as? ThumbnailItem)?.loadTask?.cancel()
    }

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        true
    }

    /// Dragging a tile out drags the file, so photos can go straight to Finder or another app.
    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard library.shots.indices.contains(indexPath.item) else { return nil }
        let shot = library.shots[indexPath.item]
        guard let url = shot.url(for: shot.kind(preferring: library.preferredKind)) else { return nil }
        return url as NSURL
    }

    // MARK: Context menu

    private final class MenuAction: NSObject {
        let action: BrowserAction
        let index: Int

        init(_ action: BrowserAction, index: Int) {
            self.action = action
            self.index = index
        }
    }

    private func menu(forItemAt index: Int) -> NSMenu? {
        guard library.shots.indices.contains(index) else { return nil }
        let shot = library.shots[index]
        let selection = library.selection(for: shot)
        let menu = NSMenu()
        menu.autoenablesItems = false

        func add(_ title: String, _ action: BrowserAction, symbol: String, enabled: Bool = true, checked: Bool = false) {
            let item = NSMenuItem(title: title, action: #selector(runMenuAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = MenuAction(action, index: index)
            item.image = NSImage.symbol(symbol)
            item.isEnabled = enabled
            item.state = checked ? .on : .off
            menu.addItem(item)
        }

        add("Show Photo", .show, symbol: "photo")
        menu.addItem(.separator())
        for kind in FileKind.allCases {
            add("Flag \(kind.label)", .toggleFlag(kind), symbol: "flag",
                enabled: shot.url(for: kind) != nil, checked: selection.contains(.kind(kind)))
        }
        add("Flag Both", .flagBoth, symbol: "flag.2.crossed", enabled: shot.isPaired)
        add("Clear Flags", .clearFlags, symbol: "flag.slash", enabled: !selection.isEmpty)
        menu.addItem(.separator())
        add("Show in Finder", .revealInFinder, symbol: "folder")
        add("Open in Default App", .openInDefaultApp, symbol: "arrow.up.forward.app")
        return menu
    }

    @objc private func runMenuAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? MenuAction else { return }
        onAction?(action.action, action.index)
    }
}

/// A scroll view that lets a mouse wheel scroll a horizontal filmstrip.
final class BrowserScrollView: NSScrollView {
    var scrollsHorizontally = false

    override func scrollWheel(with event: NSEvent) {
        guard scrollsHorizontally, !event.hasPreciseScrollingDeltas,
              abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
              let document = documentView else {
            super.scrollWheel(with: event)
            return
        }
        let clip = contentView
        var origin = clip.bounds.origin
        let limit = max(0, document.frame.width - clip.bounds.width)
        origin.x = min(max(origin.x - event.scrollingDeltaY * 14, 0), limit)
        clip.scroll(to: origin)
        reflectScrolledClipView(clip)
    }
}

/// The grid's thumbnail-size slider, floating in the corner.
struct TileSizeControl: View {
    @Bindable var settings: AppSettings
    let library: Library

    var body: some View {
        HStack(spacing: 10) {
            Text("\(library.count) photos · \(library.flaggedShotCount) flagged")
                .font(Theme.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Image(systemName: "photo")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Slider(value: $settings.tileSize, in: 96...320)
                .controlSize(.small)
                .frame(width: 120)
                .help("Thumbnail size")
            Image(systemName: "photo")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassCapsule()
        .fixedSize()
    }
}
