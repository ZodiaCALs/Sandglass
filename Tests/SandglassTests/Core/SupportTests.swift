import Testing
import Foundation
import Observation
@testable import Sandglass

@Suite("LRU cache")
struct LRUCacheTests {

    @Test("Least recently used entries are evicted first")
    func evictsLeastRecentlyUsed() {
        let cache = LRUCache<String, Int>(countLimit: 3)
        cache.insert(1, forKey: "a")
        cache.insert(2, forKey: "b")
        cache.insert(3, forKey: "c")
        _ = cache.value(forKey: "a")                 // a is now the most recent
        cache.insert(4, forKey: "d")                 // evicts b
        #expect(cache.peek("b") == nil)
        #expect(cache.keysByRecency == ["d", "a", "c"])
    }

    @Test("Cost limits evict until the budget fits")
    func costLimit() {
        let cache = LRUCache<Int, String>(costLimit: 100)
        for key in 0..<10 { cache.insert("\(key)", forKey: key, cost: 30) }
        #expect(cache.totalCost <= 100)
        #expect(cache.count == 3)
        #expect(cache.keysByRecency == [9, 8, 7])
        cache.costLimit = 40
        #expect(cache.count == 1)
        cache.insert("huge", forKey: 99, cost: 500)
        #expect(cache.peek(99) == nil, "something bigger than the whole budget is not kept")
        #expect(cache.totalCost == 0)
    }

    @Test("Replacing a value updates its cost; peeking does not reorder")
    func replaceAndPeek() {
        let cache = LRUCache<String, Int>(costLimit: 100)
        cache.insert(1, forKey: "a", cost: 10)
        cache.insert(2, forKey: "b", cost: 10)
        cache.insert(3, forKey: "a", cost: 50)
        #expect(cache.totalCost == 60)
        #expect(cache.keysByRecency == ["a", "b"])
        _ = cache.peek("b")
        #expect(cache.keysByRecency == ["a", "b"])
        #expect(cache.removeValue(forKey: "a") == 3)
        #expect(cache.totalCost == 10)
        cache.trim(toCost: 0)
        #expect(cache.isEmpty)
    }

    @Test("Clearing a large cache works and leaves it usable")
    func removeAll() {
        let cache = LRUCache<Int, Int>()
        for key in 0..<50_000 { cache.insert(key, forKey: key) }
        cache.removeAll()
        #expect(cache.isEmpty && cache.totalCost == 0)
        cache.insert(1, forKey: 1)
        #expect(cache.keysByRecency == [1])
    }
}

@Suite("Keyboard")
struct KeyMapTests {

    private func command(_ code: UInt16, _ characters: String = "", _ modifiers: InputModifiers = [],
                         layout: BrowserLayout = .filmstrip) -> Command? {
        KeyMap.command(for: KeyPress(keyCode: code, characters: characters, modifiers: modifiers), layout: layout)
    }

    @Test("Arrows, space, J and K move through the folder")
    func movement() {
        #expect(command(KeyMap.KeyCode.right) == .next)
        #expect(command(KeyMap.KeyCode.left) == .previous)
        #expect(command(KeyMap.KeyCode.down) == .next)
        #expect(command(KeyMap.KeyCode.space, " ") == .next)
        #expect(command(KeyMap.KeyCode.space, " ", .shift) == .previous)
        #expect(command(38, "j") == .next)
        #expect(command(40, "k") == .previous)
        #expect(command(KeyMap.KeyCode.home) == .first)
        #expect(command(KeyMap.KeyCode.end) == .last)
    }

    @Test("In the grid, up and down move by rows and Return opens the photo")
    func gridKeys() {
        #expect(command(KeyMap.KeyCode.down, layout: .grid) == .rowDown)
        #expect(command(KeyMap.KeyCode.up, layout: .grid) == .rowUp)
        #expect(command(KeyMap.KeyCode.returnKey, layout: .grid) == .openSelection)
        #expect(command(KeyMap.KeyCode.returnKey, layout: .filmstrip) == nil)
    }

    @Test("Culling keys")
    func cullingKeys() {
        #expect(command(17, "t") == .toggleKind)
        #expect(command(3, "f") == .flagCurrent)
        #expect(command(3, "F", .shift) == .flagCurrent)
        #expect(command(11, "b") == .flagBoth)
        #expect(command(18, "1") == .flagOnly(.jpg))
        #expect(command(19, "2") == .flagOnly(.nef))
        #expect(command(7, "x") == .clearFlags)
        #expect(command(KeyMap.KeyCode.delete) == .clearFlags)
        #expect(command(24, "+", .shift) == .zoomIn)
        #expect(command(27, "-") == .zoomOut)
        #expect(command(29, "0") == .zoomToFit)
        #expect(command(6, "z") == .toggleZoom)
        #expect(command(5, "g") == .toggleGrid)
        #expect(command(8, "c") == .toggleCompare)
        #expect(command(34, "i") == .toggleInspector)
        #expect(command(46, "m") == .toggleInspector)
        #expect(command(KeyMap.KeyCode.tab) == .toggleThumbnails)
        #expect(command(44, "?", .shift) == .showShortcuts)
    }

