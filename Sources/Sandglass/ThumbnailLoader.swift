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
    /// Largest bitmap decoded whole. Beyond this the image is scaled on decode.
    nonisolated static let directDecodeCeiling = 12_000
    /// Ask for the file's own pixels.
    ///
    /// `CGImageSourceCreateThumbnailAtIndex` returns the native image whenever the
    /// request exceeds it, so this means "full resolution" without needing to know
    /// the file's dimensions first. The cap only guards against absurd sizes.
    nonisolated static let nativeRequest = 12_000

    /// Load a preview for `url`.
    ///
    /// Urgent by default: a single-file request comes from the preview pane, and
    /// must never queue behind the filmstrip's tiles.
    func thumbnail(for url: URL, maxPixel: Int, urgent: Bool = true) async -> Thumbnail? {
        await load(url: url, maxPixel: maxPixel, urgent: urgent)
    }

    /// Decode the file itself, at its own resolution, without caching.
    ///
    /// This deliberately does **not** go through the thumbnail API. A photo editor
    /// opens the image; it does not ask the system for a thumbnail. For a JPEG the
    /// two agree, but for a raw file the thumbnail route can hand back an embedded
    /// JPEG preview instead of the decoded raw, which is exactly the kind of
    /// softness this app must not show.
    ///
    /// A native decode of a 24 MP photo is roughly 144 MB, so the caller holds the
    /// bitmap itself and releases it on navigation rather than sharing a cache.
    func uncachedNativeImage(for url: URL) async -> Thumbnail? {
        let key = Key(path: url.path, maxPixel: Self.nativeRequest)
        if let running = inFlight[key] { return await running.value }

        let task = Task<Thumbnail?, Never>(priority: .userInitiated) {
            Self.decodeFull(url: url)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    /// Pixel dimensions the file reports for itself.
    ///
    /// Used to confirm that a decode really did return the whole image rather than
    /// a smaller proxy.
    nonisolated static func sourcePixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 1, height > 1 else { return nil }
        return CGSize(width: width, height: height)
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

    /// Decode the image proper — the equivalent of opening the file in an editor.
    ///
    /// `CGImageSourceCreateImageAtIndex` returns the full image (demosaicing a raw
    /// rather than reading its embedded preview) but does not apply the EXIF
    /// orientation, so that is done here as a transform.
    private nonisolated static func decodeFull(url: URL) -> Thumbnail? {
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ), CGImageSourceGetCount(source) > 0 else { return nil }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let orientation = (properties[kCGImagePropertyOrientation] as? UInt32) ?? 1

        // A decoded bitmap is four bytes per pixel. Past this ceiling the file is
        // scaled instead, so a 100 MP scan cannot exhaust memory; everything a
        // normal camera produces stays a whole-image decode.
        let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let longestEdge = max(pixelWidth, pixelHeight)
        if longestEdge > Self.directDecodeCeiling {
            return decode(url: url, maxPixel: Self.directDecodeCeiling)
        }

        // Eager: the bitmap is wanted now, and a lazy decode would only move the
        // cost onto the drawing pass.
        guard let image = CGImageSourceCreateImageAtIndex(
            source, 0,
            [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        ) else { return nil }

        guard orientation != 1, let rotated = applyOrientation(orientation, to: image) else {
            return Thumbnail(
                image: image,
                pixelSize: CGSize(width: image.width, height: image.height)
            )
        }
        return Thumbnail(
            image: rotated,
            pixelSize: CGSize(width: rotated.width, height: rotated.height)
        )
    }

    /// Apply an EXIF orientation to a decoded image.
    private nonisolated static func applyOrientation(_ orientation: UInt32, to image: CGImage) -> CGImage? {
        let swapsAxes = orientation >= 5
        let width = swapsAxes ? image.height : image.width
        let height = swapsAxes ? image.width : image.height

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Place the image so that the transform below lands it correctly.
        var transform = CGAffineTransform.identity
        switch orientation {
        case 2: transform = CGAffineTransform(translationX: CGFloat(width), y: 0).scaledBy(x: -1, y: 1)
        case 3: transform = CGAffineTransform(translationX: CGFloat(width), y: CGFloat(height)).scaledBy(x: -1, y: -1)
        case 4: transform = CGAffineTransform(translationX: 0, y: CGFloat(height)).scaledBy(x: 1, y: -1)
        case 5: transform = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case 6: transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(width), ty: 0)
        case 7: transform = CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: CGFloat(width), ty: CGFloat(height))
        case 8: transform = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: CGFloat(height))
        default: transform = .identity
        }

        context.concatenate(transform)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

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
