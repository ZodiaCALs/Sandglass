import Foundation

// MARK: - File kinds

/// The two file variants Sandglass understands.
///
/// A *shot* is normally a JPG + NEF pair sharing a base name, but either variant
/// may be missing on disk and the shot is still shown.
enum FileKind: String, CaseIterable, Sendable, Codable, Hashable {
    case jpg
    case nef

    /// Human-readable name used across the interface.
    var label: String {
        switch self {
        case .jpg: "JPG"
        case .nef: "NEF"
        }
    }

    /// Lower-case file extensions that map onto this kind.
    var extensions: Set<String> {
        switch self {
        case .jpg: ["jpg", "jpeg"]
        case .nef: ["nef"]
        }
    }

    var other: FileKind { self == .jpg ? .nef : .jpg }

    static func from(extension ext: String) -> FileKind? {
        let lowered = ext.lowercased()
        return allCases.first { $0.extensions.contains(lowered) }
    }

    static func from(url: URL) -> FileKind? {
        from(extension: url.pathExtension)
    }
}

// MARK: - Flags

/// A flag records *what* should be exported, not just *that* a shot was liked.
///
/// Flagging is independent per variant, so a shot can be kept as JPG only, NEF
/// only, or both.
struct FlagSelection: OptionSet, Hashable, Sendable {
    let rawValue: Int

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    static let jpg = FlagSelection(rawValue: 1 << 0)
    static let nef = FlagSelection(rawValue: 1 << 1)
    static let both: FlagSelection = [.jpg, .nef]

    static func kind(_ kind: FileKind) -> FlagSelection {
        kind == .jpg ? .jpg : .nef
    }

    /// Kinds in this selection, in stable JPG-then-NEF order.
    var kinds: [FileKind] {
        FileKind.allCases.filter { contains(.kind($0)) }
    }

    var label: String {
        switch self {
        case []: "None"
        case .jpg: "JPG"
        case .nef: "NEF"
        default: "JPG + NEF"
        }
    }
}

// MARK: - Shot

/// One logical photo: a base name plus whichever variants exist for it.
struct Shot: Identifiable, Hashable, Sendable {
    /// Stable identity derived from folder + base name.
    let id: String
    let baseName: String
    let directory: URL
    /// Present only when that variant actually exists on disk.
    let files: [FileKind: URL]

    var displayName: String { baseName }

    /// Folder-independent key used to remember flags between launches.
    var persistenceKey: String { baseName.lowercased() }

    var jpgURL: URL? { files[.jpg] }
    var nefURL: URL? { files[.nef] }

    func url(for kind: FileKind) -> URL? { files[kind] }

    var availableKinds: [FileKind] {
        FileKind.allCases.filter { files[$0] != nil }
    }

    /// True when both variants were found — the case the app is built around.
    var isPaired: Bool { jpgURL != nil && nefURL != nil }

    /// "JPG + NEF", or "NEF only" when a sibling is missing.
    var variantSummary: String {
        let labels = availableKinds.map(\.label)
        guard labels.count > 1 else { return labels.first.map { "\($0) only" } ?? "No files" }
        return labels.joined(separator: " + ")
    }

    /// The variant to show: the preferred one when it exists, otherwise whatever does.
    func kind(preferring preferred: FileKind) -> FileKind {
        if files[preferred] != nil { return preferred }
        if files[preferred.other] != nil { return preferred.other }
        return preferred
    }

    /// The variant shown first: JPG when there is one.
    var defaultKind: FileKind { kind(preferring: .jpg) }
}

// MARK: - Pairing

/// Groups loose files into shots by base name.
enum ShotPairing {

    /// Groups loose files into shots by base name.
    ///
    /// Matching is exact apart from case, which keeps the rule predictable:
    /// `DSC_0001.JPG` and `dsc_0001.nef` are one photo, while `IMG_1` and `IMG_10`
    /// stay two. Files that only differ by a numeric suffix (`DSC_0002-2`) are
    /// deliberately *not* folded into `DSC_0002` — camera numbering makes that
    /// guess wrong more often than right. If two files of one variant share a
    /// name, the duplicate becomes its own entry rather than being dropped.
    static func pair(_ urls: [URL]) -> [Shot] {
        var buckets: [String: (display: String, files: [FileKind: [URL]])] = [:]
        var order: [String] = []

        for url in urls {
            guard let kind = FileKind.from(url: url) else { continue }
            let base = url.deletingPathExtension().lastPathComponent
            let key = base.lowercased()
            if buckets[key] == nil {
                buckets[key] = (display: base, files: [:])
                order.append(key)
            }
            buckets[key]?.files[kind, default: []].append(url)
        }

        let directory = urls.first?.deletingLastPathComponent() ?? URL(fileURLWithPath: "/")
        var shots: [Shot] = []
        shots.reserveCapacity(order.count)
        // Names already taken, so a duplicate's suffixed name can never collide
        // with a real file of that name (DSC_1.JPG + DSC_1.JPEG next to DSC_1-2.JPG).
        var taken = Set(order)

        for key in order {
            guard let bucket = buckets[key] else { continue }
            // A shot holds at most one file per variant; extras become their own
            // entries so nothing on disk is silently hidden.
            let deepest = bucket.files.values.map(\.count).max() ?? 1
            var suffix = 2
            for position in 0..<max(deepest, 1) {
                var files: [FileKind: URL] = [:]
                for (kind, list) in bucket.files where list.indices.contains(position) {
                    files[kind] = list[position]
                }
                var display = bucket.display
                if position > 0 {
                    repeat {
                        display = "\(bucket.display)-\(suffix)"
                        suffix += 1
                    } while taken.contains(display.lowercased())
                    taken.insert(display.lowercased())
                }
                shots.append(Shot(
                    id: "\(directory.path)/\(display.lowercased())",
                    baseName: display,
                    directory: directory,
                    files: files
                ))
            }
        }

        return shots.sorted { naturalCompare($0.baseName, $1.baseName) }
    }

    /// Finder-like ordering: digit runs compare numerically, text case-insensitively.
    static func naturalCompare(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.numeric, .caseInsensitive, .widthInsensitive]) == .orderedAscending
    }
}

// MARK: - Scanning

/// Reads a folder from disk and turns its loose files into shots.
enum FolderScanner {

    enum ScanError: LocalizedError, Equatable {
        case notAFolder(URL)
        case notReadable(URL)
        case noImages(URL)

        var errorDescription: String? {
            switch self {
            case .notAFolder(let url):
                "“\(url.lastPathComponent)” is not a folder."
            case .notReadable(let url):
                "Sandglass can’t read “\(url.lastPathComponent)”. Check the folder’s permissions and try again."
            case .noImages(let url):
                "No JPG or NEF files were found in “\(url.lastPathComponent)”."
            }
        }
    }

    /// Enumerate handled image files directly inside `folder` and pair them.
    /// Subfolders are not scanned.
    static func scan(folder: URL) throws -> [Shot] {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory) else {
            throw ScanError.notReadable(folder)
        }
        guard isDirectory.boolValue else { throw ScanError.notAFolder(folder) }

        #if os(macOS)
        // A security-scoped URL from an open panel needs its scope held while reading.
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        #endif

        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants, .skipsPackageDescendants]
            )
        } catch {
            throw ScanError.notReadable(folder)
        }

        var found: [URL] = []
        for entry in entries where FileKind.from(url: entry) != nil {
            let values = try? entry.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile ?? false else { continue }
            found.append(entry)
        }

        let shots = ShotPairing.pair(found)
        guard !shots.isEmpty else { throw ScanError.noImages(folder) }
        return shots
    }
}
