import SwiftUI
import AppKit

/// Sandglass's visual language.
///
/// macOS 26 Liquid Glass for everything that floats over the photo — the
/// control bar, the overlay, the navigator — so the picture stays the brightest
/// thing on screen and the chrome refracts it rather than covering it. From
/// Microsoft's Fluent design come the quieter conventions: layered cards with a
/// hairline stroke for grouped content, a gentle hover highlight on everything
/// clickable, a clear four-step type ramp, and an accent-coloured focus ring
/// around the selection.
enum Theme {

    // MARK: Colour

    /// Flags are amber: warm, distinct from the system accent, readable on glass.
    static let flag = Color(red: 1.0, green: 0.62, blue: 0.04)
    static let flagNS = NSColor(srgbRed: 1.0, green: 0.62, blue: 0.04, alpha: 1)

    /// Fluent-style card fill and hairline stroke, adapting to light and dark.
    static let cardFill = Color.primary.opacity(0.045)
    static let cardStroke = Color.primary.opacity(0.09)

    // MARK: Shape

    static let controlRadius: CGFloat = 8
    static let cardRadius: CGFloat = 12
    static let panelRadius: CGFloat = 20

    // MARK: Type ramp

    static let title = Font.system(size: 22, weight: .semibold, design: .rounded)
    static let subtitle = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 12.5)
    static let caption = Font.system(size: 11)
    static let badge = Font.system(size: 9, weight: .bold, design: .rounded)
    static let numeric = Font.system(size: 11.5, weight: .semibold, design: .rounded).monospacedDigit()
}

extension View {

    /// A floating Liquid Glass capsule.
    func glassCapsule(tint: Color? = nil, interactive: Bool = false) -> some View {
        glassEffect(
            interactive ? Glass.regular.tint(tint).interactive() : Glass.regular.tint(tint),
            in: Capsule(style: .continuous)
        )
    }

    /// A floating Liquid Glass panel with continuous corners.
    func glassPanel(cornerRadius: CGFloat = Theme.panelRadius, tint: Color? = nil) -> some View {
        glassEffect(Glass.regular.tint(tint), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// A Fluent-style card: soft fill, hairline stroke.
    func card(cornerRadius: CGFloat = Theme.cardRadius) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Theme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: 1)
        )
    }
}

/// A glass button used across the floating controls.
///
/// Every control is a capsule of the same height, so groups line up; the label
/// can be an icon, text or both.
struct GlassButton<Label: View>: View {
    var help: String
    var tint: Color?
    var isEnabled = true
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            label()
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 11)
                .frame(minWidth: 32, minHeight: 30)
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint == nil ? Color.primary.opacity(isEnabled ? 0.9 : 0.35) : Color.white)
        .glassCapsule(tint: tint ?? (isHovering && isEnabled ? Color.primary.opacity(0.08) : nil), interactive: isEnabled)
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
        .help(help)
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

/// "JPG" / "NEF" chips: amber when flagged, plain when present, faint when missing.
struct KindChips: View {
    let available: [FileKind]
    let flagged: FlagSelection
    var showsMissing = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(showsMissing ? FileKind.allCases : available, id: \.self) { kind in
                let present = available.contains(kind)
                let isFlagged = flagged.contains(.kind(kind))
                Text(kind.label)
                    .font(Theme.badge)
                    .tracking(0.5)
                    .foregroundStyle(isFlagged ? Color.white : Color.primary.opacity(present ? 0.8 : 0.3))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(isFlagged ? Theme.flag : Color.primary.opacity(present ? 0.12 : 0.04))
                    )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let flaggedText = flagged.isEmpty ? "not flagged" : "flagged \(flagged.label)"
        return "\(available.map(\.label).joined(separator: " and ")), \(flaggedText)"
    }
}

// MARK: - AppKit helpers

/// A view whose coordinates start at the top left, like the rest of the layout code.
class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// An `NSHostingView` that reports when its SwiftUI content changes size, so
/// manually laid-out overlays can follow it.
final class OverlayHostingView<Content: View>: NSHostingView<Content> {
    var onSizeChange: (() -> Void)?
    /// Purely informational overlays let clicks and scrolls reach the photo beneath.
    var passesEventsThrough = false

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onSizeChange?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        passesEventsThrough ? nil : super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension NSImage {
    /// An SF Symbol, with a fallback so a missing name can never crash.
    static func symbol(_ name: String, description: String? = nil, fallback: String = "circle") -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: description)
            ?? NSImage(systemSymbolName: fallback, accessibilityDescription: description)
            ?? NSImage()
    }
}

extension NSColor {
    convenience init(_ color: RGBColor, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat(color.red), green: CGFloat(color.green), blue: CGFloat(color.blue), alpha: alpha)
    }
}

extension InputModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        var modifiers: InputModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        self = modifiers
    }
}
