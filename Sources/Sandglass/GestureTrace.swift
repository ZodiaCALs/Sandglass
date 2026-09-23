import Foundation

/// Temporary diagnostics for the zoom gesture path.
///
/// Enabled with `SANDGLASS_TRACE=1`; silent otherwise. Remove once the gesture
/// handling is confirmed working on real hardware.
enum GestureTrace {
    static let isEnabled = ProcessInfo.processInfo.environment["SANDGLASS_TRACE"] != nil

    static func log(_ message: String) {
        guard isEnabled else { return }
        FileHandle.standardError.write(Data("GESTURE \(message)\n".utf8))
    }
}
