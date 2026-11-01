import Foundation
import Observation

/// Re-runs a closure whenever any observable property it read changes.
///
/// This is how AppKit controllers follow `@Observable` models: the closure both
/// reads the state it depends on and applies it, so dependencies are always
/// exactly what it used last time. Changes are coalesced onto the next main-actor
/// turn, so a burst of mutations produces a single update.
@MainActor
final class ObservationLoop {
    private let body: @MainActor () -> Void
    private var isCancelled = false

    init(_ body: @escaping @MainActor () -> Void) {
        self.body = body
        run()
    }

    func cancel() {
        isCancelled = true
    }

    private func run() {
        guard !isCancelled else { return }
        withObservationTracking {
            body()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.run()
            }
        }
    }
}
