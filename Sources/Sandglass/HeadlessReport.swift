import Foundation
import ImageIO

/// Runs the full scan → flag → export path without a user interface.
///
/// Invoked with `Sandglass --report <folder>`. It prints what it found and what
/// it exported, then exits non-zero if anything did not behave. This exercises
/// the same model and exporter the UI drives, so it doubles as a smoke test on
/// a real photo folder.
enum HeadlessReport {

    /// Measure cold decode cost at each size the app actually requests.
    ///
    /// Invoked with `Sandglass --bench <folder>`. Useful for checking that a
    /// preview budget really is affordable on a given machine.
    @MainActor
    static func bench(folder: URL) -> Never {
        setvbuf(stdout, nil, _IONBF, 0)

        let shots: [Shot]
        do {
            shots = try FolderScanner.scan(folder: folder)
        } catch {
            print("FAIL: \(error.localizedDescription)")
            exit(1)
        }

        let samples = Array(shots.prefix(6))
        guard !samples.isEmpty else {
            print("FAIL: no shots found in \(folder.path)")
            exit(1)
        }

        print("Benchmarking \(samples.count) file(s) from \(folder.lastPathComponent)")
        print("")
        print(pad("FILE", 22) + pad("NATIVE", 12) + pad("REQUEST", 10) + pad("RESULT", 12) + "MS")

        for shot in samples {
            for variant in shot.availableKinds {
                guard let url = shot.url(for: variant) else { continue }
                let native = nativePixelSize(url).map { "\($0.width)x\($0.height)" } ?? "?"
                for request in [320, 1400, 2000, 3200] {
                    // Purge between runs so every decode is cold.
                    let elapsed = measure {
                        Task { await ThumbnailLoader.shared.purge() }
                        let done = DispatchSemaphore(value: 0)
                        var result: Thumbnail?
                        Task {
                            result = await ThumbnailLoader.shared.thumbnail(for: url, maxPixel: request)
                            done.signal()
                        }
                        while done.wait(timeout: .now() + 0.01) == .timedOut {
                            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                        }
                        return result.map { "\($0.image.width)x\($0.image.height)" } ?? "nil"
                    }
                    print(pad(url.lastPathComponent, 22)
                          + pad(native, 12)
                          + pad("\(request)", 10)
                          + pad(elapsed.value, 12)
                          + String(format: "%.1f", elapsed.milliseconds))
                }
            }
        }

        print("")
        print("PASS")
        exit(0)
    }

    /// Time a closure that spins the run loop, returning its value and duration.
    @MainActor
    private static func measure(_ body: () -> String) -> (value: String, milliseconds: Double) {
        let start = Date()
        let value = body()
        return (value, Date().timeIntervalSince(start) * 1000)
    }

    /// Native pixel dimensions reported by ImageIO.
    private static func nativePixelSize(_ url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    @MainActor
    static func run(folder: URL) -> Never {
        // Unbuffered so the report survives the immediate exit below.
        setvbuf(stdout, nil, _IONBF, 0)

        let model = LibraryModel()
        model.openFolder(at: folder)

        // Let pending main-actor work (the scan) actually run.
        let deadline = Date().addingTimeInterval(60)
        while model.isScanning && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }

        if let error = model.errorMessage {
            print("FAIL: \(error)")
            exit(1)
        }

        let shots = model.shots
        guard !shots.isEmpty else {
            print("FAIL: no shots found in \(folder.path)")
            exit(1)
        }

        print("Folder: \(folder.path)")
        print("Shots:  \(shots.count)")
        print("")
        print(pad("NAME", 18) + pad("PAIR", 12) + "FILES")
        for shot in shots {
            let files = shot.availableKinds.map(\.label).joined(separator: " + ")
            print(pad(shot.baseName, 18) + pad(shot.variantSummary, 12) + files)
        }

        // Exercise all three flag rules on real files: JPG only, NEF only, and both.
        func flag(_ shot: Shot, _ selection: FlagSelection) {
            guard let position = shots.firstIndex(of: shot) else { return }
            model.go(to: position)
            model.setFlag(selection, for: shot.id)
        }
        if let jpgShot = shots.first(where: { $0.jpgURL != nil && $0.nefURL != nil }) {
            flag(jpgShot, .jpg)
        }
        if let nefOnly = shots.first(where: { $0.nefURL != nil && $0.jpgURL == nil }) {
            flag(nefOnly, .nef)
        }
        if let paired = shots.last(where: { $0.isPaired && model.flagFor($0).isEmpty }) {
            flag(paired, [.jpg, .nef])
        }

        let plan = Exporter.plan(shots: shots, flags: model.flags)
        print("")
        print("Flagged \(model.flaggedCount) shot(s) → \(plan.files.count) file(s)")
        for url in plan.files {
            print("  \(url.lastPathComponent)")
        }
        // Export into a temporary folder and report exactly what landed.
        let destination = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sandglass-report-\(UUID().uuidString)")
        let semaphore = DispatchSemaphore(value: 0)
        var result = Exporter.Result()

        Task {
            result = await Exporter.run(files: plan.files, destination: destination, mode: .copy) { _, _ in }
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now() + 0.02) == .timedOut {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }

        let written = (try? FileManager.default.contentsOfDirectory(atPath: destination.path).sorted()) ?? []
        print("")
        print("Exported to: \(destination.path)")
        print("Result:      \(result.summary)")
        for name in written { print("  \(name)") }

        try? FileManager.default.removeItem(at: destination)

        let ok = result.failures.isEmpty && written.count == plan.files.count
        print("")
        print(ok ? "PASS" : "FAIL: exported \(written.count) of \(plan.files.count) file(s)")
        if !result.failures.isEmpty {
            for failure in result.failures { print("  ! \(failure)") }
        }
        exit(ok ? 0 : 1)
    }

    /// Left-align `text` in a fixed-width column for the plain-text table.
    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text + " " : text.padding(toLength: width, withPad: " ", startingAt: 0)
    }
}
