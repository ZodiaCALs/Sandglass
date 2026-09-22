import SwiftUI
import AppKit

extension Color {
    /// Build a colour from `#RRGGBB`, or nil when the string is not usable.
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// `#RRGGBB` for persisting in `AppStorage`.
    var hexString: String {
        let colour = NSColor(self).usingColorSpace(.sRGB) ?? .black
        let r = Int((colour.redComponent * 255).rounded())
        let g = Int((colour.greenComponent * 255).rounded())
        let b = Int((colour.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// Perceived brightness, used to pick readable text over the backdrop.
    var isLight: Bool {
        let colour = NSColor(self).usingColorSpace(.sRGB) ?? .black
        let luminance = 0.2126 * colour.redComponent
            + 0.7152 * colour.greenComponent
            + 0.0722 * colour.blueComponent
        return luminance > 0.62
    }
}
