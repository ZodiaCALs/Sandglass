import SwiftUI
import AppKit

/// The floating Liquid Glass control bar under the photo: move, switch
/// variant, flag, zoom. Every control mirrors a single-key shortcut.
struct ControlBar: View {
    let library: Library
    let viewer: ViewerModel
    let previews: PreviewStore
    let perform: (Command) -> Void

    @Namespace private var glassSpace

    private var shot: Shot? { library.currentShot }
    private var selection: FlagSelection { library.currentSelection }
    private var compact: Bool { viewer.isCompact }

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                navigation
                variantSwitch
                flags
                zoom
            }
            .padding(6)
        }
        .fixedSize()
    }

    // MARK: Groups

    private var navigation: some View {
        HStack(spacing: 2) {
            GlassButton(help: "Previous photo  ←", isEnabled: !library.isAtStart, action: { perform(.previous) }) {
                Image(systemName: "chevron.left")
            }
            if !compact {
                Text("\(library.position) / \(library.count)")
                    .font(Theme.numeric)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 64)
                    .accessibilityLabel("Photo \(library.position) of \(library.count)")
            }
            GlassButton(help: "Next photo  →", isEnabled: !library.isAtEnd, action: { perform(.next) }) {
                Image(systemName: "chevron.right")
            }
        }
    }

    private var variantSwitch: some View {
        HStack(spacing: 2) {
            ForEach(FileKind.allCases, id: \.self) { kind in
                let exists = shot?.url(for: kind) != nil
                let active = library.kind == kind && exists
                Button {
                    perform(.showKind(kind))
                } label: {
                    HStack(spacing: 4) {
                        Text(kind.label)
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .tracking(0.4)
                        if selection.contains(.kind(kind)) {
                            Image(systemName: "flag.fill")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundStyle(active ? Color.white : Theme.flag)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 30)
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .foregroundStyle(active ? Color.white : Color.primary.opacity(exists ? 0.75 : 0.28))
                .glassEffect(
                    active ? Glass.regular.tint(Color.accentColor.opacity(0.85)).interactive() : Glass.regular.interactive(),
                    in: Capsule(style: .continuous)
                )
                .glassEffectID(kind.rawValue, in: glassSpace)
                .disabled(!exists)
                .help(exists ? "Show the \(kind.label)  T · \(kind == .jpg ? "⌘J" : "⌘K")" : "This photo has no \(kind.label)")
            }
        }
    }

    private var flags: some View {
        let kind = library.kind
        let flaggedOnScreen = selection.contains(.kind(kind))
        let available = shot?.availableKinds ?? []
        let bothFlagged = !available.isEmpty && available.allSatisfy { selection.contains(.kind($0)) }

        return HStack(spacing: 2) {
            GlassButton(
                help: "Flag the \(kind.label)  F",
                tint: flaggedOnScreen ? Theme.flag : nil,
                isEnabled: shot != nil,
                action: { perform(.flagCurrent) }
            ) {
                if compact {
                    Image(systemName: flaggedOnScreen ? "flag.fill" : "flag")
                } else {
                    Label("Flag", systemImage: flaggedOnScreen ? "flag.fill" : "flag")
                }
            }
            GlassButton(
                help: available.count > 1 ? "Keep both JPG and NEF  B" : "This photo has only one file",
                tint: bothFlagged && available.count > 1 ? Theme.flag : nil,
                isEnabled: available.count > 1,
                action: { perform(.flagBoth) }
            ) {
                if compact {
                    Image(systemName: "flag.2.crossed")
                } else {
                    Label("Both", systemImage: "flag.2.crossed")
                }
            }
            if !selection.isEmpty {
                GlassButton(help: "Clear this photo’s flags  X", action: { perform(.clearFlags) }) {
                    Image(systemName: "xmark")
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selection)
    }

    private var zoom: some View {
        HStack(spacing: 2) {
            GlassButton(help: "Zoom out  −", isEnabled: viewer.canZoom && viewer.isZoomedIn, action: { perform(.zoomOut) }) {
                Image(systemName: "minus")
            }
            Button {
                perform(.toggleZoom)
            } label: {
                HStack(spacing: 4) {
                    if viewer.isSharpening {
                        ProgressView()
                            .controlSize(.mini)
                            .transition(.opacity)
                    }
                    Text(viewer.zoomText)
                        .font(Theme.numeric)
                        .foregroundStyle(viewer.isZoomedIn ? Color.primary : Color.secondary)
                }
                .frame(minWidth: 52, minHeight: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!viewer.canZoom)
            .help(viewer.isSharpening ? "Loading full resolution…" : "Fit ↔ 100%  Z")
            GlassButton(help: "Zoom in  +", isEnabled: viewer.canZoom, action: { perform(.zoomIn) }) {
                Image(systemName: "plus")
            }
            GlassButton(
                help: "Compare JPG and NEF side by side  C",
                tint: viewer.isComparing ? Color.accentColor.opacity(0.85) : nil,
                isEnabled: shot?.isPaired == true || viewer.isComparing,
                action: { perform(.toggleCompare) }
            ) {
                Image(systemName: "rectangle.split.2x1")
            }
        }
        .animation(.easeOut(duration: 0.15), value: viewer.isSharpening)
    }
}

/// The photo's name, variants, flags and exposure, top left over the photo.
struct PhotoOverlay: View {
    let library: Library
    let metadata: MetadataStore
    /// In Compare, each pane is labelled with its own variant.
    var kindOverride: FileKind?

    var body: some View {
        if let shot = library.currentShot {
            let kind = kindOverride ?? library.kind
            let url = shot.url(for: kind)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(kindOverride == nil ? shot.displayName : kind.label)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    KindChips(
                        available: kindOverride == nil ? shot.availableKinds : [kind],
                        flagged: library.selection(for: shot)
                    )
                    if let summary = url.flatMap({ metadata.metadata(for: $0)?.exposureSummary }), kindOverride == nil {
                        Text(summary)
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .glassCapsule()

                if !shot.isPaired, kindOverride == nil {
                    Label(shot.jpgURL == nil ? "NEF only — no JPG" : "JPG only — no NEF", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Theme.flag)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .glassCapsule()
                }
            }
            .fixedSize()
            .allowsHitTesting(false)
        }
    }
}

/// What a pane shows while it has no bitmap: a spinner, or why there is nothing.
struct PreviewPlaceholder: View {
    let status: PreviewStore.Status
    let kind: FileKind
    let alternative: FileKind?
    let perform: (Command) -> Void

    @State private var showsSpinner = false

    var body: some View {
        Group {
            switch status {
            case .loading, .ready:
                ProgressView()
                    .controlSize(.regular)
                    .opacity(showsSpinner ? 1 : 0)
                    .task {
                        // Only show a spinner if loading takes a noticeable moment.
                        try? await Task.sleep(for: .milliseconds(180))
                        withAnimation(.easeIn(duration: 0.2)) { showsSpinner = true }
                    }
            case .unavailable:
                message(
                    symbol: "eye.slash",
                    title: "No preview available",
                    detail: "This \(kind.label) has no image macOS can decode.\nYou can still flag and export it."
                ) {
                    Button {
                        perform(.openInDefaultApp)
                    } label: {
                        Label("Open in Default App", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.glass)
                }
            case .missing:
                message(symbol: "questionmark.folder", title: "No \(kind.label) for this photo", detail: nil) {
                    if let alternative {
                        Button("Show \(alternative.label)") { perform(.showKind(alternative)) }
                            .buttonStyle(.glass)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func message<Actions: View>(
        symbol: String,
        title: String,
        detail: String?,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(Theme.subtitle)
            if let detail {
                Text(detail)
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            actions()
        }
        .padding(24)
        .glassPanel(cornerRadius: 22)
    }
}

/// The toast capsule.
struct ToastView: View {
    let toast: Toast

    var body: some View {
        Label(toast.text, systemImage: toast.symbol)
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassCapsule()
            .fixedSize()
            .allowsHitTesting(false)
    }
}

/// Shown over the window while a folder is read.
struct ScanningView: View {
    let folderName: String

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("Reading “\(folderName)”…")
                .font(Theme.body.weight(.medium))
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .glassPanel(cornerRadius: 18)
        .fixedSize()
    }
}
