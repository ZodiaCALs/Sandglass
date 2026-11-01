import Testing
import Foundation
import AppKit
@testable import Sandglass

/// The photo canvas, measured by rendering its layer tree — what reaches the
/// screen — rather than trusting that it looks right.
@Suite("Photo canvas")
@MainActor
struct CanvasTests {

    private func checkerboard(side: Int, cell: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        for y in stride(from: 0, to: side, by: cell) {
            for x in stride(from: 0, to: side, by: cell) {
                context.setFillColor(gray: ((x / cell) + (y / cell)) % 2 == 0 ? 1 : 0, alpha: 1)
                context.fill(CGRect(x: x, y: y, width: cell, height: cell))
            }
        }
        return context.makeImage()!
    }

    private func solid(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private struct Render {
        let grey: [UInt8]
        let width: Int
        let height: Int
    }

    /// Render through the layer tree. Row 0 of the output is the bottom of the view.
    private func render(_ canvas: ImageCanvasView) -> Render? {
        let width = Int(canvas.bounds.width)
        let height = Int(canvas.bounds.height)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .none
        canvas.layer?.render(in: context)
        guard let image = context.makeImage() else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let grey = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        grey.interpolationQuality = .none
        grey.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Render(grey: pixels, width: width, height: height)
    }

    private func runs(_ render: Render, row: Int) -> [Int] {
        var lengths: [Int] = []
        var current = render.grey[row * render.width] > 127
        var length = 1
        for x in 1..<render.width {
            let on = render.grey[row * render.width + x] > 127
            if on == current { length += 1 } else { lengths.append(length); current = on; length = 1 }
        }
        lengths.append(length)
        return lengths
    }

    private func makeCanvas(_ size: CGSize) -> ImageCanvasView {
        let canvas = ImageCanvasView(frame: CGRect(origin: .zero, size: size))
        canvas.viewDidChangeBackingProperties()
        return canvas
    }

    @Test("Magnifying real pixels is exact: runs scale by the zoom with no smoothing")
    func zoomIsPixelExact() throws {
        let cell = 3
        let side = 300
        let canvas = makeCanvas(CGSize(width: side, height: side))
        canvas.setImage(checkerboard(side: side, cell: cell), allPixels: true, resetFraming: true)
        for zoom in [1, 2, 3, 4] {
            canvas.zoom(to: CGFloat(zoom), animated: false)
            let output = try #require(render(canvas))
            #expect(output.grey.filter { $0 > 40 && $0 < 215 }.isEmpty, "zoom \(zoom)x was smoothed")
            let interior = runs(output, row: side / 2).dropFirst().dropLast()
            #expect(interior.allSatisfy { $0 == cell * zoom }, "zoom \(zoom)x: \(Array(interior.prefix(6)))")
        }
    }

    @Test("Fit keeps the aspect ratio and letterboxes")
    func aspectFit() throws {
        let canvas = makeCanvas(CGSize(width: 300, height: 300))
        canvas.setImage(solid(width: 400, height: 100), allPixels: true, resetFraming: true)
        let output = try #require(render(canvas))
        #expect((0..<output.width).allSatisfy { output.grey[10 * output.width + $0] < 20 }, "letterbox above/below")
        #expect((0..<output.width).allSatisfy { output.grey[150 * output.width + $0] > 235 }, "photo in the middle band")
    }

    @Test("Replacing the bitmap with a sharper one mid-zoom does not move the photo")
    func sharperBitmapKeepsFraming() {
        let canvas = makeCanvas(CGSize(width: 800, height: 600))
        let logical = CGSize(width: 2400, height: 1600)
        canvas.setImage(solid(width: 600, height: 400), logicalSize: logical, allPixels: false, resetFraming: true)
        canvas.zoom(to: 3.5, anchor: CGPoint(x: 650, y: 120), animated: false)
        let before = canvas.imageContentsLayer.frame
        let region = canvas.viewport.visibleRegion

        canvas.setImage(solid(width: 2400, height: 1600), logicalSize: logical, allPixels: true, resetFraming: false)
        let after = canvas.imageContentsLayer.frame
        #expect(abs(after.minX - before.minX) < 0.75 && abs(after.minY - before.minY) < 0.75, "\(before) → \(after)")
        #expect(abs(after.width - before.width) < 0.75)
        #expect(canvas.viewport.visibleRegion == region)
        #expect(canvas.showsAllPixels)
    }

    @Test("A new photo starts at fit, centred")
    func newPhotoResets() {
        let canvas = makeCanvas(CGSize(width: 800, height: 600))
        canvas.setImage(solid(width: 600, height: 600), allPixels: true, resetFraming: true)
        canvas.zoom(to: 4, anchor: CGPoint(x: 10, y: 10), animated: false)
        canvas.setImage(solid(width: 600, height: 600), allPixels: true, resetFraming: true)
        #expect(canvas.viewport.zoom == 1)
        #expect(canvas.viewport.centre == CGPoint(x: 0.5, y: 0.5))
    }

    @Test("Resizing the pane while zoomed keeps the magnification and the centre")
    func resizeKeepsFraming() {
        let canvas = makeCanvas(CGSize(width: 800, height: 600))
        canvas.setImage(solid(width: 3000, height: 2000), allPixels: true, resetFraming: true)
        canvas.zoomToActualPixels(anchor: CGPoint(x: 600, y: 200))
        let magnification = canvas.viewport.pixelMagnification
        let centre = canvas.viewport.centre
        for _ in 0..<30 {
            canvas.setFrameSize(NSSize(width: 520, height: 600))   // e.g. the inspector opens
            canvas.setFrameSize(NSSize(width: 1100, height: 760))
        }
        canvas.setFrameSize(NSSize(width: 800, height: 600))
        #expect(abs(canvas.viewport.pixelMagnification - magnification) < 0.0001)
        #expect(abs(canvas.viewport.centre.x - centre.x) < 0.0001 && abs(canvas.viewport.centre.y - centre.y) < 0.0001)
    }

    @Test("Every change of framing is reported, including the last one")
    func viewportReports() {
        let canvas = makeCanvas(CGSize(width: 800, height: 600))
        var regions: [CGRect] = []
        canvas.onViewportChange = { regions.append($0.viewport.visibleRegion) }
        canvas.setImage(solid(width: 600, height: 600), allPixels: true, resetFraming: true)
        for step in 1...20 {
            canvas.zoom(to: 1 + CGFloat(step) * 0.2, anchor: CGPoint(x: 600, y: 450), animated: false)
        }
        #expect(regions.count >= 21, "the navigator sees every frame")
        #expect((regions.last?.width ?? 1) < 0.5)
        canvas.zoomToFit()
        #expect(regions.last == CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    @Test("The photo can never be panned out of view")
    func panningStaysInBounds() {
        let canvas = makeCanvas(CGSize(width: 800, height: 600))
        canvas.setImage(solid(width: 600, height: 600), allPixels: true, resetFraming: true)
        canvas.zoom(to: 2, animated: false)
        canvas.centre(on: CGPoint(x: 1, y: 1))
        let region = canvas.viewport.visibleRegion
        #expect(region.maxX <= 1.0001 && region.maxY <= 1.0001)
        canvas.centre(on: CGPoint(x: -3, y: -3))
        #expect(canvas.viewport.visibleRegion.minX >= -0.0001)
    }
}

@Suite("Preview pipeline")
@MainActor
struct PreviewPipelineTests {

    private func waitUntil(timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(15))
        }
        return condition()
    }

