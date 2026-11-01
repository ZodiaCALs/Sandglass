import Foundation
@testable import Sandglass

/// Paths to the checked-in fixtures, resolved from this source file so tests run
/// from any working directory.
enum Fixtures {
    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Core
            .deletingLastPathComponent()   // SandglassTests
            .deletingLastPathComponent()   // Tests
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    static var sampleShoot: URL { root.appendingPathComponent("SampleShoot", isDirectory: true) }
    static var orientation: URL { root.appendingPathComponent("Orientation", isDirectory: true) }
    static var rawPreview: URL { root.appendingPathComponent("RawPreview", isDirectory: true) }

    static func sample(_ name: String) -> URL { sampleShoot.appendingPathComponent(name) }
    static func raw(_ name: String) -> URL { rawPreview.appendingPathComponent(name) }
}

/// URLs that look like real files without touching the disk.
func urls(_ names: String...) -> [URL] {
    names.map { URL(fileURLWithPath: "/tmp/shoot/\($0)") }
}

func shotNamed(_ shots: [Shot], _ name: String) -> Shot? {
    shots.first { $0.baseName.caseInsensitiveCompare(name) == .orderedSame }
}

/// A throwaway directory, removed by the caller.
func makeTemporaryDirectory() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sandglass-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func writeFiles(_ names: [String], in folder: URL, bytes: Int = 32) throws {
    for name in names {
        try Data(repeating: 0x41, count: bytes).write(to: folder.appendingPathComponent(name))
    }
}

/// Copy the sample shoot somewhere disposable, so a test can change it.
func copyOfSampleShoot() throws -> URL {
    let destination = try makeTemporaryDirectory().appendingPathComponent("SampleShoot", isDirectory: true)
    try FileManager.default.copyItem(at: Fixtures.sampleShoot, to: destination)
    return destination
}
