import AppKit

/// Carries a `Command` on a menu item.
final class CommandBox: NSObject {
    let command: Command

    init(_ command: Command) {
        self.command = command
    }
}

/// Routes single-key shortcuts to commands.
///
/// Culling is driven from the keyboard, and the keys must work whichever control
/// has focus, so they are caught by a local monitor — but only for the main
/// window, never while text is being typed, and never with ⌘, ⌃ or ⌥ held (those
/// belong to the menus).
@MainActor
final class KeyRouter {
    weak var window: NSWindow?
    var layout: () -> BrowserLayout = { .filmstrip }
    /// Returns true when the command was handled, which consumes the key.
    var handler: (Command) -> Bool = { _ in false }

    private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.route(event) ? nil : event
        }
    }

    private func route(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, window.attachedSheet == nil else { return false }
        if let responder = window.firstResponder, responder is NSText || responder is NSTextField {
            return false
        }
        let press = KeyPress(
            keyCode: event.keyCode,
            characters: event.charactersIgnoringModifiers ?? "",
            modifiers: InputModifiers(event.modifierFlags.intersection(.deviceIndependentFlagsMask))
        )
        guard let command = KeyMap.command(for: press, layout: layout()) else { return false }
        return handler(command)
    }
}

/// Calls back when the system runs short of memory, so caches can be released
/// before macOS has to compress or swap them.
@MainActor
final class MemoryPressureMonitor {
    private var source: DispatchSourceMemoryPressure?

    func start(_ handler: @escaping @MainActor @Sendable () -> Void) {
        guard source == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { handler() }
        }
        source.activate()
        self.source = source
    }
}
