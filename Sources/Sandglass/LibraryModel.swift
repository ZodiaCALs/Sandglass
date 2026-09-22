import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Central app state: which folder is open, which shot is on screen, which
/// variants are flagged, and how an export is progressing.
@MainActor
final class LibraryModel: ObservableObject {

    // MARK: Published state

    @Published private(set) var shots: [Shot] = []
    @Published private(set) var folder: URL?
    @Published private(set) var isScanning = false
    @Published var errorMessage: String?

    /// Flag selections per shot. A shot can hold JPG, NEF, or both.
    @Published private(set) var flags: [Shot.ID: FlagSelection] = [:]
    /// Shots the user has actually landed on, used for the progress reading.
    @Published private(set) var reviewed: Set<Shot.ID> = []

    @Published private(set) var index: Int = 0
    /// The variant currently being shown and acted on. The toggle flips this.
    @Published private(set) var kind: FileKind = .jpg

    /// Bumped whenever flags change so dependent views recompute cheaply.
    @Published private(set) var flagRevision: Int = 0

    // Export flow
    @Published var isExporting = false
    @Published private(set) var exportProgress: (done: Int, total: Int) = (0, 0)
    @Published var exportSummary: String?
    @Published var showingExportResult = false
    /// Remembered between exports so repeat runs are one click.
    @Published var lastExportFolder: URL?

    /// Size of the preview canvas in points, reported by the view.
    ///
    /// The decode budget is derived from this rather than being a fixed number.
    /// A fixed high budget is what made navigation feel slow on large files: a
    /// 6000 px JPEG decoded to 4200 px costs ~70 MB, so a handful of photos
    /// evicts the whole cache and every step re-decodes from scratch.
    private var canvasPoints: CGSize = CGSize(width: 820, height: 700)

    func reportCanvasSize(_ size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        let changed = abs(size.width - canvasPoints.width) > 8
            || abs(size.height - canvasPoints.height) > 8
        guard changed else { return }
        canvasPoints = size
        // The pane now needs a different number of pixels, so drop the stale
        // rendition and fetch one to match.
        refreshPreviewResolution()
    }

    /// Long-edge pixel budget for the current canvas.
    ///
    /// Covers the pane at 2× with a little headroom so resizing the window does
    /// not immediately need a re-decode, and never exceeds the loader's ceiling.
    var previewPixelBudget: Int {
        let needed = max(canvasPoints.width, canvasPoints.height) * Self.retinaScale * 1.2
        let clamped = min(max(needed, 1024), CGFloat(ThumbnailLoader.maximumPreviewPixel))
        return Int(clamped.rounded(.up))
    }

    /// Zoom bounds, shared so the slider, keyboard and gestures all agree.
    /// The live zoom value itself lives in `ZoomBridge`, next to the canvas.
    nonisolated static let minZoom: CGFloat = 1
    nonisolated static let maxZoom: CGFloat = 12

    private var thumbnails: [String: Thumbnail] = [:]
    private var loadingThumbnails: Set<String> = []
    /// Full-resolution previews for the large pane, kept apart from the small
    /// prefetch images in `thumbnails` so a soft preview is never shown as final.
    /// Native-resolution bitmap for the photo on screen. One entry only: these
    /// are large, and only the current photo needs one.
    private var previewImages: [String: CGImage] = [:]
    /// Budget each entry in `previewImages` was decoded at, so a window resize
    /// knows to re-decode.
    private var previewBudgets: [String: Int] = [:]
    private var detailTasks: [String: Task<Void, Never>] = [:]
    /// Sharp renditions currently being fetched because of a zoom.
    private var zoomTasks: Set<String> = []
    private var metadataCache: [String: FileMetadata] = [:]
    private var metadataLoading: Set<String> = []
    /// Keys whose bytes could not be decoded, so the UI can say so instead of
    /// spinning forever. Also stops repeated decode attempts.
    private var failedThumbnails: Set<String> = []
    /// Guards against an in-flight scan finishing after a newer one started.
    private var scanToken = UUID()
    /// Last reviewed index per folder, so reopening a folder resumes where you left off.
    private var lastPosition: [String: Int] = [:]

