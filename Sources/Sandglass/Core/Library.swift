import Foundation
import Observation

/// What a flag action did — drives the confirmation toast and undo.
enum FlagOutcome: Equatable, Sendable {
    case changed(shotID: Shot.ID, from: FlagSelection, to: FlagSelection)
    /// The requested variant has no file on disk.
    case unavailable(FileKind)
    case noPhoto

    /// Short confirmation text and an SF Symbol name, or nil when nothing changed.
    var message: (text: String, symbol: String)? {
        switch self {
        case .noPhoto:
            return nil
        case .unavailable(let kind):
            return ("No \(kind.label) file for this photo", "exclamationmark.triangle")
        case .changed(_, let before, let after):
            if after == before { return nil }
            if after.isEmpty { return ("Flags cleared", "flag.slash") }
            let added = after.subtracting(before)
            let removed = before.subtracting(after)
            if removed.isEmpty { return ("Flagged \(added.label)", "flag.fill") }
            if added.isEmpty { return ("Unflagged \(removed.label)", "flag.slash") }
            return ("Keeping \(after.label) only", "flag.fill")
        }
    }

    /// True when the action added a flag (used by "advance after flagging").
    var addedFlag: Bool {
        guard case .changed(_, let before, let after) = self else { return false }
        return !after.subtracting(before).isEmpty
    }
}

/// The culling session: which folder is open, which photo and variant are on
/// screen, and what has been flagged.
///
/// Observation is fine-grained: a view that reads only `index` is not redrawn
/// when a flag changes, and vice versa.
@MainActor
@Observable
final class Library {

    enum Phase: Equatable, Sendable {
        case empty
        case scanning(URL)
        case ready
    }

    private(set) var phase: Phase = .empty
    private(set) var folder: URL?
    private(set) var shots: [Shot] = []
    /// Bumped whenever the list of shots is replaced (open, reload), so observers
    /// can tell a new folder from a changed flag.
    private(set) var generation = 0

    private(set) var index = 0
    /// The variant on screen. Always one that exists for the current shot.
    private(set) var kind: FileKind = .jpg
    /// The variant the user last asked for; shown whenever a photo has it.
    private(set) var preferredKind: FileKind = .jpg

    /// Only non-empty selections are stored.
    private(set) var flags: [Shot.ID: FlagSelection] = [:]
    /// Photos that have been on screen.
    private(set) var reviewed: Set<Shot.ID> = []

    /// Where sessions are remembered between launches; nil turns that off.
    @ObservationIgnored var sessionStore: SessionStore?
    @ObservationIgnored private var scanToken = 0
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var indexByID: [Shot.ID: Int] = [:]

    init(sessionStore: SessionStore? = nil) {
        self.sessionStore = sessionStore
    }

    // MARK: Derived state

    var isScanning: Bool {
        if case .scanning = phase { return true }
        return false
    }

    var currentShot: Shot? {
        shots.indices.contains(index) ? shots[index] : nil
    }

    /// The file on screen.
    var currentURL: URL? { currentShot?.url(for: kind) }

    var count: Int { shots.count }
    var position: Int { shots.isEmpty ? 0 : index + 1 }
    var isAtStart: Bool { index <= 0 }
    var isAtEnd: Bool { shots.isEmpty || index >= shots.count - 1 }

    var flaggedShotCount: Int { flags.count }
    var flaggedFileCount: Int { flags.values.reduce(0) { $0 + $1.kinds.count } }

    var currentSelection: FlagSelection {
        guard let shot = currentShot else { return [] }
        return flags[shot.id] ?? []
    }

    var reviewedFraction: Double {
        shots.isEmpty ? 0 : Double(reviewed.count) / Double(shots.count)
    }

    func selection(for shot: Shot) -> FlagSelection {
        flags[shot.id] ?? []
    }

    func index(of id: Shot.ID) -> Int? {
        indexByID[id]
    }

    func exportPlan() -> ExportPlan {
        Exporter.plan(shots: shots, flags: flags)
    }

    // MARK: Opening

    /// Scan `url` and show it. Flags, reviewed photos and position are restored
    /// from the last session in that folder; `file` (a JPG or NEF inside it) is
    /// selected when given. On failure the previous folder stays open.
    @discardableResult
    func open(folder url: URL, selecting file: URL? = nil) async throws -> Int {
        let previous = phase
        saveSessionNow()
        scanToken += 1
        let token = scanToken
        phase = .scanning(url)
        do {
            let scanned = try await Task.detached(priority: .userInitiated) {
                try FolderScanner.scan(folder: url)
            }.value
            guard token == scanToken else { throw CancellationError() }
            install(scanned, folder: url, selecting: file, restoring: storedState(for: url))
            return scanned.count
        } catch {
            if token == scanToken {
                phase = previous == .empty || shots.isEmpty ? .empty : .ready
            }
            throw error
        }
    }

