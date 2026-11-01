import Foundation
import CoreGraphics
import Observation

/// The pictures behind the photo pane.
///
/// For every photo shown, a rendition sized to the pane is decoded first — it
/// is what fit-to-window needs, and it arrives quickly. Every pixel is decoded
/// only when zooming in goes beyond that rendition (or, after a short pause on a
/// photo, in the background so zooming is instant). The neighbours and the
/// other variant are prepared at low priority while you look, and anything no
/// longer wanted is cancelled the moment you move on.
///
/// Memory stays bounded: screen-sized renditions live in a small LRU cache, and
/// at most two full-resolution bitmaps — the two halves of Compare — are kept.
@MainActor
@Observable
final class PreviewStore {

    enum Status: Equatable, Sendable {
        case loading
        case ready
        /// ImageIO could not decode the file.
        case unavailable
        /// The photo has no file of this variant.
        case missing
    }

    /// What one pane shows.
    struct Slot: Equatable {
        let shotID: Shot.ID
        let kind: FileKind
        let url: URL?
        var status: Status
        var display: DecodedImage?
        var full: DecodedImage?

        /// The sharpest bitmap available.
        var best: DecodedImage? { full ?? display }

        /// True when no sharper bitmap exists for this file.
        var hasAllPixels: Bool { full != nil || display?.isFullResolution == true }

        static func == (lhs: Slot, rhs: Slot) -> Bool {
            lhs.shotID == rhs.shotID && lhs.kind == rhs.kind && lhs.url == rhs.url && lhs.status == rhs.status
                && lhs.display?.cgImage === rhs.display?.cgImage
                && lhs.full?.cgImage === rhs.full?.cgImage
        }
    }

    /// The main pane.
    private(set) var primary: Slot?
    /// The second pane in Compare: the same photo's other variant.
    private(set) var secondary: Slot?
    /// True while every pixel of a photo on screen is being decoded.
    private(set) var isLoadingFullResolution = false

    @ObservationIgnored var preloadFullResolution = true
    @ObservationIgnored var decodeRawWhenZooming = true
    /// Long edge, in pixels, of the renditions decoded for the pane.
    @ObservationIgnored private(set) var displayPixels = 2560

    @ObservationIgnored private let displayCache: LRUCache<URL, DecodedImage>
    @ObservationIgnored private let fullCache: LRUCache<URL, DecodedImage>
    @ObservationIgnored private var jobs: [Job: Task<Void, Never>] = [:]
    @ObservationIgnored private var failures: Set<URL> = []
    @ObservationIgnored private var upcoming: [URL] = []
    @ObservationIgnored private var preloadTask: Task<Void, Never>?
    @ObservationIgnored private var preloadDue = false

    private struct Job: Hashable {
        let url: URL
        let full: Bool
    }

    init() {
        let physical = Double(ProcessInfo.processInfo.physicalMemory)
        let displayBudget = Int(min(max(physical / 24, 192 * 1_048_576), 640 * 1_048_576))
        displayCache = LRUCache(costLimit: displayBudget, countLimit: 24)
        fullCache = LRUCache(costLimit: 900 * 1_048_576, countLimit: 2)
    }

    var cachedDisplayCount: Int { displayCache.count }
    var cachedFullCount: Int { fullCache.count }

    // MARK: Showing photos

    /// Show a photo (and, in Compare, its other variant), then prepare `next` —
    /// files likely to be shown soon — in the background.
    func show(_ shot: Shot?, kind: FileKind, compare: Bool, next: [URL]) {
        let newPrimary = makeSlot(shot, kind: kind, previous: primary)
        let newSecondary = compare ? makeSlot(shot, kind: kind.other, previous: secondary) : nil
        let movedOn = newPrimary?.url != primary?.url
        if newPrimary != primary { primary = newPrimary }
        if newSecondary != secondary { secondary = newSecondary }
        upcoming = next
        schedule()
        if movedOn { schedulePreload() }
        refreshLoadingFlag()
    }

    /// Ask for every pixel of the photos on screen — called when zooming in goes
    /// past what the screen-sized rendition can show.
    func requestFullResolution() {
        for slot in [primary, secondary].compactMap({ $0 }) where !slot.hasAllPixels {
            guard let url = slot.url, !failures.contains(url) else { continue }
            let job = Job(url: url, full: true)
            if jobs[job] == nil {
                start(job, priority: .userInitiated)
            }
        }
    }

    /// The pane changed size; renditions follow it so a big window gets more
    /// pixels and a small one stops paying for them.
    func updatePane(size: CGSize, backingScale: CGFloat) {
        guard size.width > 1, size.height > 1 else { return }
        let needed = Int((max(size.width, size.height) * max(backingScale, 1)).rounded(.up))
        let bucketed = min(max((needed + 255) / 256 * 256, 1024), 8192)
        guard bucketed != displayPixels else { return }
        displayPixels = bucketed
        schedule()
    }

    // MARK: Memory

    /// Release cached bitmaps — on memory pressure, or when a folder closes.
    func purge(keepingVisible: Bool) {
        let visible = visibleURLs
        for url in displayCache.keysByRecency where !(keepingVisible && visible.contains(url)) {
            displayCache.removeValue(forKey: url)
        }
        for url in fullCache.keysByRecency where !(keepingVisible && visible.contains(url)) {
            fullCache.removeValue(forKey: url)
        }
    }

    /// Forget everything — a different folder is being opened.
    func reset() {
        for task in jobs.values { task.cancel() }
        jobs.removeAll()
        preloadTask?.cancel()
        preloadTask = nil
        preloadDue = false
        displayCache.removeAll()
        fullCache.removeAll()
        failures.removeAll()
        upcoming = []
        primary = nil
        secondary = nil
        refreshLoadingFlag()
    }

