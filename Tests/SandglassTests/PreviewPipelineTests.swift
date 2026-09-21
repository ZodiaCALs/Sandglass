import Testing
import Foundation
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

    @Test("The preview resolves for every photo stepped through")
    func previewResolvesForEveryShot() async throws {
        let model = try await loadedModel()

        for (position, shot) in model.shots.enumerated() {
            model.go(to: position)
            let resolved = await waitUntil {
                model.previewState(for: shot, kind: model.kind) == .ready
            }
            #expect(resolved, "\(shot.baseName) never produced a preview")

            // And it must be the dedicated preview decode, not a neighbour
            // prefetch standing in for one.
            let isFullPreview = await waitUntil {
                model.hasFullResolutionPreview(for: shot, kind: model.kind)
            }
            #expect(isFullPreview, "\(shot.baseName) never reached full resolution")
        }
    }

    @Test("Changing the pane size re-decodes at the new budget")
    func budgetChangeReDecodes() async throws {
        let model = try await loadedModel()
        let shot = try #require(model.shots.first { $0.jpgURL != nil })
        model.go(to: try #require(model.shots.firstIndex(of: shot)))

        let firstBudget = model.previewPixelBudget
        let firstReady = await waitUntil { model.hasFullResolutionPreview(for: shot, kind: .jpg) }
        #expect(firstReady)

        // A much larger pane must invalidate the smaller decode.
        model.reportCanvasSize(CGSize(width: 1600, height: 1200))
        #expect(model.previewPixelBudget > firstBudget, "budget should grow with the pane")

        let reDecoded = await waitUntil {
            model.hasFullResolutionPreview(for: shot, kind: .jpg)
                && model.previewCGImage(for: shot, kind: .jpg) != nil
        }
        #expect(reDecoded, "preview should be refreshed after the pane grew")
    }

    @Test("A bigger pane yields a bigger bitmap")
    func biggerPaneYieldsMorePixels() async throws {
        let model = try await loadedModel()
        let shot = try #require(model.shots.first { $0.jpgURL != nil })
        model.go(to: try #require(model.shots.firstIndex(of: shot)))
        _ = await waitUntil { model.hasFullResolutionPreview(for: shot, kind: .jpg) }

        // A small pane asks for few pixels.
        model.reportCanvasSize(CGSize(width: 420, height: 340))
        let smallReady = await waitUntil { model.hasFullResolutionPreview(for: shot, kind: .jpg) }
        #expect(smallReady, "small pane should settle")
        let small = try #require(model.previewCGImage(for: shot, kind: .jpg))
        #expect(small.width <= model.previewPixelBudget, "decode should respect the budget")

        // A large pane must produce a genuinely bigger bitmap.
        model.reportCanvasSize(CGSize(width: 1400, height: 1100))
        let grew = await waitUntil {
            model.hasFullResolutionPreview(for: shot, kind: .jpg)
                && (model.previewCGImage(for: shot, kind: .jpg)?.width ?? 0) > small.width
        }
        #expect(grew, "a larger pane should decode a larger bitmap")
    }
}
