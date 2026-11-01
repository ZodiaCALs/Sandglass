import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Text formatting shared by the interface and the diagnostics.
enum Format {

    static func bytes(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: count)
    }

    /// A zoom level as people say it: "100%", "33%", "6.3%".
    static func percent(_ magnification: CGFloat) -> String {
        guard magnification.isFinite, magnification > 0 else { return "—" }
        let value = Double(magnification) * 100
        if value < 9.95 {
            // Round half away from zero (6.25 → 6.3); printf would round to even.
            let tenths = (value * 10).rounded() / 10
            return String(format: "%.1f%%", tenths)
        }
        return "\(Int(value.rounded()))%"
    }

    static func pixels(_ width: Int, _ height: Int) -> String {
        "\(width) × \(height)"
    }

    static func megapixels(_ width: Int, _ height: Int) -> String {
        let value = Double(width * height) / 1_000_000
        return value >= 10 ? "\(Int(value.rounded())) MP" : String(format: "%.1f MP", value)
    }

    /// Trim trailing zeros so 2.80 reads as 2.8 and 4.0 as 4.
    static func trim(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }

    /// Shutter speeds the way cameras show them: 1/250 s, 2 s.
    static func shutter(_ seconds: Double) -> String {
        guard seconds > 0, seconds.isFinite else { return "—" }
        if seconds >= 0.3 { return "\(trim(seconds)) s" }
        return "1/\(Int((1 / seconds).rounded())) s"
    }

    static func aperture(_ value: Double) -> String {
        "ƒ/\(trim(value))"
    }

    static func exposureProgram(_ value: Int) -> String {
        switch value {
        case 1: "Manual"
        case 2: "Program AE"
        case 3: "Aperture priority"
        case 4: "Shutter priority"
        case 5: "Creative"
        case 6: "Action"
        case 7: "Portrait"
        case 8: "Landscape"
        default: "Not defined"
        }
    }

    static func meteringMode(_ value: Int) -> String {
        switch value {
        case 1: "Average"
        case 2: "Centre-weighted"
        case 3: "Spot"
        case 4: "Multi-spot"
        case 5: "Matrix"
        case 6: "Partial"
        default: "Unknown"
        }
    }

    static func orientation(_ value: Int) -> String {
        switch value {
        case 1: "Normal"
        case 2: "Mirrored"
        case 3: "Rotated 180°"
        case 4: "Mirrored vertically"
        case 5: "Mirrored, rotated 90° anticlockwise"
        case 6: "Rotated 90° clockwise"
        case 7: "Mirrored, rotated 90° clockwise"
        case 8: "Rotated 90° anticlockwise"
        default: "Unknown"
        }
    }
}
