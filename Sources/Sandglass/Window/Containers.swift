import AppKit
import SwiftUI

/// Hosts one child view controller, filling its view. The thumbnail browser
/// moves between these as the layout changes.
@MainActor
final class HostViewController: NSViewController {
    private(set) var child: NSViewController?
    private let background: NSView?

    /// - Parameter glass: give the host its own glass panel (for places that do
    ///   not get one from the system, unlike the sidebar).
    init(glass: Bool) {
        background = glass ? GlassContainerView(cornerRadius: 16) : nil
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func loadView() {
        let root = LayoutReportingView()
        root.onLayout = { [weak self] in self?.layoutChild() }
        view = root
        if let background { view.addSubview(background) }
    }

    func host(_ controller: NSViewController?) {
        if let child, child !== controller {
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        child = controller
        guard let controller else { return }
        if controller.parent !== self {
            controller.view.removeFromSuperview()
            controller.removeFromParent()
            addChild(controller)
        }
        if let glass = background as? GlassContainerView {
            glass.content.addSubview(controller.view)
        } else {
            view.addSubview(controller.view)
        }
        view.needsLayout = true
    }

    private func layoutChild() {
        let inset: CGFloat = background == nil ? 0 : 8
        var frame = view.bounds.insetBy(dx: inset, dy: inset)
        if background != nil {
            // A glass panel of our own stays clear of the toolbar above it.
            let top = view.safeAreaInsets.top
            frame.origin.y += top
            frame.size.height = max(0, frame.height - top)
        }
        if let background {
            background.frame = frame
            background.needsLayout = true
        } else {
            child?.view.frame = frame
        }
    }
}

/// The main area: the photo, with the filmstrip under it — or the grid in its
/// place.
@MainActor
final class StageViewController: NSViewController {
    let viewer: ViewerViewController
    let filmstrip = HostViewController(glass: true)
    let grid = HostViewController(glass: false)

    var layoutMode: BrowserLayout = .filmstrip {
        didSet {
            guard layoutMode != oldValue else { return }
            applyVisibility()
        }
    }

    /// Height of the filmstrip shelf, from the thumbnail size.
    var filmstripHeight: CGFloat = 120 {
        didSet { view.needsLayout = true }
    }

    init(viewer: ViewerViewController) {
        self.viewer = viewer
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func loadView() {
        let root = LayoutReportingView()
        root.onLayout = { [weak self] in self?.layoutChildren() }
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(viewer)
        view.addSubview(viewer.view)
        addChild(filmstrip)
        view.addSubview(filmstrip.view)
        addChild(grid)
        view.addSubview(grid.view)
        applyVisibility()
    }

    private func applyVisibility() {
        guard isViewLoaded else { return }
        viewer.view.isHidden = !layoutMode.showsViewer
        filmstrip.view.isHidden = layoutMode != .filmstrip
        grid.view.isHidden = layoutMode != .grid
        view.needsLayout = true
    }

    private func layoutChildren() {
        let bounds = view.bounds
        switch layoutMode {
        case .grid:
            let top = view.safeAreaInsets.top
            grid.view.frame = CGRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
        case .filmstrip:
            let height = min(filmstripHeight, bounds.height * 0.4)
            filmstrip.view.frame = CGRect(x: 0, y: bounds.height - height, width: bounds.width, height: height)
            viewer.view.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - height + 4)
        default:
            viewer.view.frame = bounds
        }
    }
}

/// The window's split view: thumbnails in a sidebar on either side, the stage
/// in the middle, the inspector on the right.
@MainActor
final class MainSplitViewController: NSSplitViewController {
    let leadingHost = HostViewController(glass: false)
    let trailingHost = HostViewController(glass: true)
    let stage: StageViewController
    let inspector: NSViewController

    private(set) var leadingItem: NSSplitViewItem!
    private(set) var stageItem: NSSplitViewItem!
    private(set) var trailingItem: NSSplitViewItem!
    private(set) var inspectorItem: NSSplitViewItem!

    init(stage: StageViewController, inspector: NSViewController) {
        self.stage = stage
        self.inspector = inspector
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.dividerStyle = .thin
        splitView.isVertical = true

        let leading = NSSplitViewItem(sidebarWithViewController: leadingHost)
        leading.minimumThickness = 190
        leading.maximumThickness = 520
        leading.canCollapse = true
        leading.isCollapsed = true

        let stageItem = NSSplitViewItem(viewController: stage)
        stageItem.minimumThickness = 420

        let trailing = NSSplitViewItem(viewController: trailingHost)
        trailing.minimumThickness = 190
        trailing.maximumThickness = 520
        trailing.canCollapse = true
        trailing.isCollapsed = true
        trailing.holdingPriority = NSLayoutConstraint.Priority(rawValue: 260)

        let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        inspectorItem.minimumThickness = 260
        inspectorItem.maximumThickness = 400
        inspectorItem.canCollapse = true
        inspectorItem.isCollapsed = true

        addSplitViewItem(leading)
        addSplitViewItem(stageItem)
        addSplitViewItem(trailing)
        addSplitViewItem(inspectorItem)
        leadingItem = leading
        self.stageItem = stageItem
        trailingItem = trailing
        self.inspectorItem = inspectorItem
    }

    /// Show or hide the side panels, animated.
    func setPanels(leading: Bool, trailing: Bool, inspector: Bool, animated: Bool) {
        let changes = {
            let target = animated ? self.leadingItem.animator() : self.leadingItem!
            target.isCollapsed = !leading
            let trailingTarget = animated ? self.trailingItem.animator() : self.trailingItem!
            trailingTarget.isCollapsed = !trailing
            let inspectorTarget = animated ? self.inspectorItem.animator() : self.inspectorItem!
            inspectorTarget.isCollapsed = !inspector
        }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.allowsImplicitAnimation = true
                changes()
            }
        } else {
            changes()
        }
    }
}

