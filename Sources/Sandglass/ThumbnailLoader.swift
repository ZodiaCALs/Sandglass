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

    /// Load a preview for `url`, honouring `maxPixel` on the long edge.
    func thumbnail(for url: URL, maxPixel: Int) async -> Thumbnail? {
        await thumbnails(for: [(url: url, maxPixel: maxPixel)]).first ?? nil
    }

    /// Load several previews in one pass.
    ///
    /// A task group bounds how many decodes run at once instead of serialising
    /// them, and results come back in request order.
    func thumbnails(for requests: [(url: URL, maxPixel: Int)]) async -> [Thumbnail?] {
        var results = [Thumbnail?](repeating: nil, count: requests.count)
        var pending: [(key: Key, url: URL, maxPixel: Int)] = []
        var pendingIndices: [Int] = []

        // Serve whatever is already cached or in flight.
        for (index, request) in requests.enumerated() {
            let key = Key(path: request.url.path, maxPixel: request.maxPixel)
            if let hit = cache[key] {
                touch(key)
                results[index] = hit
            } else if let running = inFlight[key] {
                results[index] = await running.value
            } else {
                pending.append((key, request.url, request.maxPixel))
                pendingIndices.append(index)
            }
        }

        guard !pending.isEmpty else { return results }

        let decoded = await withTaskGroup(
            of: (offset: Int, thumbnail: Thumbnail?).self,
            returning: [(offset: Int, thumbnail: Thumbnail?)].self
        ) { group in
            for (offset, item) in pending.enumerated() {
                group.addTask { (offset, Self.decode(url: item.url, maxPixel: item.maxPixel)) }
            }
            var collected: [(offset: Int, thumbnail: Thumbnail?)] = []
            for await value in group { collected.append(value) }
            return collected
        }

        for (offset, thumbnail) in decoded {
            guard let thumbnail, pending.indices.contains(offset) else { continue }
            store(pending[offset].key, thumbnail)
            results[pendingIndices[offset]] = thumbnail
        }
        return results
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
