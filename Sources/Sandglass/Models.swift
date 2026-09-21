import Foundation

// MARK: - File kinds

/// The two file variants Sandglass understands.
///
/// A "shot" is normally a JPG + NEF pair sharing a base name, but either
/// variant may be missing on disk and the shot is still shown.
enum FileKind: String, CaseIterable, Sendable, Codable {
    case jpg
    case nef

    /// Human readable name used across the UI.
    var label: String {
        switch self {
        case .jpg: return "JPG"
        case .nef: return "NEF"
        }
    }

    /// Lowercase file extensions that map onto this kind.
    var extensions: Set<String> {
        switch self {
        case .jpg: return ["jpg", "jpeg"]
        case .nef: return ["nef"]
        }
    }

    var other: FileKind {
        switch self {
        case .jpg: return .nef
        case .nef: return .jpg
        }
    }

    /// Build a kind from a file extension, if it is one we handle.
    static func from(extension ext: String) -> FileKind? {
        let lowered = ext.lowercased()
        return allCases.first { $0.extensions.contains(lowered) }
    }

    /// Kind inferred from a concrete file URL.
    static func from(url: URL) -> FileKind? {
        from(extension: url.pathExtension)
    }
}

// MARK: - Flagged quality

/// A flag records *what* the user wants exported, not just *that* they liked it.
///
/// Flagging is independent per variant, so a shot can be flagged as JPG only,
/// NEF only, or both.
struct FlagSelection: OptionSet, Hashable, Sendable {
    let rawValue: Int

    static let jpg = FlagSelection(rawValue: 1 << 0)
    static let nef = FlagSelection(rawValue: 1 << 1)

    static func kind(_ kind: FileKind) -> FlagSelection {
        switch kind {
        case .jpg: return .jpg
        case .nef: return .nef
        }
    }

    var isEmpty: Bool { rawValue == 0 }

    /// Kinds contained in this selection, in stable JPG-then-NEF order.
    var kinds: [FileKind] {
        FileKind.allCases.filter { contains(.kind($0)) }
    }

    var label: String {
        switch self {
        case []: return "None"
        case .jpg: return "JPG"
        case .nef: return "NEF"
        default: return "JPG + NEF"
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

    var jpgURL: URL? { files[.jpg] }
    var nefURL: URL? { files[.nef] }

    func url(for kind: FileKind) -> URL? { files[kind] }

    var availableKinds: [FileKind] {
        FileKind.allCases.filter { files[$0] != nil }
    }

    /// True when both variants were found — the case the app is built around.
    var isPaired: Bool { jpgURL != nil && nefURL != nil }

    /// Label such as "JPG + NEF" or "NEF only".
    var variantSummary: String {
        let labels = availableKinds.map(\.label)
        guard labels.count > 1 else { return labels.first.map { "\($0) only" } ?? "No files" }
        return labels.joined(separator: " + ")
    }

    /// The variant to show first for this shot: prefer JPG, fall back to NEF.
    var defaultKind: FileKind {
        if jpgURL != nil { return .jpg }
        if nefURL != nil { return .nef }
        return .jpg
    }
}

// MARK: - Pairing

/// Groups loose files into shots by normalised base name.
///
/// Handles Lightroom-style suffixed duplicates (`DSC_0001-2.NEF`), macOS
/// `copy` duplicates, and case differences, so `IMG_1234.JPG` and
/// `img_1234.nef` land in the same shot.
enum ShotPairing {

    /// Groups loose files into shots by base name.
    ///
    /// Matching is exact apart from case, which is what keeps the rule
    /// predictable: `DSC_0001.JPG` and `dsc_0001.nef` are one photo, while
    /// `IMG_1` and `IMG_10` stay two. Files that only differ by a numeric
    /// suffix (`DSC_0002-2`) are deliberately *not* folded into `DSC_0002`:
    /// camera numbering makes that guess wrong more often than right. If both
    /// files of one shot share a name they cannot be stored separately, so the
    /// duplicate is kept as its own entry rather than silently dropped.
    static func pair(_ urls: [URL]) -> [Shot] {
        // Bucket every file by base name, preserving discovery order per variant.
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

        for key in order {
            guard let bucket = buckets[key] else { continue }
            // A shot holds at most one file per variant; extras become their own
            // entries so nothing on disk is silently hidden. A count of 1 means
            // there is nothing to enumerate.
            let extra = (bucket.files[.jpg]?.count ?? 0) == 1 && (bucket.files[.nef]?.count ?? 0) == 1
                ? 0
                : max(bucket.files.values.map(\.count).max() ?? 1, 1) - 1

            for position in 0...max(extra, 0) {
                var files: [FileKind: URL] = [:]
                for (kind, list) in bucket.files where list.indices.contains(position) {
                    files[kind] = list[position]
                }
                // The first entry keeps the clean name; duplicates get a suffix so
                // both display and identity stay distinct.
                let display = position == 0 ? bucket.display : "\(bucket.display)-\(position + 1)"
                shots.append(
                    Shot(
                        id: "\(directory.path)/\(display.lowercased())",
                        baseName: display,
                        directory: directory,
                        files: files
                    )
                )
            }
        }

        return shots.sorted { naturalCompare($0.baseName, $1.baseName) }
    }

    /// Finder-like ordering: compare digit runs numerically, text case-insensitively.
    static func naturalCompare(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.numeric, .caseInsensitive, .widthInsensitive]) == .orderedAscending
    }
}
