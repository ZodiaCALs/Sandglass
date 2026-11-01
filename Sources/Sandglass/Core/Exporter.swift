import Foundation

/// What happens to the originals after an export.
enum ExportMode: String, CaseIterable, Sendable, Codable {
    case copy
    case move

    var label: String {
        switch self {
        case .copy: "Copy"
        case .move: "Move"
        }
    }

    var help: String {
        switch self {
        case .copy: "Originals stay where they are."
        case .move: "Originals are removed from the source folder."
        }
    }
}

/// Exactly which files an export will touch, worked out before anything is written.
struct ExportPlan: Sendable, Equatable {
    /// Files to write, in shot order.
    var files: [URL]
    /// Total size of those files, for the confirmation sheet.
    var totalBytes: Int64
    var shotCount: Int

    var isEmpty: Bool { files.isEmpty }
}

/// What an export actually did.
struct ExportResult: Sendable, Equatable {
    var copied = 0
    var moved = 0
    var skipped = 0
    var failures: [String] = []
    var wasCancelled = false

    var summary: String {
        var parts: [String] = []
        if copied > 0 { parts.append("\(copied) copied") }
        if moved > 0 { parts.append("\(moved) moved") }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        if !failures.isEmpty { parts.append("\(failures.count) failed") }
        if wasCancelled { parts.append("cancelled") }
        return parts.isEmpty ? "Nothing to do" : parts.joined(separator: ", ")
    }
}

/// Copies (or moves) the flagged variants of each shot into a destination folder.
///
/// Nothing is ever overwritten: a name collision becomes `DSC_0001 2.NEF`.
enum Exporter {

    /// Work out which files an export would write, without touching the disk
    /// beyond reading file sizes.
    static func plan(shots: [Shot], flags: [Shot.ID: FlagSelection]) -> ExportPlan {
        var files: [URL] = []
        var bytes: Int64 = 0
        var shotCount = 0

        for shot in shots {
            guard let selection = flags[shot.id], !selection.isEmpty else { continue }
            var contributed = false
            for kind in selection.kinds {
                guard let url = shot.url(for: kind) else { continue }
                files.append(url)
                bytes += fileSize(url) ?? 0
                contributed = true
            }
            if contributed { shotCount += 1 }
        }
        return ExportPlan(files: files, totalBytes: bytes, shotCount: shotCount)
    }

    /// Run the export off the calling actor.
    ///
    /// Same-volume copies are APFS clones and finish instantly; large cross-volume
    /// copies no longer freeze the interface because nothing here runs on the
    /// main thread. `progress` is called after every file, from a background
    /// context. Cancelling the surrounding task stops between files.
    @concurrent
    static func run(
        files: [URL],
        destination: URL,
        mode: ExportMode,
        progress: @escaping @Sendable (_ done: Int, _ total: Int) -> Void = { _, _ in }
    ) async -> ExportResult {
        var result = ExportResult()
        let fileManager = FileManager.default

        #if os(macOS)
        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
        #endif

        do {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            result.failures.append("Could not create the destination: \(error.localizedDescription)")
            return result
        }

        let total = files.count
        let target = destination.standardizedFileURL
        for (index, source) in files.enumerated() {
            if Task.isCancelled {
                result.wasCancelled = true
                break
            }
            // Exporting into the folder a file already lives in would only make a copy
            // of it next to itself (or move it nowhere), so it is skipped.
            if source.deletingLastPathComponent().standardizedFileURL == target {
                result.skipped += 1
                progress(index + 1, total)
                continue
            }
            let output = uniqueDestination(for: source, in: destination)
            do {
                switch mode {
                case .copy:
                    try fileManager.copyItem(at: source, to: output)
                    result.copied += 1
                case .move:
                    try fileManager.moveItem(at: source, to: output)
                    result.moved += 1
                }
            } catch {
                result.failures.append("\(source.lastPathComponent): \(error.localizedDescription)")
            }
            progress(index + 1, total)
        }
        return result
    }

    /// A non-colliding destination, appending " 2", " 3", … when needed.
    static func uniqueDestination(for source: URL, in folder: URL) -> URL {
        let fileManager = FileManager.default
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var candidate = folder.appendingPathComponent(source.lastPathComponent)
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = folder.appendingPathComponent(name)
            counter += 1
        }
        return candidate
    }

    static func fileSize(_ url: URL) -> Int64? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return nil }
        return Int64(size)
    }
}
