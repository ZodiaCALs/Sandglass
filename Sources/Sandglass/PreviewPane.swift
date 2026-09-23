import SwiftUI

/// A transient message that floats above the preview (e.g. "No NEF for this shot").
struct Toast: Equatable, Identifiable {
    let id = UUID()
    let text: String
    let systemName: String
}

/// Shared state for the zoom controls.
///
/// The canvas owns the framing while a gesture is running — routing every frame
/// through SwiftUI is what made zooming lag. This class mirrors the value so
/// controls can display it and send deliberate changes back.
@MainActor
final class ZoomBridge: ObservableObject {
    /// Current magnification, kept in step with the canvas.
    ///
    /// This is the value the readout renders, so it is updated both when a
    /// gesture changes the zoom and when a control asks for a new one. Relying on
    /// the canvas to report back alone left the readout stale.
    @Published private(set) var level: CGFloat = 1

    weak var canvas: ImageCanvasView?

    /// Ask the canvas to change zoom, and record the result immediately.
    func setFromUI(_ value: CGFloat) {
        GestureTrace.log("bridge.setFromUI(\(value)) canvasAttached=\(canvas != nil)")
        guard let canvas else {
            report(value)
            return
        }
        canvas.setZoomFromUI(value)
        // Read the canvas back rather than assuming: it clamps, and a gesture may
        // have moved it since. This is what keeps the readout truthful.
        report(canvas.zoom)
    }

    /// Accept a value from the canvas.
    func report(_ value: CGFloat) {
        GestureTrace.log("bridge.report(\(value)) current=\(level)")
        guard value.isFinite, abs(level - value) > 0.0005 else { return }
        level = value
    }

    /// Remember the live canvas so controls can drive it directly. Weak: the view
    /// hierarchy owns it.
    func attach(canvas: ImageCanvasView) {
        self.canvas = canvas
        report(canvas.zoom)
    }
}

