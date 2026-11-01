import Foundation
import Observation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A short confirmation that floats over the photo ("Flagged NEF").
struct Toast: Equatable, Identifiable {
    let id = UUID()
    let text: String
    let symbol: String
}

/// State the floating controls display: zoom readout, Compare, toasts.
///
/// The canvas owns the framing; this mirrors only what the controls show, and
/// only changes when the displayed value changes, so zooming does not redraw
/// anything but the readout.
@MainActor
@Observable
final class ViewerModel {
    private(set) var zoomText = "—"
    private(set) var isZoomedIn = false
    private(set) var canZoom = false
    /// Zoomed in beyond the screen-sized rendition while every pixel is decoded.
    private(set) var isSharpening = false
    var isComparing = false
    /// The pane is narrow, so the controls drop their text labels.
    var isCompact = false
    private(set) var toast: Toast?

    @ObservationIgnored private var toastTask: Task<Void, Never>?

    func update(with viewport: Viewport, hasImage: Bool) {
        let text = hasImage ? Format.percent(viewport.pixelMagnification) : "—"
        if text != zoomText { zoomText = text }
        if viewport.isZoomedIn != isZoomedIn { isZoomedIn = viewport.isZoomedIn }
        if hasImage != canZoom { canZoom = hasImage }
    }

    func setSharpening(_ value: Bool) {
        if value != isSharpening { isSharpening = value }
    }

    func show(_ text: String, symbol: String) {
        toast = Toast(text: text, symbol: symbol)
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1600))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}