/// The window's content: backdrop, then either the welcome screen or the split
/// view, with drop handling and the scanning overlay on top.
@MainActor
final class RootViewController: NSViewController {
    let backdrop = BackdropView()
    let split: MainSplitViewController
    var onDrop: (([URL]) -> Bool)?

    private var welcome: NSHostingView<WelcomeView>?
    private var scanning: OverlayHostingView<ScanningView>?
    private let dropHighlight = NSView()

    init(split: MainSplitViewController) {
        self.split = split
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func loadView() {
        let root = DropTargetView(frame: NSRect(x: 0, y: 0, width: 1280, height: 820))
        root.onDrop = { [weak self] urls in self?.onDrop?(urls) ?? false }
        root.onHighlight = { [weak self] on in self?.setDropHighlight(on) }
        view = root

        backdrop.frame = root.bounds
        backdrop.autoresizingMask = [.width, .height]
        root.addSubview(backdrop)

        addChild(split)
        split.view.frame = root.bounds
        split.view.autoresizingMask = [.width, .height]
        root.addSubview(split.view)

        dropHighlight.wantsLayer = true
        dropHighlight.layer?.borderWidth = 3
        dropHighlight.layer?.cornerRadius = 14
        dropHighlight.layer?.borderColor = NSColor.controlAccentColor.cgColor
        dropHighlight.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
        dropHighlight.isHidden = true
        dropHighlight.autoresizingMask = [.width, .height]
        root.addSubview(dropHighlight)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        dropHighlight.frame = view.bounds.insetBy(dx: 8, dy: 8)
        if let scanning {
            let size = scanning.fittingSize
            scanning.frame = CGRect(x: view.bounds.midX - size.width / 2, y: view.bounds.midY - size.height / 2,
                                    width: size.width, height: size.height)
        }
    }

    /// The welcome screen, shown while no folder is open.
    func showWelcome(_ view: WelcomeView?) {
        if let view {
            split.view.isHidden = true
            if let welcome {
                welcome.rootView = view
            } else {
                let host = NSHostingView(rootView: view)
                host.frame = self.view.bounds
                host.autoresizingMask = [.width, .height]
                self.view.addSubview(host, positioned: .below, relativeTo: dropHighlight)
                welcome = host
            }
        } else {
            split.view.isHidden = false
            welcome?.removeFromSuperview()
            welcome = nil
        }
    }

    func showScanning(folderName: String?) {
        if let folderName {
            if let scanning {
                scanning.rootView = ScanningView(folderName: folderName)
            } else {
                let host = OverlayHostingView(rootView: ScanningView(folderName: folderName))
                view.addSubview(host)
                scanning = host
            }
            view.needsLayout = true
        } else {
            scanning?.removeFromSuperview()
            scanning = nil
        }
    }

    private func setDropHighlight(_ on: Bool) {
        dropHighlight.isHidden = !on
    }
}
