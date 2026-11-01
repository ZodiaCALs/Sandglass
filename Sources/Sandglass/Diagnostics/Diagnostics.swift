import Foundation

/// Command-line checks that report facts rather than impressions.
///
///     Sandglass --report  <folder>   scan → flag → export to a temporary folder, verify
///     Sandglass --inspect <folder>   what each file decodes to, from where, how fast
///     Sandglass --bench   <folder>   cold decode times at the sizes the app requests
@MainActor
enum Diagnostics {

    /// Runs the diagnostic named in `arguments`, returning its exit status — or
    /// nil when none was asked for.
    static func run(arguments: [String]) -> Int32? {
        func folder(after flag: String) -> URL? {
            guard let index = arguments.firstIndex(of: flag), arguments.index(after: index) < arguments.endIndex else {
                return nil
            }
            let path = (arguments[arguments.index(after: index)] as NSString).expandingTildeInPath
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        if let url = folder(after: "--report") { return report(folder: url) }
        if let url = folder(after: "--inspect") { return inspect(folder: url) }
        if let url = folder(after: "--bench") { return bench(folder: url) }
        return nil
    }

    // MARK: --report

    static func report(folder: URL) -> Int32 {
        setvbuf(stdout, nil, _IONBF, 0)
        return wait {
            let library = Library()
            do {
                try await library.open(folder: folder)
            } catch {
                print("FAIL: \(error.localizedDescription)")
                return 1
            }
            print("Folder: \(folder.path)")
            print("Shots:  \(library.count)\n")
            print(pad("NAME", 20) + pad("PAIR", 12) + "FILES")
            for shot in library.shots {
                print(pad(shot.displayName, 20) + pad(shot.variantSummary, 12) + shot.availableKinds.map(\.label).joined(separator: " + "))
            }

            // The three flag rules on real files: JPG only, NEF only, both.
            if let index = library.shots.firstIndex(where: \.isPaired) {
                library.flagOnly(.jpg, at: index)
            }
            if let index = library.shots.firstIndex(where: { $0.nefURL != nil && $0.jpgURL == nil }) {
                library.flagOnly(.nef, at: index)
            }
            if let index = library.shots.lastIndex(where: { $0.isPaired && library.selection(for: $0).isEmpty }) {
                library.toggleFlagBoth(at: index)
            }

            let plan = library.exportPlan()
            print("\nFlagged \(library.flaggedShotCount) shot(s) → \(plan.files.count) file(s)")
            for url in plan.files { print("  \(url.lastPathComponent)") }

            let destination = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("sandglass-report-\(UUID().uuidString)", isDirectory: true)
            let result = await Exporter.run(files: plan.files, destination: destination, mode: .copy)
            let written = (try? FileManager.default.contentsOfDirectory(atPath: destination.path).sorted()) ?? []
            print("\nExported to: \(destination.path)")
            print("Result:      \(result.summary)")
            for name in written { print("  \(name)") }
            try? FileManager.default.removeItem(at: destination)

            let ok = result.failures.isEmpty && written.count == plan.files.count
            print(ok ? "\nPASS" : "\nFAIL: exported \(written.count) of \(plan.files.count) file(s)")
            for failure in result.failures { print("  ! \(failure)") }
            return ok ? 0 : 1
        }
    }

    // MARK: --inspect

    static func inspect(folder: URL) -> Int32 {
        setvbuf(stdout, nil, _IONBF, 0)
        let shots: [Shot]
        do {
            shots = try FolderScanner.scan(folder: folder)
        } catch {
            print("FAIL: \(error.localizedDescription)")
            return 1
        }
        print(pad("FILE", 22) + pad("SOURCE", 13) + pad("SCREEN", 13) + pad("MS", 7) + pad("FULL", 13) + pad("MS", 7) + "FROM")
        var undecodable = 0
        for shot in shots.prefix(12) {
            for kind in shot.availableKinds {
                guard let url = shot.url(for: kind) else { continue }
                let source = ImageDecoder.pixelSize(of: url).map { "\(Int($0.width))x\(Int($0.height))" } ?? "?"
                let (display, displayMS) = time { ImageDecoder.display(url: url, maxPixel: 2560) }
                let (full, fullMS) = time { ImageDecoder.fullResolution(url: url, allowRawDecode: true) }
                if display == nil { undecodable += 1 }
                print(pad(url.lastPathComponent, 22)
                      + pad(source, 13)
                      + pad(display.map { size($0) } ?? "—", 13) + pad(String(format: "%.0f", displayMS), 7)
                      + pad(full.map { size($0) } ?? "—", 13) + pad(String(format: "%.0f", fullMS), 7)
                      + (full?.origin.label ?? display?.origin.label ?? "no preview"))
            }
        }
        print("\n\(undecodable) file(s) had no decodable image.")
        print("PASS")
        return 0
    }

    // MARK: --bench

    static func bench(folder: URL) -> Int32 {
        setvbuf(stdout, nil, _IONBF, 0)
        let shots: [Shot]
        do {
            shots = try FolderScanner.scan(folder: folder)
        } catch {
            print("FAIL: \(error.localizedDescription)")
            return 1
        }
        print(pad("FILE", 22) + pad("THUMB 384", 12) + pad("SCREEN 1600", 13) + pad("SCREEN 2560", 13) + "FULL")
        for shot in shots.prefix(8) {
            for kind in shot.availableKinds {
                guard let url = shot.url(for: kind) else { continue }
                let thumb = time { ImageDecoder.thumbnail(url: url, maxPixel: 384) }.1
                let small = time { ImageDecoder.display(url: url, maxPixel: 1600) }.1
                let large = time { ImageDecoder.display(url: url, maxPixel: 2560) }.1
                let full = time { ImageDecoder.fullResolution(url: url, allowRawDecode: false) }.1
                print(pad(url.lastPathComponent, 22)
                      + pad(String(format: "%.1f ms", thumb), 12)
                      + pad(String(format: "%.1f ms", small), 13)
                      + pad(String(format: "%.1f ms", large), 13)
                      + String(format: "%.1f ms", full))
            }
        }
        print("PASS")
        return 0
    }

    // MARK: Helpers

    private static func size(_ image: DecodedImage) -> String {
        "\(image.cgImage.width)x\(image.cgImage.height)"
    }

    private static func time<T>(_ body: () -> T) -> (T, Double) {
        let start = DispatchTime.now().uptimeNanoseconds
        let value = body()
        return (value, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }

    /// Run async work from the synchronous entry point, spinning the main run
    /// loop so main-actor work can proceed.
    private static func wait(_ body: @escaping @MainActor @Sendable () async -> Int32) -> Int32 {
        let box = StatusBox()
        Task { @MainActor in
            box.status = await body()
        }
        while box.status == nil {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        return box.status ?? 1
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text + " " : text.padding(toLength: width, withPad: " ", startingAt: 0)
    }
}

@MainActor
private final class StatusBox {
    var status: Int32?
}
