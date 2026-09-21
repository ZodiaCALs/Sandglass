import Foundation

/// Reads a folder from disk and turns its loose files into shots.
enum FolderScanner {

    enum ScanError: LocalizedError {
        case notReadable(URL)
        case noImages(URL)

        var errorDescription: String? {
            switch self {
            case .notReadable(let url):
                return "Sandglass can't read “\(url.lastPathComponent)”. Check the folder's permissions and try again."
            case .noImages(let url):
                return "No JPG or NEF files were found in “\(url.lastPathComponent)”."
            }
        }
    }

    /// Enumerate handled image files directly inside `folder` and pair them.
    ///
    /// `onProgress` fires on the calling context as files are discovered, so the
    /// UI can show the scan advancing on large folders.
    static func scan(folder: URL, onProgress: @Sendable (Int) -> Void = { _ in }) throws -> [Shot] {
        let fm = FileManager.default

        // A security-scoped URL from NSOpenPanel needs its scope held while we read.
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }

        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants, .skipsPackageDescendants]
            )
        } catch {
            throw ScanError.notReadable(folder)
        }

        var found: [URL] = []
        for entry in entries {
            guard FileKind.from(url: entry) != nil else { continue }
            let values = try? entry.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile ?? false else { continue }
            found.append(entry)
            onProgress(found.count)
        }

        let shots = ShotPairing.pair(found)
        guard !shots.isEmpty else { throw ScanError.noImages(folder) }
        return shots
    }
}
