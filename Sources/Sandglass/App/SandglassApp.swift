import AppKit

@main
enum SandglassApp {
    @MainActor
    static func main() {
        // `Sandglass --report|--inspect|--bench <folder>` runs a diagnostic and
        // exits without opening a window.
        if let status = Diagnostics.run(arguments: CommandLine.arguments) {
            exit(status)
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        // The application holds its delegate weakly; keep it alive for the run.
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
