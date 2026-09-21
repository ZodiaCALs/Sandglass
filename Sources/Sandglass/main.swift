import SwiftUI
import AppKit

@main
enum SandglassApp {
    static func main() {
        // `Sandglass --report <folder>` checks a real folder and exits without
        // opening a window. Anything else starts the normal app.
        let arguments = CommandLine.arguments
        func folderArgument(after flag: String) -> URL? {
            guard let index = arguments.firstIndex(of: flag),
                  arguments.index(after: index) < arguments.endIndex else { return nil }
            let raw = arguments[arguments.index(after: index)]
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        }
        if let url = folderArgument(after: "--report") {
            MainActor.assumeIsolated { HeadlessReport.run(folder: url) }
        }
        if let url = folderArgument(after: "--bench") {
            MainActor.assumeIsolated { HeadlessReport.bench(folder: url) }
        }
        if let url = folderArgument(after: "--flow") {
            MainActor.assumeIsolated { HeadlessReport.flow(folder: url) }
        }
        if let url = folderArgument(after: "--inspect") {
            MainActor.assumeIsolated { HeadlessReport.inspect(folder: url) }
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
