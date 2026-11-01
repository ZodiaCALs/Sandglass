import Foundation
import CoreGraphics

/// Thumbnails for the browser: decoded in the background, cached on the main
/// actor, bounded in memory.
///
/// Requests for the same thumbnail share one decode. A cell that scrolls away
/// cancels its request; when nobody is waiting any more the decode is cancelled
/// too, so fast scrolling through thousands of photos never queues up thousands
/// of decodes.
@MainActor
final class ThumbnailStore {

    /// Long-edge sizes thumbnails are decoded at. A request is rounded up to the
    /// next bucket, so resizing tiles does not re-decode everything.
    static let buckets = [192, 288, 384, 512, 768]

    static func bucket(for pixels: Int) -> Int {
        buckets.first { $0 >= pixels } ?? buckets[buckets.count - 1]
    }

    /// About 1/48 of physical memory, between 96 MB and 256 MB.
    static var defaultCostLimit: Int {
        let physical = Double(ProcessInfo.processInfo.physicalMemory)
        return Int(min(max(physical / 48, 96 * 1_048_576), 256 * 1_048_576))
    }

    private struct Key: Hashable, Sendable {
        let url: URL
        let bucket: Int
    }

    private final class InFlight {
        let id = UUID()
        let task: Task<DecodedImage?, Never>
        var waiters = 1

        init(task: Task<DecodedImage?, Never>) {
            self.task = task
        }
    }

    private let cache: LRUCache<Key, DecodedImage>
    private var inFlight: [Key: InFlight] = [:]
    /// Files ImageIO could not decode, so they are not retried on every scroll.
    private var failures: Set<URL> = []

    init(costLimit: Int = ThumbnailStore.defaultCostLimit) {
        cache = LRUCache(costLimit: costLimit, countLimit: 8000)
    }

    var cachedCost: Int { cache.totalCost }

    /// A cached thumbnail of at least `pixels` on its long edge, if there is one.
    func cachedImage(for url: URL, pixels: Int) -> CGImage? {
        let wanted = Self.bucket(for: pixels)
        for bucket in Self.buckets where bucket >= wanted {
            if let hit = cache.value(forKey: Key(url: url, bucket: bucket)) {
                return hit.cgImage
            }
        }
        return nil
    }

    func hasFailed(_ url: URL) -> Bool {
        failures.contains(url)
    }

    /// The thumbnail for `url`, decoding it if needed. Returns nil when the file
    /// cannot be decoded or the calling task was cancelled.
    func image(for url: URL, pixels: Int, priority: TaskPriority = .utility) async -> CGImage? {
        if let hit = cachedImage(for: url, pixels: pixels) { return hit }
        guard !failures.contains(url) else { return nil }

        let key = Key(url: url, bucket: Self.bucket(for: pixels))
        let entry: InFlight
        if let existing = inFlight[key] {
            existing.waiters += 1
            entry = existing
        } else {
            let bucket = key.bucket
            let task = Task.detached(priority: priority) { () -> DecodedImage? in
                guard !Task.isCancelled else { return nil }
                return ImageDecoder.thumbnail(url: url, maxPixel: bucket)
            }
            entry = InFlight(task: task)
            inFlight[key] = entry
        }

        let id = entry.id
        let result = await withTaskCancellationHandler {
            await entry.task.value
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.release(key, id: id)
            }
        }

        if inFlight[key]?.id == id {
            inFlight[key] = nil
        }
        if let result {
            if cache.peek(key) == nil {
                cache.insert(result, forKey: key, cost: result.byteCost)
            }
        } else if !entry.task.isCancelled {
            failures.insert(url)
        }
        return Task.isCancelled ? nil : result?.cgImage
    }

    /// Drop part of the cache, keeping the most recently used thumbnails.
    func trim(keeping fraction: Double) {
        cache.trim(toCost: Int(Double(cache.totalCost) * min(max(fraction, 0), 1)))
    }

    func removeAll() {
        for entry in inFlight.values { entry.task.cancel() }
        inFlight.removeAll()
        cache.removeAll()
        failures.removeAll()
    }

    private func release(_ key: Key, id: UUID) {
        guard let entry = inFlight[key], entry.id == id else { return }
        entry.waiters -= 1
        if entry.waiters <= 0 {
            entry.task.cancel()
            inFlight[key] = nil
        }
    }
}
