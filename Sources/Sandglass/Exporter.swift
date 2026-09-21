import Foundation
import AppKit

/// Copies (or moves) the flagged variants of each shot into a destination folder.
enum Exporter {

    enum Mode: String, CaseIterable, Sendable {
        case copy
        case move

        var label: String {
            switch self {
            case .copy: return "Copy"
            case .move: return "Move"
            }
        }

        var help: String {
            switch self {
            case .copy: return "Leave originals in the source folder"
            case .move: return "Remove originals from the source folder"
            }
        }
    }

    struct Plan {
        /// Files that will be written, in shot order.
        let files: [URL]
        /// Total bytes of those files, for the confirmation UI.
        let totalBytes: Int64
        let shotCount: Int

        var isEmpty: Bool { files.isEmpty }
    }

    struct Result: Sendable {
        var copied: Int = 0
        var moved: Int = 0
        var skipped: Int = 0
        var failures: [String] = []

        var summary: String {
            var parts: [String] = []
            if copied > 0 { parts.append("\(copied) copied") }
            if moved > 0 { parts.append("\(moved) moved") }
            if skipped > 0 { parts.append("\(skipped) skipped") }
            return parts.isEmpty ? "Nothing to do" : parts.joined(separator: ", ")
        }
    }

    /// Work out exactly which files an export would touch, without writing anything.
    static func plan(shots: [Shot], flags: [Shot.ID: FlagSelection]) -> Plan {
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

        return Plan(files: files, totalBytes: bytes, shotCount: shotCount)
    }

    /// Execute the export, reporting progress on the main actor as files land.
    @MainActor
    static func run(
        files: [URL],
        destination: URL,
        mode: Mode,
        onProgress: @MainActor (Int, Int) -> Void
    ) async -> Result {
        var result = Result()
        let fm = FileManager.default

        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }

        do {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            result.failures.append("Could not create destination: \(error.localizedDescription)")
            return result
        }

        let total = files.count
        for (index, source) in files.enumerated() {
            let target = uniqueDestination(for: source, in: destination)

            // Moving inside the same folder is a no-op; treat it as skipped.
            if source.deletingLastPathComponent().standardizedFileURL == destination.standardizedFileURL {
                result.skipped += 1
                onProgress(index + 1, total)
                continue
            }

            do {
                switch mode {
                case .copy:
                    try fm.copyItem(at: source, to: target)
                    result.copied += 1
                case .move:
                    try fm.moveItem(at: source, to: target)
                    result.moved += 1
                }
            } catch {
                result.failures.append("\(source.lastPathComponent): \(error.localizedDescription)")
            }
            onProgress(index + 1, total)

            // Yield so the progress UI can breathe on very large exports.
            if index % 8 == 7 {
                await Task.yield()
            }
        }

        return result
    }

    /// Pick a non-colliding destination, appending " 2", " 3", … when needed.
    static func uniqueDestination(for source: URL, in folder: URL) -> URL {
        let fm = FileManager.default
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var candidate = folder.appendingPathComponent(source.lastPathComponent)
        var counter = 2

        while fm.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = folder.appendingPathComponent(name)
            counter += 1
        }
        return candidate
    }

    static func fileSize(_ url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values?.fileSize else { return nil }
        return Int64(size)
    }
}

// MARK: - Formatting helpers

enum Format {
    static func bytes(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: count)
    }
}