    /// Rescan the open folder, keeping flags and position for shots that remain.
    func reload() async throws {
        guard let folder else { return }
        let kept = currentState()
        scanToken += 1
        let token = scanToken
        phase = .scanning(folder)
        do {
            let scanned = try await Task.detached(priority: .userInitiated) {
                try FolderScanner.scan(folder: folder)
            }.value
            guard token == scanToken else { throw CancellationError() }
            install(scanned, folder: folder, selecting: nil, restoring: kept)
        } catch {
            if token == scanToken { phase = shots.isEmpty ? .empty : .ready }
            throw error
        }
    }

    /// Close the folder, remembering its session.
    func close() {
        saveSessionNow()
        scanToken += 1
        folder = nil
        shots = []
        indexByID = [:]
        flags = [:]
        reviewed = []
        index = 0
        generation += 1
        phase = .empty
    }

    // MARK: Navigation

    func go(to newIndex: Int) {
        guard !shots.isEmpty else { return }
        let clamped = min(max(newIndex, 0), shots.count - 1)
        guard clamped != index else { return }
        index = clamped
        kind = shots[clamped].kind(preferring: preferredKind)
        markReviewed()
        scheduleSave()
    }

    func next() { go(to: index + 1) }
    func previous() { go(to: index - 1) }
    func first() { go(to: 0) }
    func last() { go(to: shots.count - 1) }
    func move(by delta: Int) { go(to: index + delta) }

    /// Show a variant. Returns false when the current photo has no such file.
    /// The choice sticks: later photos open on it too, when they have it.
    @discardableResult
    func setKind(_ newKind: FileKind) -> Bool {
        guard let shot = currentShot, shot.url(for: newKind) != nil else { return false }
        preferredKind = newKind
        if kind != newKind { kind = newKind }
        return true
    }

    /// Flip between JPG and NEF. Returns false when the other variant is missing.
    @discardableResult
    func toggleKind() -> Bool {
        setKind(kind.other)
    }

    /// Change the variant shown by default, without requiring the current photo to have it.
    func setPreferredKind(_ newKind: FileKind) {
        preferredKind = newKind
        if let shot = currentShot { kind = shot.kind(preferring: newKind) }
    }

    // MARK: Flags

    /// Flag or unflag one variant. Defaults to the photo and variant on screen.
    @discardableResult
    func toggleFlag(_ variant: FileKind? = nil, at shotIndex: Int? = nil) -> FlagOutcome {
        guard let shot = shot(at: shotIndex) else { return .noPhoto }
        let target = variant ?? (shotIndex == nil ? kind : shot.kind(preferring: preferredKind))
        guard shot.url(for: target) != nil else { return .unavailable(target) }
        let before = flags[shot.id] ?? []
        var after = before
        let bit = FlagSelection.kind(target)
        if after.contains(bit) { after.remove(bit) } else { after.insert(bit) }
        return apply(after, to: shot, from: before)
    }

    /// Keep every variant the photo has — or, when all are already kept, none.
    @discardableResult
    func toggleFlagBoth(at shotIndex: Int? = nil) -> FlagOutcome {
        guard let shot = shot(at: shotIndex) else { return .noPhoto }
        let available = Self.available(shot)
        let before = flags[shot.id] ?? []
        let after: FlagSelection = before.isSuperset(of: available) ? [] : before.union(available)
        return apply(after, to: shot, from: before)
    }

    /// Keep exactly one variant — or clear the photo if that is already the case.
    @discardableResult
    func flagOnly(_ variant: FileKind, at shotIndex: Int? = nil) -> FlagOutcome {
        guard let shot = shot(at: shotIndex) else { return .noPhoto }
        guard shot.url(for: variant) != nil else { return .unavailable(variant) }
        let before = flags[shot.id] ?? []
        let only = FlagSelection.kind(variant)
        return apply(before == only ? [] : only, to: shot, from: before)
    }

    @discardableResult
    func clearFlags(at shotIndex: Int? = nil) -> FlagOutcome {
        guard let shot = shot(at: shotIndex) else { return .noPhoto }
        let before = flags[shot.id] ?? []
        return apply([], to: shot, from: before)
    }

    /// Set a photo's selection outright (used by undo).
    @discardableResult
    func setSelection(_ selection: FlagSelection, forShotID id: Shot.ID) -> FlagOutcome {
        guard let position = indexByID[id] else { return .noPhoto }
        let shot = shots[position]
        return apply(selection, to: shot, from: flags[id] ?? [])
    }

