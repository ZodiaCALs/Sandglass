import SwiftUI

/// A transient message that floats above the preview (e.g. "No NEF for this shot").
struct Toast: Equatable, Identifiable {
    let id = UUID()
    let text: String
    let systemName: String
}

/// Renders the currently selected shot at the requested zoom level.
struct PreviewPane: View {
    @ObservedObject var model: LibraryModel
    @Binding var toast: Toast?

    @State private var zoomAnchor: UnitPoint = .center
    @State private var lastMagnification: CGFloat = 1

    private var shot: Shot? { model.currentShot }
    /// Full resolution when it has arrived, the instant prefetch before that.
    private var image: NSImage? {
        guard let shot else { return nil }
        return model.previewImage(for: shot, kind: model.kind)
    }
    private var isFullResolution: Bool {
        guard let shot else { return false }
        return model.hasFullResolutionPreview(for: shot, kind: model.kind)
    }

    var body: some View {
        ZStack {
            if let shot {
                GeometryReader { proxy in
                    switch model.previewState(for: shot, kind: model.kind) {
                    case .ready:
                        if let image {
                            imageView(image, in: proxy.size)
                        } else {
                            loadingPlaceholder(in: proxy.size)
                        }
                    case .loading:
                        loadingPlaceholder(in: proxy.size)
                    case .unavailable:
                        unavailable(shot, in: proxy.size)
                    case .missingVariant:
                        missingVariant(shot, in: proxy.size)
                    }
                }
                .overlay(alignment: .topLeading) { overlays(for: shot) }
            } else {
                EmptyStage()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
        .padding(10)
    }

    // MARK: Image

    @ViewBuilder
    private func imageView(_ image: NSImage, in size: CGSize) -> some View {
        let level = model.zoom

        if level <= 1.001 {
            fitted(image, in: size)
        } else {
            GeometryReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    fitted(image, in: size)
                        .scaleEffect(level, anchor: zoomAnchor)
                        .frame(width: size.width, height: size.height)
                }
                .scrollIndicators(.never)
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
    }

    private func fitted(_ image: NSImage, in size: CGSize) -> some View {
        Image(nsImage: image)
            .resizable()
            // Smooth scaling on the rare occasion the photo is larger than the
            // pane. No tint, saturation, blend or colour effect is applied, so
            // the pixels you see are the pixels in the file.
            .interpolation(.high)
            .antialiased(true)
            .aspectRatio(contentMode: .fit)
            .frame(width: size.width, height: size.height)
            .shadow(color: .black.opacity(0.28), radius: 18, y: 6)
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        model.zoom = min(max(Double(value) * lastMagnification, LibraryModel.minZoom), LibraryModel.maxZoom)
                    }
                    .onEnded { _ in lastMagnification = CGFloat(model.zoom) }
            )
            .onContinuousHover { phase in
                if case .active(let point) = phase, size.width > 0, size.height > 0 {
                    zoomAnchor = UnitPoint(
                        x: min(max(point.x / size.width, 0), 1),
                        y: min(max(point.y / size.height, 0), 1)
                    )
                }
            }
    }

    private func loadingPlaceholder(in size: CGSize) -> some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("Loading \(model.kind.label)…")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(width: size.width, height: size.height)
    }

    /// Some raw files carry no preview this system can decode. Be explicit about
    /// it and offer a way to still look at the file.
    private func unavailable(_ shot: Shot, in size: CGSize) -> some View {
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
        .frame(width: size.width, height: size.height)
    }

    private func missingVariant(_ shot: Shot, in size: CGSize) -> some View {
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
        .frame(width: size.width, height: size.height)
    }

    /// Shown while the full-resolution decode is still in flight, so it is clear
    /// that the slightly softer prefetch image is temporary.
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
    }

    private func toastView(_ toast: Toast) -> some View {
        Label(toast.text, systemImage: toast.systemName)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .glassChip(tint: .orange)
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
