import Testing
import Foundation
@testable import Sandglass

@Suite("Culling session")
@MainActor
struct LibraryTests {

    private func openedSample(store: SessionStore? = nil) async throws -> Library {
        let library = Library(sessionStore: store)
        try await library.open(folder: Fixtures.sampleShoot)
        try #require(!library.shots.isEmpty)
        return library
    }

    @Test("Opening a folder lists its shots and starts on the first")
    func opensFolder() async throws {
        let library = try await openedSample()
        #expect(library.phase == .ready)
        #expect(library.folder == Fixtures.sampleShoot)
        #expect(library.index == 0)
        #expect(library.position == 1)
        #expect(library.count == library.shots.count)
        #expect(library.reviewed.count == 1, "the first photo counts as seen")
        #expect(library.generation == 1)
    }

    @Test("A failed open keeps the previous folder")
    func failedOpenKeepsFolder() async throws {
        let library = try await openedSample()
        let empty = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: empty) }

        await #expect(throws: FolderScanner.ScanError.self) {
            try await library.open(folder: empty)
        }
        #expect(library.phase == .ready)
        #expect(library.folder == Fixtures.sampleShoot)
    }

    @Test("Moving stops at the ends of the folder")
    func navigationIsBounded() async throws {
        let library = try await openedSample()
        library.previous()
        #expect(library.index == 0)
        library.last()
        #expect(library.isAtEnd)
        let end = library.index
        library.next()
        #expect(library.index == end)
        library.first()
        #expect(library.isAtStart)
        library.move(by: 3)
        #expect(library.index == 3)
    }

    @Test("The chosen variant sticks, and falls back on photos that lack it")
    func variantChoiceSticks() async throws {
        let library = try await openedSample()
        let paired = try #require(library.shots.firstIndex { $0.isPaired })
        let jpgOnly = try #require(library.shots.firstIndex { $0.jpgURL != nil && $0.nefURL == nil })

        library.go(to: paired)
        #expect(library.setKind(.nef))
        #expect(library.kind == .nef)

        library.go(to: jpgOnly)
        #expect(library.kind == .jpg, "a JPG-only photo shows its JPG")
        #expect(!library.toggleKind(), "there is no NEF to switch to")
        #expect(library.kind == .jpg)

        library.go(to: paired)
        #expect(library.kind == .nef, "back on a pair, the NEF choice applies again")
    }

    @Test("Flag, flag both, keep only one, clear")
    func flagRules() async throws {
        let library = try await openedSample()
        let paired = try #require(library.shots.firstIndex { $0.isPaired })
        library.go(to: paired)
        library.setKind(.jpg)

        var outcome = library.toggleFlag()
        #expect(library.currentSelection == .jpg)
        #expect(outcome.message?.text == "Flagged JPG")
        #expect(outcome.addedFlag)

        outcome = library.toggleFlagBoth()
        #expect(library.currentSelection == .both)
        #expect(outcome.message?.text == "Flagged NEF")

        outcome = library.flagOnly(.nef)
        #expect(library.currentSelection == .nef)
        #expect(outcome.message?.text == "Unflagged JPG")

        outcome = library.flagOnly(.nef)
        #expect(library.currentSelection.isEmpty, "keeping only what is already kept clears it")
        #expect(outcome.message?.text == "Flags cleared")

        library.toggleFlagBoth()
        outcome = library.toggleFlagBoth()
        #expect(library.currentSelection.isEmpty, "flag both on a fully flagged photo clears it")

        library.flagOnly(.jpg)
        outcome = library.flagOnly(.nef)
        #expect(outcome.message?.text == "Keeping NEF only")

        library.clearFlags()
        #expect(library.flaggedShotCount == 0)
    }

    @Test("A missing variant cannot be flagged")
    func missingVariantIsRefused() async throws {
        let library = try await openedSample()
        let jpgOnly = try #require(library.shots.firstIndex { $0.jpgURL != nil && $0.nefURL == nil })
        library.go(to: jpgOnly)

        #expect(library.toggleFlag(.nef) == .unavailable(.nef))
        #expect(library.flagOnly(.nef) == .unavailable(.nef))
        library.toggleFlagBoth()
        #expect(library.currentSelection == .jpg, "flag both keeps only what exists")
    }

    @Test("Flags can be changed on any photo, not just the one on screen")
    func flagsByIndex() async throws {
        let library = try await openedSample()
        let target = try #require(library.shots.lastIndex { $0.isPaired })
        library.toggleFlagBoth(at: target)
        #expect(library.selection(for: library.shots[target]) == .both)
        #expect(library.index == 0, "the photo on screen is unchanged")
        #expect(library.flaggedFileCount == 2)
    }

    @Test("Clearing all flags can be undone")
    func clearAllCanBeRestored() async throws {
        let library = try await openedSample()
        library.toggleFlag()
        library.toggleFlagBoth(at: 2)
        let saved = library.clearAllFlags()
        #expect(library.flaggedShotCount == 0)
        library.restoreFlags(saved)
        #expect(library.flaggedShotCount == 2)

        let id = library.shots[2].id
        library.setSelection([], forShotID: id)
        #expect(library.selection(for: library.shots[2]).isEmpty)
    }

    @Test("Opening with a file selects that photo and variant")
    func opensOnSelectedFile() async throws {
        let library = Library()
        try await library.open(folder: Fixtures.sampleShoot, selecting: Fixtures.sample("DSC_0007.NEF"))
        #expect(library.currentShot?.baseName == "DSC_0007")
        #expect(library.kind == .nef)
    }

    @Test("Flags, reviewed photos and position survive closing and reopening")
    func sessionsPersist() async throws {
        let storeFolder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: storeFolder) }
        let store = SessionStore(directory: storeFolder)

        let first = try await openedSample(store: store)
        let paired = try #require(first.shots.firstIndex { $0.isPaired })
        first.go(to: paired)
        first.toggleFlagBoth()
        first.next()
        let position = first.index
        let reviewed = first.reviewed.count
        first.saveSessionNow()

        let second = try await openedSample(store: store)
        #expect(second.index == position)
        #expect(second.selection(for: second.shots[paired]) == .both)
        #expect(second.reviewed.count == reviewed)
    }

    @Test("Reloading keeps flags for photos that are still there")
    func reloadKeepsFlags() async throws {
        let folder = try copyOfSampleShoot()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let library = Library()
        try await library.open(folder: folder)
        let kept = try #require(library.shots.firstIndex { $0.baseName == "DSC_0003" })
        library.go(to: kept)
        library.toggleFlagBoth()

        try FileManager.default.removeItem(at: folder.appendingPathComponent("DSC_0001.JPG"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("DSC_0001.NEF"))
        try await library.reload()

        #expect(library.generation == 2)
        #expect(!library.shots.contains { $0.baseName == "DSC_0001" })
        #expect(library.currentShot?.baseName == "DSC_0003", "the photo on screen is kept")
        #expect(library.currentSelection == .both)
    }

    @Test("The export plan reflects the flags")
    func exportPlanFollowsFlags() async throws {
        let library = try await openedSample()
        #expect(library.exportPlan().isEmpty)
        let paired = try #require(library.shots.firstIndex { $0.isPaired })
        library.go(to: paired)
        library.flagOnly(.nef)
        let plan = library.exportPlan()
        #expect(plan.files == [library.shots[paired].nefURL].compactMap { $0 })
    }

    @Test("Closing returns to the empty state")
    func closeEmpties() async throws {
        let library = try await openedSample()
        library.close()
        #expect(library.phase == .empty)
        #expect(library.shots.isEmpty)
        #expect(library.currentShot == nil)
        #expect(library.toggleFlag() == .noPhoto)
    }
}