    /// Clear every flag, returning what was cleared so it can be restored.
    @discardableResult
    func clearAllFlags() -> [Shot.ID: FlagSelection] {
        let previous = flags
        flags = [:]
        scheduleSave()
        return previous
    }

    /// Put back a complete set of flags (undo of "Clear All Flags").
    func restoreFlags(_ saved: [Shot.ID: FlagSelection]) {
        flags = saved.filter { indexByID[$0.key] != nil && !$0.value.isEmpty }
        scheduleSave()
    }

    // MARK: Sessions

    func snapshot() -> SessionSnapshot? {
        guard let folder else { return nil }
        var stored: [String: Int] = [:]
        for shot in shots {
            if let selection = flags[shot.id], !selection.isEmpty {
                stored[shot.persistenceKey] = selection.rawValue
            }
        }
        return SessionSnapshot(
            folderPath: folder.standardizedFileURL.path,
            currentShot: currentShot?.persistenceKey,
            flags: stored,
            reviewed: shots.filter { reviewed.contains($0.id) }.map(\.persistenceKey),
            savedAt: Date()
        )
    }

    /// Write the session now instead of waiting for the debounce.
    func saveSessionNow() {
        saveTask?.cancel()
        saveTask = nil
        guard let store = sessionStore, let snapshot = snapshot() else { return }
        try? store.save(snapshot)
    }

    // MARK: Internals

    private struct RestoredState {
        var flags: [String: FlagSelection] = [:]
        var reviewed: Set<String> = []
        var current: String?
    }

    private func shot(at shotIndex: Int?) -> Shot? {
        guard let shotIndex else { return currentShot }
        return shots.indices.contains(shotIndex) ? shots[shotIndex] : nil
    }

    private static func available(_ shot: Shot) -> FlagSelection {
        FlagSelection(shot.availableKinds.map(FlagSelection.kind))
    }

    private func apply(_ requested: FlagSelection, to shot: Shot, from before: FlagSelection) -> FlagOutcome {
        // A flag can only name a variant that exists, or export would come up short.
        let after = requested.intersection(Self.available(shot))
        flags[shot.id] = after.isEmpty ? nil : after
        scheduleSave()
        return .changed(shotID: shot.id, from: before, to: after)
    }

    private func markReviewed() {
        guard let shot = currentShot, !reviewed.contains(shot.id) else { return }
        reviewed.insert(shot.id)
    }

    private func storedState(for folder: URL) -> RestoredState {
        guard let snapshot = sessionStore?.load(folder: folder) else { return RestoredState() }
        return RestoredState(
            flags: snapshot.flags.mapValues { FlagSelection(rawValue: $0) },
            reviewed: Set(snapshot.reviewed),
            current: snapshot.currentShot
        )
    }

    private func currentState() -> RestoredState {
        var state = RestoredState(current: currentShot?.persistenceKey)
        for shot in shots {
            if let selection = flags[shot.id] { state.flags[shot.persistenceKey] = selection }
            if reviewed.contains(shot.id) { state.reviewed.insert(shot.persistenceKey) }
        }
        return state
    }

    private func install(_ scanned: [Shot], folder url: URL, selecting file: URL?, restoring state: RestoredState) {
        folder = url
        shots = scanned
        indexByID = Dictionary(scanned.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })

        var restoredFlags: [Shot.ID: FlagSelection] = [:]
        var restoredReviewed: Set<Shot.ID> = []
        for shot in scanned {
            if let selection = state.flags[shot.persistenceKey] {
                let valid = selection.intersection(Self.available(shot))
                if !valid.isEmpty { restoredFlags[shot.id] = valid }
            }
            if state.reviewed.contains(shot.persistenceKey) { restoredReviewed.insert(shot.id) }
        }
        flags = restoredFlags
        reviewed = restoredReviewed

        var start = 0
        if let file {
            let target = file.standardizedFileURL
            if let match = scanned.firstIndex(where: { $0.files.values.contains { $0.standardizedFileURL == target } }) {
                start = match
            }
        } else if let current = state.current,
                  let match = scanned.firstIndex(where: { $0.persistenceKey == current }) {
            start = match
        }
        index = start
        if let file, let shot = scanned.indices.contains(start) ? scanned[start] : nil,
           let fileKind = FileKind.from(url: file), shot.url(for: fileKind) != nil {
            kind = fileKind
        } else if scanned.indices.contains(start) {
            kind = scanned[start].kind(preferring: preferredKind)
        }
        generation += 1
        phase = .ready
        markReviewed()
        scheduleSave()
    }

    private func scheduleSave() {
        guard sessionStore != nil else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.saveSessionNow()
        }
    }
}