    private func shot(_ name: String) throws -> Shot {
        try #require(try FolderScanner.scan(folder: Fixtures.sampleShoot).first { $0.baseName == name })
    }

    @Test("A screen-sized rendition comes first, every pixel when zooming asks for it")
    func displayThenFull() async throws {
        let store = PreviewStore()
        store.preloadFullResolution = false
        store.updatePane(size: CGSize(width: 400, height: 300), backingScale: 1)
        let photo = try shot("DSC_0010")
        store.show(photo, kind: .jpg, compare: false, next: [])
        #expect(await waitUntil { store.primary?.status == .ready })
        let display = try #require(store.primary?.display)
        #expect(display.longEdge == store.displayPixels)
        #expect(!display.isFullResolution)
        #expect(store.primary?.full == nil, "nothing more is decoded until it is needed")

        store.requestFullResolution()
        #expect(await waitUntil { store.primary?.full != nil })
        #expect(store.primary?.full?.longEdge == 1600)
        #expect(store.primary?.hasAllPixels == true)
        #expect(await waitUntil { !store.isLoadingFullResolution })
    }

    @Test("Neighbours are prepared in the background")
    func prefetchesNeighbours() async throws {
        let store = PreviewStore()
        store.preloadFullResolution = false
        let first = try shot("DSC_0001")
        let next = try shot("DSC_0002")
        store.show(first, kind: .jpg, compare: false, next: [try #require(next.jpgURL)])
        #expect(await waitUntil { store.cachedDisplayCount == 2 })
        store.show(next, kind: .jpg, compare: false, next: [])
        #expect(store.primary?.status == .ready, "the neighbour is on screen instantly")
    }

    @Test("Missing variants and undecodable files are reported, not spun on")
    func states() async throws {
        let store = PreviewStore()
        store.show(try shot("DSC_0006"), kind: .nef, compare: false, next: [])
        #expect(store.primary?.status == .missing)

        store.show(try shot("DSC_0001"), kind: .nef, compare: false, next: [])
        #expect(await waitUntil { store.primary?.status == .unavailable })
    }

    @Test("Compare shows both variants of the photo")
    func compare() async throws {
        let store = PreviewStore()
        store.preloadFullResolution = false
        let photo = try shot("DSC_0008")
        store.show(photo, kind: .jpg, compare: true, next: [])
        #expect(store.secondary?.kind == .nef)
        #expect(await waitUntil { store.primary?.status == .ready && store.secondary?.status == .ready })
    }

    @Test("Thumbnails are small, cached, and shared between requests")
    func thumbnails() async throws {
        let store = ThumbnailStore()
        let url = Fixtures.sample("DSC_0010.JPG")
        // Two requests at once share one decode.
        let other = Task { await store.image(for: url, pixels: 200) != nil }
        let image = try #require(await store.image(for: url, pixels: 200))
        #expect(max(image.width, image.height) <= ThumbnailStore.bucket(for: 200))
        #expect(await other.value)
        #expect(store.cachedImage(for: url, pixels: 200) != nil)
        #expect(await store.image(for: Fixtures.sample("DSC_0001.NEF"), pixels: 200) == nil)
        #expect(store.hasFailed(Fixtures.sample("DSC_0001.NEF")))
    }
}
