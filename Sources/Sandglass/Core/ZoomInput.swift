import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Modifier keys, independent of AppKit so input rules can be tested anywhere.
struct InputModifiers: OptionSet, Hashable, Sendable {
    let rawValue: Int

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    static let shift = InputModifiers(rawValue: 1 << 0)
    static let control = InputModifiers(rawValue: 1 << 1)
    static let option = InputModifiers(rawValue: 1 << 2)
    static let command = InputModifiers(rawValue: 1 << 3)
}

/// What a scroll event over the photo should do.
enum ScrollIntent: Equatable, Sendable {
    case zoom(factor: CGFloat)
    case pan(dx: CGFloat, dy: CGFloat)
    case none
}

/// Turns raw scroll and pinch input into zoom and pan.
enum ZoomInput {

    /// One notch of a mouse wheel changes the magnification by this factor.
    static let wheelNotchFactor: CGFloat = 1.2
    /// Zoom sensitivity for precise deltas (trackpad, Magic Mouse), per point.
    static let preciseZoomRate: CGFloat = 0.01
    /// Points moved per wheel line when a wheel pans (with Shift).
    static let lineStep: CGFloat = 24

    /// Decide what a scroll means.
    ///
    /// - A mouse wheel (no precise deltas) zooms about the pointer, with Shift it
    ///   pans sideways.
    /// - A trackpad or Magic Mouse (precise deltas) pans, following the fingers;
    ///   holding ⌘, ⌥ or ⌃ makes it zoom instead.
    /// - Zoom direction is physical: rolling the wheel away from you, or pushing
    ///   two fingers up, zooms in — whatever the "natural scrolling" preference is.
    ///   The deltas AppKit reports are flipped by that preference, which is why
    ///   `isDirectionInverted` is needed to undo it.
    /// - Each event's factor is bounded and multiplicative, so a fast flick can
    ///   never produce a zero or negative zoom and zooming in then out by the same
    ///   amount returns exactly to where it started.
    static func interpret(
        deltaX: CGFloat,
        deltaY: CGFloat,
        hasPreciseDeltas: Bool,
        isDirectionInverted: Bool,
        modifiers: InputModifiers
    ) -> ScrollIntent {
        guard deltaX.isFinite, deltaY.isFinite else { return .none }
        let wantsZoom = !modifiers.intersection([.command, .option, .control]).isEmpty

        if hasPreciseDeltas && !wantsZoom {
            guard deltaX != 0 || deltaY != 0 else { return .none }
            return .pan(dx: deltaX, dy: deltaY)
        }

        if !hasPreciseDeltas && !wantsZoom && modifiers.contains(.shift) {
            let amount = deltaX != 0 ? deltaX : deltaY
            guard amount != 0 else { return .none }
            return .pan(dx: amount * lineStep, dy: 0)
        }

        let physical = isDirectionInverted ? -deltaY : deltaY
        guard physical != 0 else { return .none }
        let factor: CGFloat
        if hasPreciseDeltas {
            factor = CGFloat(exp(Double(min(max(physical, -40), 40) * preciseZoomRate)))
        } else {
            factor = CGFloat(pow(Double(wheelNotchFactor), Double(min(max(physical, -4), 4))))
        }
        return .zoom(factor: factor)
    }

    /// Zoom factor for one pinch event (`NSEvent.magnification`), bounded.
    static func pinchFactor(_ magnification: CGFloat) -> CGFloat {
        guard magnification.isFinite else { return 1 }
        return min(max(1 + magnification, 0.5), 2)
    }
}