@Suite("Session files")
struct SessionStoreTests {

    @Test("Each folder gets its own stable file")
    func stableFileNames() {
        let store = SessionStore(directory: URL(fileURLWithPath: "/tmp/sessions"))
        let a = store.fileURL(for: URL(fileURLWithPath: "/Volumes/Card/DCIM/100NIKON"))
        let b = store.fileURL(for: URL(fileURLWithPath: "/Volumes/Card/DCIM/101NIKON"))
        #expect(a != b)
        #expect(a == store.fileURL(for: URL(fileURLWithPath: "/Volumes/Card/DCIM/100NIKON/")))
        #expect(SessionStore.stableHash("") == "cbf29ce484222325", "FNV-1a offset basis")
        #expect(SessionStore.stableHash("a") == "af63dc4c8601ec8c")
    }

    @Test("A snapshot round-trips and is tied to its folder")
    func roundTrip() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        let folder = URL(fileURLWithPath: "/tmp/shoot")
        let snapshot = SessionSnapshot(
            folderPath: folder.standardizedFileURL.path,
            currentShot: "dsc_0002",
            flags: ["dsc_0001": 3],
            reviewed: ["dsc_0001", "dsc_0002"],
            savedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try store.save(snapshot)
        #expect(store.load(folder: folder) == snapshot)
        #expect(store.load(folder: URL(fileURLWithPath: "/tmp/other")) == nil)
        store.remove(folder: folder)
        #expect(store.load(folder: folder) == nil)
    }
}