/// Renders the selected shot at native resolution with live zoom and pan.
struct PreviewPane: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject var zoom: ZoomBridge
    @Binding var toast: Toast?

    /// Which part of the photo is on screen, in normalised image coordinates.
    @State private var visibleRegion = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// Bumped on every viewport change so the navigator always redraws, even when
    /// the rectangle itself compares equal.
    @State private var viewportTick = 0

    /// Above this the photo no longer fits the pane, so the navigator is useful.
    private static let navigatorThreshold: CGFloat = 1.01
    private var isZoomedIn: Bool { zoom.level > Self.navigatorThreshold }

    private var shot: Shot? { model.currentShot }

    /// The decoded bitmap for the current file, if it has arrived.
    private var image: CGImage? {
        guard let shot else { return nil }
        return model.previewCGImage(for: shot, kind: model.kind)
    }

    private var isFullResolution: Bool {
        guard let shot else { return false }
        return model.hasFullResolutionPreview(for: shot, kind: model.kind)
    }

    var body: some View {
        ZStack {
            if let shot {
                stage(for: shot)
                    .overlay(alignment: .topLeading) { overlays(for: shot) }
                    .overlay(alignment: .bottomTrailing) { navigator }
            } else {
                EmptyStage()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(alignment: .bottom) {
            if let toast {
                toastView(toast)
                    .padding(.bottom, 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if image != nil && !isFullResolution {
                sharpeningIndicator
                    .padding(18)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: isFullResolution)
        .animation(.easeOut(duration: 0.18), value: isZoomedIn)
        .padding(6)
    }

    /// A small map for the navigator, kept separate from the full-resolution
    /// preview so the navigator's redraws stay cheap while you zoom.
    private var navigatorMap: CGImage? {
        guard let shot else { return nil }
        return model.navigatorImage(for: shot, kind: model.kind) ?? image
    }

    /// Shown only while zoomed in, where knowing your position actually matters.
    @ViewBuilder
    private var navigator: some View {
        if isZoomedIn, let map = navigatorMap {
            NavigatorView(image: map, region: visibleRegion) { point in
                zoom.canvas?.centreOn(normalised: point)
            }
            .padding(14)
            .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .bottomTrailing)))
        }
    }

    /// The image surface. Zoom and pan happen entirely inside this layer-backed
    /// view, so the compositor handles them instead of SwiftUI's layout pass.
    @ViewBuilder
    private func stage(for shot: Shot) -> some View {
        switch model.previewState(for: shot, kind: model.kind) {
        case .ready:
            canvas
        case .loading:
            loadingPlaceholder
        case .unavailable:
            unavailable(shot)
        case .missingVariant:
            missingVariant(shot)
        }
    }

    private var canvas: some View {
        ImageCanvas(
            image: image,
            // Only the photo identity resets the framing.
            resetToken: "\(shot?.id ?? "")|\(model.kind.rawValue)",
            // The revision signals a replaced bitmap, which must not reset zoom.
            bitmapRevision: model.previewRevision,
            onZoomChange: { level in
                zoom.report(level)
                // Reveal more detail only once the user actually zooms in.
                model.requestSharperPreviewWhileZoomed(zoomLevel: level)
            },
            onViewportChange: { region, tick in
                // Publish the region together with its tick. The tick is what
                // guarantees the navigator redraws, so the rectangle keeps up
                // with zooming instead of appearing stuck.
                if abs(region.width - visibleRegion.width) > 0.0005
                    || abs(region.minX - visibleRegion.minX) > 0.0005
                    || abs(region.minY - visibleRegion.minY) > 0.0005
                    || tick != viewportTick {
                    visibleRegion = region
                    viewportTick = tick
                }
            },
            onCanvasReady: { canvas in
                zoom.attach(canvas: canvas)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        // The model sizes its decodes from the real pane, so a big window gets
        // more pixels and a small one stops paying for them.
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            model.reportCanvasSize(size)
        }
    }

    // MARK: States

    private var loadingPlaceholder: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("Loading \(model.kind.label)…")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Some raw files carry no preview this system can decode. Be explicit about
    /// it and offer a way to still look at the file.
    private func unavailable(_ shot: Shot) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "eye.slash")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            VStack(spacing: 4) {
                Text("No preview available")
                    .font(.system(size: 13, weight: .semibold))
                Text("This \(model.kind.label) has no embedded preview that macOS can read.\nYou can still flag and export it.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                model.openExternally(shot, kind: model.kind)
            } label: {
                Label("Open in Default App", systemImage: "arrow.up.forward.app")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.glass)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func missingVariant(_ shot: Shot) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "questionmark.folder")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
            Text("No \(model.kind.label) file for this photo")
                .font(.system(size: 12, weight: .medium))
            if let fallback = shot.availableKinds.first {
                Button("Show \(fallback.label)") {
                    model.setKind(fallback)
                }
                .buttonStyle(.glass)
                .font(.system(size: 11, weight: .medium))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Shown while the full-resolution decode is still in flight, so it is clear
    /// that the softer prefetch image is temporary.
    private var sharpeningIndicator: some View {
        HStack(spacing: 5) {
            ProgressView().controlSize(.mini)
            Text("Loading full resolution…")
                .font(.system(size: 10, weight: .medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .glassChip()
        .allowsHitTesting(false)
    }

    // MARK: Overlays

    @ViewBuilder
    private func overlays(for shot: Shot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Text(shot.displayName)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                KindBadge(
                    kinds: shot.availableKinds,
                    flagged: model.flagFor(shot),
                    dimmed: Set(FileKind.allCases).subtracting(shot.availableKinds)
                )
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .glassChip()

            if !shot.isPaired {
                Label(
                    shot.jpgURL == nil ? "NEF only — no JPG sibling" : "JPG only — no NEF sibling",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.orange)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .glassChip()
            }
        }
        .padding(16)
        .allowsHitTesting(false)
    }

    private func toastView(_ toast: Toast) -> some View {
        Label(toast.text, systemImage: toast.systemName)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .glassChip(tint: .orange)
            .allowsHitTesting(false)
    }
}

/// Shown before any folder is opened.
struct EmptyStage: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "hourglass")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.orange.opacity(0.9), .pink.opacity(0.7)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            VStack(spacing: 6) {
                Text("Sandglass")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                Text("Open a folder to cull JPG and NEF pairs side by side.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