    // MARK: Scheduling

    private var visibleURLs: Set<URL> {
        Set([primary?.url, secondary?.url].compactMap { $0 })
    }

    private func makeSlot(_ shot: Shot?, kind: FileKind, previous: Slot?) -> Slot? {
        guard let shot else { return nil }
        let url = shot.url(for: kind)
        if let previous, previous.shotID == shot.id, previous.kind == kind, previous.url == url {
            return previous
        }
        guard let url else {
            return Slot(shotID: shot.id, kind: kind, url: nil, status: .missing)
        }
        var slot = Slot(shotID: shot.id, kind: kind, url: url, status: .loading)
        slot.display = displayCache.value(forKey: url)
        slot.full = fullCache.value(forKey: url)
        if slot.best != nil {
            slot.status = .ready
        } else if failures.contains(url) {
            slot.status = .unavailable
        }
        return slot
    }

    private func needsDisplay(_ url: URL, current: DecodedImage?, hasFull: Bool) -> Bool {
        if failures.contains(url) || hasFull { return false }
        guard let current else { return true }
        return !current.isFullResolution && current.longEdge < displayPixels * 9 / 10
    }

    private func schedule() {
        var wanted: [(job: Job, priority: TaskPriority)] = []
        let visible = visibleURLs
        for slot in [primary, secondary].compactMap({ $0 }) {
            guard let url = slot.url else { continue }
            if needsDisplay(url, current: slot.display, hasFull: slot.full != nil) {
                wanted.append((Job(url: url, full: false), .userInitiated))
            }
        }
        for url in upcoming where !visible.contains(url) {
            if needsDisplay(url, current: displayCache.peek(url), hasFull: fullCache.peek(url) != nil) {
                wanted.append((Job(url: url, full: false), .utility))
            }
        }

        let keep = Set(wanted.map(\.job))
        for (job, task) in jobs {
            // Full-resolution work for a photo still on screen carries on.
            if keep.contains(job) || (job.full && visible.contains(job.url)) { continue }
            task.cancel()
            jobs[job] = nil
        }
        for item in wanted where jobs[item.job] == nil {
            start(item.job, priority: item.priority)
        }
    }

    private func start(_ job: Job, priority: TaskPriority) {
        let url = job.url
        let pixels = displayPixels
        let allowRaw = decodeRawWhenZooming
        jobs[job] = Task(priority: priority) { [weak self] in
            let result: DecodedImage?
            if job.full {
                result = await PreviewStore.decodeFull(url: url, allowRawDecode: allowRaw)
            } else {
                result = await PreviewStore.decodeDisplay(url: url, maxPixel: pixels)
            }
            guard !Task.isCancelled, let self else { return }
            self.finish(job, result: result)
        }
        refreshLoadingFlag()
    }

    @concurrent
    nonisolated private static func decodeDisplay(url: URL, maxPixel: Int) async -> DecodedImage? {
        guard !Task.isCancelled else { return nil }
        return ImageDecoder.display(url: url, maxPixel: maxPixel)
    }

    @concurrent
    nonisolated private static func decodeFull(url: URL, allowRawDecode: Bool) async -> DecodedImage? {
        guard !Task.isCancelled else { return nil }
        return ImageDecoder.fullResolution(url: url, allowRawDecode: allowRawDecode)
    }

    private func finish(_ job: Job, result: DecodedImage?) {
        jobs[job] = nil
        defer { refreshLoadingFlag() }

        guard let result else {
            guard !job.full else { return }
            failures.insert(job.url)
            updateSlots(for: job.url) { slot in
                if slot.best == nil { slot.status = .unavailable }
            }
            return
        }

        if job.full {
            fullCache.insert(result, forKey: job.url, cost: result.byteCost)
            updateSlots(for: job.url) { slot in
                slot.full = result
                slot.status = .ready
            }
        } else {
            displayCache.insert(result, forKey: job.url, cost: result.byteCost)
            updateSlots(for: job.url) { slot in
                if (slot.display?.longEdge ?? 0) < result.longEdge {
                    slot.display = result
                }
                slot.status = .ready
            }
            if preloadDue, job.url == primary?.url {
                preloadDue = false
                preloadFull()
            }
        }
    }

    private func updateSlots(for url: URL, _ change: (inout Slot) -> Void) {
        if var slot = primary, slot.url == url {
            change(&slot)
            if slot != primary { primary = slot }
        }
        if var slot = secondary, slot.url == url {
            change(&slot)
            if slot != secondary { secondary = slot }
        }
    }

    /// After a short pause on a photo, decode every pixel in the background so
    /// zooming in is instant. Holding an arrow key never triggers it.
    private func schedulePreload() {
        preloadTask?.cancel()
        preloadDue = false
        guard preloadFullResolution, primary?.url != nil else { return }
        preloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let self else { return }
            if self.primary?.display != nil {
                self.preloadFull()
            } else {
                // Wait for the screen-sized rendition, so the two never compete.
                self.preloadDue = true
            }
        }
    }

    private func preloadFull() {
        guard preloadFullResolution, let slot = primary, !slot.hasAllPixels,
              let url = slot.url, !failures.contains(url) else { return }
        let job = Job(url: url, full: true)
        if jobs[job] == nil {
            start(job, priority: .utility)
        }
    }

    private func refreshLoadingFlag() {
        let visible = visibleURLs
        let loading = jobs.keys.contains { $0.full && visible.contains($0.url) }
        if loading != isLoadingFullResolution {
            isLoadingFullResolution = loading
        }
    }
}
