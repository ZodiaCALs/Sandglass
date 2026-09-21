import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// A decoded, downsampled preview image that can cross actor boundaries.
///
/// `CGImage` is immutable once created, so sharing it is safe even though it
/// predates `Sendable` annotation.
struct Thumbnail: @unchecked Sendable {
    let image: CGImage
    let pixelSize: CGSize
}

/// Decodes thumbnails off the main thread and keeps a bounded cache.
///
/// Uses ImageIO, which reads the embedded JPEG preview inside NEF files instead
/// of demosaicing the full raw — fast enough for a grid of hundreds of shots.
actor ThumbnailLoader {
    static let shared = ThumbnailLoader()

    /// Upper bound on cached decoded pixels (approximate bytes) before eviction.
    ///
    /// Sized to hold a handful of full-resolution previews plus the small
    /// prefetch images around them, without letting a long culling session grow
    /// without limit.
    private let byteLimit = 384 * 1024 * 1024
    private let countLimit = 500

    private struct Key: Hashable {
        let path: String
        let maxPixel: Int
    }

    private var cache: [Key: Thumbnail] = [:]
    private var order: [Key] = []          // least-recently-used first
    private var cost: [Key: Int] = [:]
    private var totalCost = 0
    private var inFlight: [Key: Task<Thumbnail?, Never>] = [:]

    // MARK: Public API

    /// Instant prefetch shown while the sharp pass is in flight.
    nonisolated static let prefetchPixel = 1400
    /// Grid tile rendition, matching a 156 pt tile on a 2× display.
    nonisolated static let tilePixel = 320
    /// Upper bound for any preview request.
    nonisolated static let maximumPreviewPixel = 4200

    /// Load a preview for `url`.
    ///
    /// Urgent by default: a single-file request comes from the preview pane, and
    /// must never queue behind the filmstrip's tiles.
    func thumbnail(for url: URL, maxPixel: Int, urgent: Bool = true) async -> Thumbnail? {
        await load(url: url, maxPixel: maxPixel, urgent: urgent)
    }

    /// Load several previews in one pass, returning them in request order.
    ///
    /// `urgent` requests run as independent high-priority tasks. Grid tiles go
    /// through a lower-priority task group, so hundreds of them can never starve
    /// the photo actually on screen.
    func thumbnails(
        for requests: [(url: URL, maxPixel: Int)],
        urgent: Bool = false
    ) async -> [Thumbnail?] {
        var results = [Thumbnail?](repeating: nil, count: requests.count)
        var pending: [(key: Key, url: URL, maxPixel: Int)] = []
        var pendingIndices: [Int] = []

        // Serve whatever is already cached or in flight.
        for (index, request) in requests.enumerated() {
            let key = Key(path: request.url.path, maxPixel: request.maxPixel)
            if let hit = cache[key] {
                touch(key)
                results[index] = hit
            } else if let running = inFlight[key], !urgent {
                results[index] = await running.value
            } else {
                pending.append((key, request.url, request.maxPixel))
                pendingIndices.append(index)
            }
        }

        guard !pending.isEmpty else { return results }

        let priority: TaskPriority = urgent ? .userInitiated : .utility
        let decoded = await withTaskGroup(
            of: (offset: Int, thumbnail: Thumbnail?).self,
            returning: [(offset: Int, thumbnail: Thumbnail?)].self
        ) { group in
            for (offset, item) in pending.enumerated() {
                group.addTask(priority: priority) {
                    (offset, await self.load(url: item.url, maxPixel: item.maxPixel, urgent: urgent))
                }
            }
            var collected: [(offset: Int, thumbnail: Thumbnail?)] = []
            for await value in group { collected.append(value) }
            return collected
        }

        for (offset, thumbnail) in decoded where pending.indices.contains(offset) {
            results[pendingIndices[offset]] = thumbnail
        }
        return results
    }

    /// Decode one image, coalescing duplicate work.
    ///
    /// Urgent requests get their own high-priority task rather than joining a
    /// shared group, which is what keeps the preview responsive while the grid is
    /// still filling in.
    private func load(url: URL, maxPixel: Int, urgent: Bool) async -> Thumbnail? {
        let key = Key(path: url.path, maxPixel: maxPixel)

        if let hit = cache[key] {
            touch(key)
            return hit
        }
        if let running = inFlight[key] {
            return await running.value
        }

        let task = Task<Thumbnail?, Never>(priority: urgent ? .userInitiated : .utility) {
            Self.decode(url: url, maxPixel: maxPixel)
        }
        inFlight[key] = task

        let result = await task.value
        inFlight[key] = nil
        if let result {
            store(key, result)
        }
        return result
    }

    /// Drop everything — used when the user opens a different folder.
    func purge() {
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        cache.removeAll()
        order.removeAll()
        cost.removeAll()
        totalCost = 0
    }

    // MARK: Decoding

    /// Synchronous decode; always called from a detached context, never the main thread.
    private nonisolated static func decode(url: URL, maxPixel: Int) -> Thumbnail? {
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary),
              CGImageSourceGetCount(source) > 0 else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]

        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        return Thumbnail(
            image: image,
            pixelSize: CGSize(width: image.width, height: image.height)
        )
    }

    // MARK: Cache bookkeeping

    private func touch(_ key: Key) {
        if let index = order.firstIndex(of: key) {
            order.remove(at: index)
        }
        order.append(key)
    }

    private func store(_ key: Key, _ thumbnail: Thumbnail) {
        let bytes = thumbnail.image.bytesPerRow * thumbnail.image.height
        cache[key] = thumbnail
        cost[key] = bytes
        totalCost += bytes
        touch(key)

        while totalCost > byteLimit || cache.count > countLimit, let oldest = order.first {
            evict(oldest)
        }
    }

    private func evict(_ key: Key) {
        cache[key] = nil
        totalCost -= cost[key] ?? 0
        cost[key] = nil
        if let index = order.firstIndex(of: key) {
            order.remove(at: index)
        }
    }
}
