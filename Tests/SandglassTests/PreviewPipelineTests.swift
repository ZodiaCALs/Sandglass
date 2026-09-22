import Testing
import Foundation
import ImageIO
@testable import Sandglass

/// Guards the single request path that feeds the large preview.
///
/// A previous design asked for the current photo twice at the same resolution —
/// once as a neighbour prefetch, once as the detail request. The loader coalesced
/// the two identical decodes, the inner request ended up awaiting the outer one,
/// and the pane sat on its loading state forever. The prefetch-based checks did
/// not catch it because the prefetch alone made them look satisfied.
@Suite("Preview request path")
@MainActor
struct PreviewRequestPathTests {

    private var fixtureFolder: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/SampleShoot")
    }

    private func loadedModel() async throws -> LibraryModel {
        let model = LibraryModel()
        model.openFolder(at: fixtureFolder)
        for _ in 0..<300 where model.isScanning {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        try #require(!model.shots.isEmpty, "fixtures should load")
        return model
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    @Test("Every photo reaches a definite state, and decodable ones show the whole file")
    func everyShotResolves() async throws {
        let model = try await loadedModel()
        var decoded = 0
        var undecodable = 0

        for (position, shot) in model.shots.enumerated() {
            model.go(to: position)

            // Settle into either a rendered image or an explicit "unavailable" —
            // never a state that hangs.
            let settled = await waitUntil(timeout: 8) {
                let state = model.previewState(for: shot, kind: model.kind)
                return state == .ready || state == .unavailable
            }
            let state = model.previewState(for: shot, kind: model.kind)
            #expect(settled, "\(shot.baseName) never settled (stuck at \(state))")

            if state == .unavailable {
                // Some fixtures are placeholder raws ImageIO cannot decode. That
                // must be reported, not papered over with a smaller bitmap.
                undecodable += 1
                continue
            }

            decoded += 1
            let whole = await waitUntil(timeout: 8) {
                model.hasFullResolutionPreview(for: shot, kind: model.kind)
            }
            #expect(whole, "\(shot.baseName) rendered a proxy instead of the whole file")
        }

        #expect(decoded > 0, "at least some fixtures should decode")
        // The synthetic raws are expected to be undecodable; the JPEGs are not.
        #expect(undecodable <= 4, "unexpected number of undecodable files: \(undecodable)")
    }

    /// Native pixel size of a file, straight from its metadata.
    private func nativeSize(_ url: URL) -> Int? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return max(width, height)
    }

    @Test("The preview is decoded at the file's own resolution, not a downscale")
    func previewIsNativeResolution() async throws {
        let model = try await loadedModel()
        let shot = try #require(model.shots.first { $0.jpgURL != nil })
        let url = try #require(shot.jpgURL)
        let native = try #require(nativeSize(url), "fixture should report its size")

        model.go(to: try #require(model.shots.firstIndex(of: shot)))
        let ready = await waitUntil { model.hasFullResolutionPreview(for: shot, kind: .jpg) }
        #expect(ready, "preview should resolve")

        let image = try #require(model.previewCGImage(for: shot, kind: .jpg))
        // A downscaled proxy loses fine detail; the pane must get the real pixels.
        #expect(
            image.width == native,
            "expected native \(native)px, got \(image.width)px — the preview is a downscale"
        )
    }

    @Test("Resizing the pane keeps the preview at native resolution")
    func resizeKeepsNativeResolution() async throws {
        let model = try await loadedModel()
        let shot = try #require(model.shots.first { $0.jpgURL != nil })
        let url = try #require(shot.jpgURL)
        let native = try #require(nativeSize(url))

        model.go(to: try #require(model.shots.firstIndex(of: shot)))
        _ = await waitUntil { model.hasFullResolutionPreview(for: shot, kind: .jpg) }

        // Shrinking then growing the pane must not leave a smaller decode behind.
        model.reportCanvasSize(CGSize(width: 420, height: 340))
        _ = await waitUntil { model.previewCGImage(for: shot, kind: .jpg) != nil }
        model.reportCanvasSize(CGSize(width: 1400, height: 1100))
        let settled = await waitUntil {
            model.previewCGImage(for: shot, kind: .jpg)?.width == native
        }
        let image = try #require(model.previewCGImage(for: shot, kind: .jpg))
        #expect(settled, "expected native \(native)px after resize, got \(image.width)px")
    }

    /// Pixel size of what actually decodes from a file.
    ///
    /// Metadata can advertise more than the file really contains — this NEF
    /// embeds only a small preview — so this is the honest reference.
    private func decodableSize(_ url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                  // Same orientation handling as the app, so dimensions are compared
                  // in the same orientation.
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: ThumbnailLoader.nativeRequest
              ] as CFDictionary) else { return nil }
        return CGSize(width: image.width, height: image.height)
    }

    @Test("JPG and NEF of the same shot are decoded as separate files")
    func variantsAreDistinctFiles() async throws {
        let model = try await loadedModel()

        // Use a shot whose NEF actually contains a decodable image. Most of the
        // synthetic fixtures are placeholder TIFFs that ImageIO refuses (see the
        // "NEF whose preview cannot be decoded" test); DSC_0008 carries a real one.
        let paired = try #require(
            model.shots.first { $0.isPaired && $0.baseName == "DSC_0008" },
            "expected the real-NEF fixture"
        )
        let position = try #require(model.shots.firstIndex(of: paired))
        let jpgURL = try #require(paired.jpgURL)
        let nefURL = try #require(paired.nefURL)
        #expect(jpgURL != nefURL, "the two variants are different files on disk")
        #expect(jpgURL.pathExtension != nefURL.pathExtension)

        model.go(to: position)
        model.setKind(.jpg)
        let jpgReady = await waitUntil { model.hasFullResolutionPreview(for: paired, kind: .jpg) }
        #expect(jpgReady, "the JPG should decode")
        let jpg = try #require(model.previewCGImage(for: paired, kind: .jpg))

        // Switching variant must decode the NEF as its own file, not reuse the JPG.
        model.setKind(.nef)
        let nefReady = await waitUntil { model.hasFullResolutionPreview(for: paired, kind: .nef) }
        #expect(nefReady, "switching variant must decode the NEF as its own file")

        let nef = try #require(model.previewCGImage(for: paired, kind: .nef))

        // Each variant reflects its own file, at the full size that file can give.
        let expectedJPG = try #require(decodableSize(jpgURL))
        let expectedNEF = try #require(decodableSize(nefURL))
        #expect(
            CGSize(width: jpg.width, height: jpg.height) == expectedJPG,
            "JPG preview should match its own file"
        )
        #expect(
            CGSize(width: nef.width, height: nef.height) == expectedNEF,
            "NEF preview should match its own file"
        )
        // And they are genuinely different images, not one standing in for the other.
        #expect(
            CGSize(width: jpg.width, height: jpg.height) != CGSize(width: nef.width, height: nef.height),
            "the two variants should not be the same bitmap"
        )
    }
}
