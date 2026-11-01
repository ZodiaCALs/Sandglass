import Foundation

/// What Sandglass remembers about a folder between launches: which variants were
/// flagged, which photos were looked at, and where you were.
struct SessionSnapshot: Codable, Equatable, Sendable {
    var version = 1
    var folderPath: String
    /// Persistence key of the photo that was on screen.
    var currentShot: String?
    /// Persistence key → `FlagSelection.rawValue`.
    var flags: [String: Int]
    var reviewed: [String]
    var savedAt: Date
}

/// Stores one small JSON file per folder in Application Support — never inside
/// the photo folder itself, which may be read-only or a card.
final class SessionStore: Sendable {
    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("Sandglass", isDirectory: true)
            .appendingPathComponent("Sessions", isDirectory: true)
    }

    func fileURL(for folder: URL) -> URL {
        directory.appendingPathComponent(Self.stableHash(folder.standardizedFileURL.path) + ".json")
    }

    func load(folder: URL) -> SessionSnapshot? {
        guard let data = try? Data(contentsOf: fileURL(for: folder)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(SessionSnapshot.self, from: data),
              snapshot.folderPath == folder.standardizedFileURL.path else { return nil }
        return snapshot
    }

    func save(_ snapshot: SessionSnapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL(for: URL(fileURLWithPath: snapshot.folderPath)), options: .atomic)
    }

    func remove(folder: URL) {
        try? FileManager.default.removeItem(at: fileURL(for: folder))
    }

    /// FNV-1a 64-bit — stable across launches and platforms, unlike `hashValue`.
    static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }
}