    // MARK: Derived state

    var currentShot: Shot? {
        guard shots.indices.contains(index) else { return nil }
        return shots[index]
    }

    var isEmpty: Bool { shots.isEmpty }

    var flaggedShotIDs: [Shot.ID] {
        shots.map(\.id).filter { !(flags[$0] ?? []).isEmpty }
    }

    var flaggedCount: Int { flaggedShotIDs.count }

    /// Total individual files that would be exported.
    var flaggedFileCount: Int {
        flags.values.reduce(0) { $0 + $1.kinds.count }
    }

    var totalCount: Int { shots.count }
    var position: Int { shots.isEmpty ? 0 : index + 1 }

    var selectionForCurrent: FlagSelection {
        guard let shot = currentShot else { return [] }
        return flags[shot.id] ?? []
    }

    var isCurrentFlagged: Bool { !selectionForCurrent.isEmpty }

    var progressFraction: Double {
        guard !shots.isEmpty else { return 0 }
        return Double(reviewed.count) / Double(shots.count)
    }

    var isAtEnd: Bool {
        guard !shots.isEmpty else { return false }
        return index >= shots.count - 1
    }

    // MARK: Opening a folder

    /// Present the folder picker and load the chosen folder.
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a folder of JPG and NEF photos"
        panel.title = "Open Photo Folder"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(folder: url)
    }

    /// Scan a folder directly, bypassing the picker. Used for the folder passed
    /// on the command line so the app can open a shoot straight from a shell.
    func openFolder(at url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            errorMessage = "“\(url.lastPathComponent)” is not a folder."
            return
        }
        load(folder: url)
    }

    /// Scan `url` for shots and reset all review state.
    func load(folder url: URL) {
        let token = UUID()
        scanToken = token

        isScanning = true
        errorMessage = nil
        for task in detailTasks.values { task.cancel() }
        detailTasks.removeAll()
        previewImages.removeAll()
        previewBudgets.removeAll()
        metadataCache.removeAll()
        metadataLoading.removeAll()
        thumbnails.removeAll()
        loadingThumbnails.removeAll()
        failedThumbnails.removeAll()
        Task { await ThumbnailLoader.shared.purge() }

        Task {
            let scanned: [Shot]
            do {
                scanned = try await Task.detached(priority: .userInitiated) {
                    try FolderScanner.scan(folder: url)
                }.value
            } catch {
                guard self.scanToken == token else { return }
                self.isScanning = false
                self.errorMessage = error.localizedDescription
                return
            }

            guard self.scanToken == token else { return }
            self.folder = url
            self.shots = scanned
            self.flags = [:]
            self.reviewed = []
            // Returning to a folder you are part-way through should not lose your place.
            let restoredIndex = min(max(self.lastPosition[url.path] ?? 0, 0), max(scanned.count - 1, 0))
            self.index = restoredIndex
            self.isScanning = false
            // Start on a variant that exists for the first shot.
            self.kind = scanned.first?.defaultKind ?? .jpg
            self.markReviewed()
            self.prefetchAroundCurrent()
            self.requestFullResolutionPreview()
        }
    }

    /// Rescan the open folder, keeping flags for shots that still exist.
    func reload() {
        guard let folder else { return }
        let keptFlags = flags
        let keptFolder = folder
        load(folder: keptFolder)
        // Re-apply flags for surviving shots once the scan lands.
        Task {
            while isScanning { try? await Task.sleep(nanoseconds: 40_000_000) }
            var restored: [Shot.ID: FlagSelection] = [:]
            for shot in shots {
                if let selection = keptFlags[shot.id] { restored[shot.id] = selection }
            }
            flags = restored
            flagRevision &+= 1
        }
    }

    // MARK: Navigating

    func go(to newIndex: Int) {
        guard !shots.isEmpty else { return }
        index = min(max(newIndex, 0), shots.count - 1)
        if let folder { lastPosition[folder.path] = index }
        markReviewed()
        // Keep the shown variant valid for the shot we just landed on.
        if currentShot?.url(for: kind) == nil, let fallback = currentShot?.defaultKind {
            kind = fallback
        }
        prefetchAroundCurrent()
        requestFullResolutionPreview()
    }

    func next() {
        guard !isAtEnd else { return }
        go(to: index + 1)
    }

    func previous() {
        guard index > 0 else { return }
        go(to: index - 1)
    }

    func jumpToEnd() { go(to: shots.count - 1) }

    /// Flip between JPG and NEF.
    ///
    /// Returns the variant that could not be shown, so the UI can explain why
    /// nothing happened on a shot that lacks that half of the pair.
    @discardableResult
    func toggleKind() -> FileKind? {
        guard currentShot != nil else { return nil }
        return setKind(kind.other) ? nil : kind.other
    }

    /// Switch the displayed variant. Returns false when that variant is missing.
    @discardableResult
    func setKind(_ newKind: FileKind) -> Bool {
        guard let shot = currentShot else { return false }
        guard shot.url(for: newKind) != nil else { return false }
        kind = newKind
        prefetchAroundCurrent()
        requestFullResolutionPreview()
        return true
    }

    /// True when the current shot can actually be shown in `kind`.
    func canShow(_ candidate: FileKind) -> Bool {
        currentShot?.url(for: candidate) != nil
    }

    private func markReviewed() {
        guard let shot = currentShot else { return }
        reviewed.insert(shot.id)
    }

    // MARK: Preview availability

    /// Thumbnails that could not be decoded, so the UI can explain why.
    enum PreviewState {
        case loading
        case ready
        case unavailable
        case missingVariant
    }

    func previewState(for shot: Shot, kind variant: FileKind) -> PreviewState {
        guard shot.url(for: variant) != nil else { return .missingVariant }
        if previewCGImage(for: shot, kind: variant) != nil { return .ready }
        if failedThumbnails.contains(fileKey(shot, variant)) { return .unavailable }
        return .loading
    }

    /// The sharpest preview currently available.
    ///
    /// Full resolution when it has arrived, the prefetch otherwise, so the pane
    /// is filled immediately and then quietly sharpened.
    func previewCGImage(for shot: Shot, kind variant: FileKind) -> CGImage? {
        // A rendition is good enough only if it was decoded at least at the
        // current budget. An older, smaller one is treated as absent so the pane
        // shows its loading state rather than a soft image — a mosaic of the
        // photo is far worse than a moment of waiting.
        let key = fileKey(shot, variant)
        if let image = previewImages[key], (previewBudgets[key] ?? 0) >= previewPixelBudget {
            return image
        }
        return thumbnails[cacheKey(shot, variant, previewPixelBudget)]?.image
    }

    /// True once the whole file has been decoded — not a proxy, not a budget.
    ///
    /// The test is whether the bitmap matches what the file reports about itself.
    /// That is a much stronger claim than "big enough for the pane", and it is the
    /// property that actually decides whether fine detail is present.
    func hasFullResolutionPreview(for shot: Shot, kind variant: FileKind) -> Bool {
        guard let image = previewImages[fileKey(shot, variant)] else { return false }
        return isWholeImage(image, for: shot, kind: variant)
    }

    /// Whether a decoded bitmap is the entire image the file holds.
    private func isWholeImage(_ image: CGImage, for shot: Shot, kind variant: FileKind) -> Bool {
        guard let url = shot.url(for: variant),
              let source = ThumbnailLoader.sourcePixelSize(of: url) else {
            // No dimension metadata to compare against; assume the decode is whole.
            return true
        }
        // Orientation can swap the axes, so accept either arrangement.
        let matches = (image.width == Int(source.width) && image.height == Int(source.height))
            || (image.width == Int(source.height) && image.height == Int(source.width))
        return matches
    }

    /// Human-readable account of what is on screen, for the diagnostics.
    func decodeReport(for shot: Shot, kind variant: FileKind) -> String {
        guard let url = shot.url(for: variant) else { return "no file" }
        let source = ThumbnailLoader.sourcePixelSize(of: url)
        let decoded = previewImages[fileKey(shot, variant)]
        let sourceText = source.map { "\(Int($0.width))x\(Int($0.height))" } ?? "?"
        let decodedText = decoded.map { "\($0.width)x\($0.height)" } ?? "not decoded"
        guard let decoded, let source else { return "file \(sourceText) -> \(decodedText)" }
        let whole = isWholeImage(decoded, for: shot, kind: variant)
        return "file \(sourceText) -> \(decodedText)  \(whole ? "whole image" : "PARTIAL — a proxy, not the file")"
    }

    /// Hand the file to the system so the shot is still reachable when its
    /// preview cannot be rendered.
    func openExternally(_ shot: Shot, kind variant: FileKind) {
        guard let url = shot.url(for: variant) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Metadata

    func metadata(for shot: Shot, kind variant: FileKind) -> FileMetadata? {
        metadataCache[fileKey(shot, variant)]
    }

    func isLoadingMetadata(for shot: Shot, kind variant: FileKind) -> Bool {
        metadataLoading.contains(fileKey(shot, variant))
    }

    func loadMetadata(for shot: Shot, kind variant: FileKind) {
        let key = fileKey(shot, variant)
        guard metadataCache[key] == nil, !metadataLoading.contains(key),
              let url = shot.url(for: variant) else { return }

        metadataLoading.insert(key)
        Task {
            let result = await Task.detached(priority: .utility) {
                MetadataReader.read(url: url)
            }.value
            self.metadataLoading.remove(key)
            if let result {
                self.metadataCache[key] = result
            } else {
                // Remember that there is nothing to show rather than re-reading.
                self.metadataCache[key] = FileMetadata(sections: [])
            }
        }
    }

    // MARK: Flagging

    /// Flag or unflag the current shot. `kind` defaults to whatever is on screen,
    /// which is what the on-screen flag button does.
    func toggleFlag(for kind: FileKind? = nil) {
        guard let shot = currentShot else { return }
        let target = kind ?? self.kind
        guard shot.url(for: target) != nil else { return }

        var selection = flags[shot.id] ?? []
        let bit = FlagSelection.kind(target)
        if selection.contains(bit) {
            selection.remove(bit)
        } else {
            selection.insert(bit)
        }

        if selection.isEmpty {
            flags[shot.id] = nil
        } else {
            flags[shot.id] = selection
        }
        flagRevision &+= 1
    }

    /// Flag both variants of the current shot in one action.
    func toggleFlagBoth() {
        guard let shot = currentShot else { return }
        let available = Set(shot.availableKinds)
        let current = flags[shot.id] ?? []
        let allFlagged = available.allSatisfy { current.contains(.kind($0)) }

        if allFlagged {
            flags[shot.id] = nil
        } else {
            var selection = current
            for variant in available { selection.insert(.kind(variant)) }
            flags[shot.id] = selection
        }
        flagRevision &+= 1
    }

    func clearAllFlags() {
        flags = [:]
        flagRevision &+= 1
    }

    /// Replace a shot's flag selection outright. Used by the "flag only this
    /// variant" shortcut and by programmatic flag changes.
    func setFlag(_ selection: FlagSelection, for shotID: Shot.ID) {
        if selection.isEmpty {
            flags[shotID] = nil
        } else {
            flags[shotID] = selection
        }
        flagRevision &+= 1
    }

    func flagFor(_ shot: Shot) -> FlagSelection {
        flags[shot.id] ?? []
    }

    // MARK: Export

    /// Ask where the flagged files should go, then run the export.
    func exportFlagged(mode: Exporter.Mode) {
        let plan = Exporter.plan(shots: shots, flags: flags)
        guard !plan.isEmpty else {
            exportSummary = "No photos are flagged yet."
            showingExportResult = true
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export Here"
        panel.message = "Choose a destination folder for \(plan.files.count) flagged file\(plan.files.count == 1 ? "" : "s")"
        panel.title = "Export Flagged Photos"
        if let last = lastExportFolder {
            panel.directoryURL = last
        }

        guard panel.runModal() == .OK, let destination = panel.url else { return }
        lastExportFolder = destination

        isExporting = true
        exportProgress = (0, plan.files.count)

        Task {
            let result = await Exporter.run(
                files: plan.files,
                destination: destination,
                mode: mode
            ) { done, total in
                self.exportProgress = (done, total)
            }

            self.isExporting = false
            var message = "\(result.summary) → \(destination.lastPathComponent)"
            if !result.failures.isEmpty {
                let preview = result.failures.prefix(3).joined(separator: "\n")
                let more = result.failures.count > 3 ? "\n…and \(result.failures.count - 3) more" : ""
                message += "\n\nProblems:\n\(preview)\(more)"
            }
            self.exportSummary = message
            self.showingExportResult = true
        }
    }

    /// Reveal the most recent export destination in Finder.
    func revealLastExport() {
        guard let folder = lastExportFolder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    // MARK: Thumbnails

    /// Identity of a file, independent of the size it was decoded at.
    private func fileKey(_ shot: Shot, _ variant: FileKind) -> String {
        "\(shot.id)|\(variant.rawValue)"
    }

    /// Identity of one decoded rendition.
    ///
    /// The pixel budget is part of the key on purpose. Without it a small grid
    /// tile and the large preview collide: whichever decodes first wins, and the
    /// preview pane ends up showing a tile-sized image blown up to fill it.
    private func cacheKey(_ shot: Shot, _ variant: FileKind, _ maxPixel: Int) -> String {
        "\(fileKey(shot, variant))|\(maxPixel)"
    }

    /// The small rendition used by the grid.
    func cachedThumbnail(for shot: Shot, kind variant: FileKind) -> CGImage? {
        thumbnails[cacheKey(shot, variant, ThumbnailLoader.tilePixel)]?.image
    }

    /// Load the grid rendition if it is not already cached, then publish it.
    func requestThumbnail(
        for shot: Shot,
        kind variant: FileKind,
        maxPixel: Int = ThumbnailLoader.tilePixel,
        urgent: Bool = false
    ) {
        let key = cacheKey(shot, variant, maxPixel)
        guard thumbnails[key] == nil, !loadingThumbnails.contains(key),
              !failedThumbnails.contains(fileKey(shot, variant)),
              let url = shot.url(for: variant) else { return }

        loadingThumbnails.insert(key)
        Task {
            let result = await ThumbnailLoader.shared.thumbnail(
                for: url,
                maxPixel: maxPixel,
                urgent: urgent
            )
            self.loadingThumbnails.remove(key)
            guard let result else {
                self.failedThumbnails.insert(fileKey(shot, variant))
                return
            }
            // Never let a coarser rendition overwrite a finer one already cached.
            if let existing = self.thumbnails[key],
               existing.pixelSize.width > result.pixelSize.width {
                return
            }
            self.thumbnails[key] = result
        }
    }

    /// Point size at which a bitmap is drawn 1:1 on a 2× display.
    ///
    /// The preview canvas sets a layer's `contents` directly and renders at
    /// `contentsScale = 1`, so image pixels map to device pixels with no
    /// resampling. This is used by the grid, which still draws through SwiftUI.
    nonisolated static func displaySize(for thumbnail: Thumbnail) -> NSSize {
        NSSize(
            width: thumbnail.pixelSize.width / retinaScale,
            height: thumbnail.pixelSize.height / retinaScale
        )
    }

    /// Assumed display scale. Retina Macs are 2×; a 1× display simply renders a
    /// slightly oversampled image, which is harmless.
    nonisolated static let retinaScale: CGFloat = 2

    /// Warm the neighbours so arrow-key culling never stalls on a decode.
    ///
    /// Only the two adjacent shots are prefetched, and only at a modest size:
    /// enough to fill the pane instantly, cheap enough not to compete with the
    /// full-resolution decode of the shot actually being viewed.
    private func prefetchAroundCurrent() {
        guard !shots.isEmpty else { return }
        // Neighbours only, at the budget the preview will ask for. The current
        // shot is deliberately excluded: it has exactly one request path.
        let budget = previewPixelBudget
        for candidate in [index + 1] where shots.indices.contains(candidate) {
            requestThumbnail(for: shots[candidate], kind: kind, maxPixel: budget, urgent: false)
        }
    }

    /// Ceiling for the zoom decode. Above this the file is treated as already
    /// larger than anyone needs to inspect pixel-for-pixel.
    nonisolated static let zoomPixelCeiling = 8000

    /// Decode the file at its **native** resolution because the user zoomed in.
    ///
    /// This is the only way zoom can be genuinely sharp. At 100% each image pixel
    /// covers one point, which is two device pixels on a Retina screen — so a
    /// screen-sized preview would be magnified with nothing behind it. Zooming is
    /// an explicit request to inspect detail, so it is worth the heavier decode;
    /// it is requested only for the photo on screen, and the cache evicts it
    /// naturally afterwards.
    func requestSharperPreviewWhileZoomed(zoomLevel: CGFloat) {
        guard zoomLevel > 1.05, let shot = currentShot, let url = shot.url(for: kind) else { return }

        // Ask for the file's own pixels. ImageIO returns the native image when
        // the request exceeds it, so this is exact rather than a guess.
        let budget = Self.zoomPixelCeiling
        let key = cacheKey(shot, kind, budget)
        guard thumbnails[key] == nil, !zoomTasks.contains(key) else { return }

        zoomTasks.insert(key)
        Task {
            let result = await ThumbnailLoader.shared.thumbnail(
                for: url,
                maxPixel: budget,
                urgent: false
            )
            self.zoomTasks.remove(key)
            guard let result else { return }
            if let existing = self.thumbnails[key],
               existing.pixelSize.width >= result.pixelSize.width {
                return
            }
            self.thumbnails[key] = result
            // Adopt it as the visible preview so the canvas picks it up.
            self.previewImages[self.fileKey(shot, kind)] = result.image
            self.previewBudgets[self.fileKey(shot, kind)] = Self.zoomPixelCeiling
        }
    }

    /// Re-decode at the new budget after the pane changes size.
    func refreshPreviewResolution() {
        guard let shot = currentShot else { return }
        previewImages[fileKey(shot, kind)] = nil
        previewBudgets[fileKey(shot, kind)] = nil
        prefetchAroundCurrent()
        requestFullResolutionPreview()
    }

    /// Request the sharpest preview for the current shot.
    ///
    /// Exactly one request per (photo, variant, budget). Prefetching the current
    /// shot through a second path used to deadlock: two identical decodes were
    /// requested at once, the loader coalesced them, and the inner request ended
    /// up awaiting the outer one — so the pane sat on a loading state forever.
    private func requestFullResolutionPreview() {
        guard let shot = currentShot, let url = shot.url(for: kind) else { return }
        let key = fileKey(shot, kind)

        // Decode the file at its own resolution. Anything less is a downscale,
        // and measuring a 6000 px JPEG shown through a 1968 px proxy put the loss
        // at ~12% of fine detail — visible as softness at normal viewing size.
        let budget = max(previewPixelBudget, ThumbnailLoader.nativeRequest)

        // Already decoded at native resolution: nothing to do.
        if previewImages[key] != nil, previewBudgets[key] == budget { return }
        guard detailTasks[key] == nil else { return }

        // Drop any other photo's native bitmap before decoding a new one.
        if previewImages.count > 1 { previewImages.removeAll() }

        detailTasks[key] = Task {
            // Native resolution, held only for the current photo and deliberately
            // kept out of the shared cache so it cannot evict everything else.
            let result = await ThumbnailLoader.shared.uncachedNativeImage(for: url)
            self.detailTasks[key] = nil
            guard let result else {
                self.failedThumbnails.insert(key)
                return
            }
            self.previewImages[key] = result.image
            self.previewBudgets[key] = budget
            self.objectWillChange.send()
        }
    }

}