    @Test("Keys with ⌘, ⌃ or ⌥ are left to the menus")
    func modifiedKeysPassThrough() {
        #expect(command(3, "f", .command) == nil)
        #expect(command(KeyMap.KeyCode.right, "", .option) == nil)
        #expect(command(17, "t", .control) == nil)
        #expect(command(0, "a") == nil)
    }

    @Test("Every layout has a distinct menu key and symbol")
    func layouts() {
        #expect(Set(BrowserLayout.allCases.map(\.menuKey)).count == BrowserLayout.allCases.count)
        #expect(Set(BrowserLayout.allCases.map(\.systemImage)).count == BrowserLayout.allCases.count)
        #expect(!BrowserLayout.grid.showsViewer)
        #expect(!BrowserLayout.photoOnly.showsThumbnails)
    }
}

@Suite("Settings")
@MainActor
struct SettingsTests {

    private func freshDefaults() -> UserDefaults {
        let name = "SandglassTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("Defaults suit a dark, fast culling setup")
    func defaults() {
        let settings = AppSettings(defaults: freshDefaults())
        #expect(settings.layout == .filmstrip)
        #expect(settings.backdrop == .glass)
        #expect(settings.appearance == .dark)
        #expect(settings.rememberFlags)
        #expect(settings.preloadFullResolution)
        #expect(settings.zoomTarget == .actualPixels)
    }

    @Test("Changes persist to the next launch")
    func persistence() {
        let defaults = freshDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.layout = .grid
        settings.tileSize = 200
        settings.backdrop = .picture
        settings.preferredKind = .nef
        settings.noteOpenedFolder(URL(fileURLWithPath: "/tmp/a"))
        settings.noteOpenedFolder(URL(fileURLWithPath: "/tmp/b"))
        settings.noteOpenedFolder(URL(fileURLWithPath: "/tmp/a"))

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.layout == .grid)
        #expect(reloaded.tileSize == 200)
        #expect(reloaded.backdrop == .picture)
        #expect(reloaded.preferredKind == .nef)
        #expect(reloaded.recentFolderPaths == ["/tmp/a", "/tmp/b"], "most recent first, no duplicates")
        #expect(reloaded.lastFolderPath == "/tmp/a")
        reloaded.clearRecentFolders()
        #expect(AppSettings(defaults: defaults).recentFolderPaths.isEmpty)
    }

    @Test("Colours parse from hex and report brightness")
    func colours() throws {
        let colour = try #require(RGBColor(hex: "#2B3550"))
        #expect(colour.hex == "#2B3550")
        #expect(!colour.isLight)
        #expect(RGBColor(hex: "E7E4DE")?.isLight == true)
        #expect(RGBColor(hex: "#12345") == nil)
        #expect(RGBColor(hex: "zzzzzz") == nil)
        for preset in AppSettings.colorPresets {
            #expect(RGBColor(hex: preset.hex) != nil, "\(preset.name)")
        }
    }
}

@Suite("Formatting")
struct FormattingTests {

    @Test("Zoom percentages read naturally")
    func percentages() {
        #expect(Format.percent(1) == "100%")
        #expect(Format.percent(0.3333) == "33%")
        #expect(Format.percent(0.0625) == "6.3%")
        #expect(Format.percent(16) == "1600%")
        #expect(Format.percent(0) == "—")
    }

    @Test("Shutter speeds are shown the way a camera displays them")
    func shutterSpeeds() {
        #expect(Format.shutter(1.0 / 250) == "1/250 s")
        #expect(Format.shutter(1.0 / 8000) == "1/8000 s")
        #expect(Format.shutter(2) == "2 s")
        #expect(Format.shutter(0.5) == "0.5 s")
    }

    @Test("Numbers are trimmed and enums named")
    func numbers() {
        #expect(Format.trim(2.80) == "2.8")
        #expect(Format.trim(4.0) == "4")
        #expect(Format.aperture(1.4) == "ƒ/1.4")
        #expect(Format.exposureProgram(3) == "Aperture priority")
        #expect(Format.meteringMode(5) == "Matrix")
        #expect(Format.orientation(6) == "Rotated 90° clockwise")
        #expect(Format.pixels(6048, 4024) == "6048 × 4024")
        #expect(Format.megapixels(6048, 4024) == "24 MP")
    }
}

@Suite("Observation loop")
@MainActor
struct ObservationLoopTests {

    @Observable
    final class Counter {
        var value = 0
        var unrelated = 0
    }

    @Test("Re-runs when what it read changes, once per burst, and stops when cancelled")
    func reruns() async throws {
        let counter = Counter()
        var seen: [Int] = []
        let loop = ObservationLoop { seen.append(counter.value) }
        #expect(seen == [0])

        counter.value = 1
        counter.value = 2
        try await Task.sleep(for: .milliseconds(50))
        #expect(seen == [0, 2], "two changes in one turn give one update")

        counter.unrelated = 5
        try await Task.sleep(for: .milliseconds(50))
        #expect(seen == [0, 2], "untracked properties do not trigger it")

        loop.cancel()
        counter.value = 3
        try await Task.sleep(for: .milliseconds(50))
        #expect(seen == [0, 2])
    }
}
