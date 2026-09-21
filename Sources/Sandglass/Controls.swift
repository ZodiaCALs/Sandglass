import SwiftUI

/// Left side of the bottom bar: where you are in the folder.
struct PositionReadout: View {
    @ObservedObject var model: LibraryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Text("\(model.position)")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("/ \(model.totalCount)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Text(model.isEmpty ? "No folder open" : "\(model.reviewed.count) reviewed")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .frame(width: 112, alignment: .leading)
    }
}

/// The two-variant switch: click a side, or press T to flip.
struct VariantToggle: View {
    @ObservedObject var model: LibraryModel
    var onMessage: (String, String) -> Void

    @Namespace private var namespace

    private var available: [FileKind] {
        model.currentShot?.availableKinds ?? FileKind.allCases
    }

    var body: some View {
        GlassEffectContainer(spacing: 5) {
            HStack(spacing: 5) {
                if available.count == 1, let only = available.first {
                    singleButton(only)
                } else {
                    ForEach(FileKind.allCases, id: \.self) { kind in
                        segment(kind)
                    }
                }
            }
        }
    }

    /// Both variants exist: a real segmented switch with a sliding selection.
    private func segment(_ kind: FileKind) -> some View {
        let isActive = model.kind == kind
        let isFlagged = model.selectionForCurrent.contains(.kind(kind))

        return Button {
            if !model.setKind(kind) {
                onMessage("No \(kind.label) file for this shot", "exclamationmark.triangle")
            }
        } label: {
            HStack(spacing: 6) {
                Text(kind.label)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                if isFlagged {
                    Image(systemName: "flag.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 8)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .glassEffect(
            isActive
                ? .regular.tint(Color.accentColor.opacity(0.5)).interactive()
                : .regular.interactive(),
            in: Capsule(style: .continuous)
        )
        .glassEffectID(kind.rawValue, in: namespace)
        .foregroundStyle(isActive ? Color.white : Color.primary.opacity(0.75))
        .help("Show the \(kind.label) version  (\(kind == .jpg ? "⌘J" : "⌘K"))")
    }

    /// Only one variant on disk: show it as a switch to the missing one.
    private func singleButton(_ only: FileKind) -> some View {
        let missing = only.other
        return Button {
            onMessage("Only the \(only.label) exists for this shot", "info.circle")
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 10, weight: .bold))
                Text("Switch to \(missing.label)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 8)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule(style: .continuous))
        .foregroundStyle(.secondary)
        .help("This shot has no \(missing.label) file")
    }
}

/// Flag controls: keep the variant on screen, both of them, or clear.
struct FlagControls: View {
    @ObservedObject var model: LibraryModel
    var onMessage: (String, String) -> Void

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                currentFlagButton
                bothButton
                if model.isCurrentFlagged {
                    GlassIconButton(
                        systemName: "flag.slash",
                        help: "Clear flags for this photo",
                        size: 34
                    ) {
                        guard let shot = model.currentShot else { return }
                        model.setFlag([], for: shot.id)
                        onMessage("Cleared flags", "flag.slash")
                    }
                }
            }
        }
    }

    /// Flags exactly what is on screen — JPG while viewing JPG, NEF while viewing NEF.
    private var currentFlagButton: some View {
        let kind = model.kind
        let isFlagged = model.selectionForCurrent.contains(.kind(kind))

        return Button {
            guard let shot = model.currentShot, shot.url(for: kind) != nil else {
                onMessage("No \(kind.label) file to flag", "exclamationmark.triangle")
                return
            }
            model.toggleFlag()
            onMessage(
                isFlagged ? "Unflagged \(kind.label)" : "Flagged \(kind.label)",
                isFlagged ? "flag.slash" : "flag.fill"
            )
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isFlagged ? "flag.fill" : "flag")
                    .font(.system(size: 12, weight: .semibold))
                Text("Flag \(kind.label)")
                    .font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular.tint(isFlagged ? Color.orange.opacity(0.72) : nil).interactive(),
            in: Capsule(style: .continuous)
        )
        .foregroundStyle(isFlagged ? Color.white : Color.primary.opacity(0.85))
        .help("Flag the \(kind.label) version of this photo  (F)")
    }

    /// One click to keep both halves of the pair.
    private var bothButton: some View {
        let available = model.currentShot?.availableKinds ?? []
        let allFlagged = !available.isEmpty
            && available.allSatisfy { model.selectionForCurrent.contains(.kind($0)) }
        let canFlagBoth = available.count > 1

        return Button {
            guard model.currentShot != nil else { return }
            model.toggleFlagBoth()
            if allFlagged {
                onMessage("Cleared flags", "flag.slash")
            } else {
                onMessage("Flagged \(available.map(\.label).joined(separator: " + "))", "flag.fill")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: allFlagged ? "flag.fill" : "flag.badge.ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                Text("Both")
                    .font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular.tint(allFlagged ? Color.orange.opacity(0.72) : nil).interactive(),
            in: Capsule(style: .continuous)
        )
        .foregroundStyle(allFlagged ? Color.white : Color.primary.opacity(0.85))
        .opacity(canFlagBoth ? 1 : 0.35)
        .disabled(!canFlagBoth)
        .help(canFlagBoth
              ? "Keep both JPG and NEF for this photo  (B)"
              : "This shot has only one file, so there is nothing to pair")
    }
}

/// Step through the folder.
struct NavigationControls: View {
    @ObservedObject var model: LibraryModel

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                GlassIconButton(
                    systemName: "chevron.left",
                    help: "Previous photo  (←)",
                    size: 36,
                    isEnabled: model.index > 0
                ) {
                    model.previous()
                }

                // Flagging while advancing is the fastest way through a folder.
                GlassIconButton(
                    systemName: "flag.fill",
                    help: "Flag \(model.kind.label) and go to the next photo",
                    tint: .orange,
                    size: 36,
                    isEnabled: !model.isEmpty
                ) {
                    guard model.currentShot != nil else { return }
                    model.toggleFlag()
                    model.next()
                }

                GlassIconButton(
                    systemName: "chevron.right",
                    help: "Next photo  (→)",
                    size: 36,
                    isEnabled: !model.isAtEnd
                ) {
                    model.next()
                }
            }
        }
    }
}

/// Zoom slider plus a percentage readout that resets on click.
struct ZoomControls: View {
    @ObservedObject var model: LibraryModel

    private let range: ClosedRange<Double> = LibraryModel.minZoom...LibraryModel.maxZoom

    var body: some View {
        HStack(spacing: 8) {
            GlassIconButton(systemName: "minus.magnifyingglass", help: "Zoom out  (−)", size: 30) {
                model.zoom = max(model.zoom / 1.25, range.lowerBound)
            }

            Slider(value: $model.zoom, in: range)
                .controlSize(.mini)
                .frame(width: 92)
                .help("Zoom the preview")

            Button {
                model.zoom = 1
            } label: {
                Text("\(Int((model.zoom * 100).rounded()))%")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .frame(width: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.zoom > 1.001 ? Color.primary : Color.secondary)
            .help("Reset zoom to 100%  (0)")

            GlassIconButton(systemName: "plus.magnifyingglass", help: "Zoom in  (+)", size: 30) {
                model.zoom = min(model.zoom * 1.25, range.upperBound)
            }
        }
        .frame(width: 232, alignment: .trailing)
    }
}

/// The floating bottom bar that drives the whole culling loop.
struct ControlBar: View {
    @ObservedObject var model: LibraryModel
    @Binding var showingExportSheet: Bool
    @Binding var showingMetadata: Bool
    var onMessage: (String, String) -> Void

    var body: some View {
        HStack(spacing: 12) {
            PositionReadout(model: model)

            Spacer(minLength: 6)

            VariantToggle(model: model, onMessage: onMessage)

            Divider().frame(height: 24).opacity(0.35)

            FlagControls(model: model, onMessage: onMessage)

            Divider().frame(height: 24).opacity(0.35)

            NavigationControls(model: model)

            Spacer(minLength: 6)

            exportButton

            GlassIconButton(
                systemName: "info.circle",
                help: "Show file information  (M)",
                tint: .accentColor,
                isActive: showingMetadata,
                size: 34
            ) {
                showingMetadata.toggle()
            }

            ZoomControls(model: model)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassCard(cornerRadius: 22)
    }

    private var exportButton: some View {
        Button {
            if model.flaggedCount == 0 {
                onMessage("Flag some photos first", "flag")
            } else {
                showingExportSheet = true
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 12, weight: .semibold))
                Text(model.flaggedCount > 0 ? "Export \(model.flaggedCount)" : "Export")
                    .font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular.tint(model.flaggedCount > 0 ? Color.orange.opacity(0.65) : nil).interactive(),
            in: Capsule(style: .continuous)
        )
        .foregroundStyle(model.flaggedCount > 0 ? Color.white : Color.primary.opacity(0.6))
        .help(model.flaggedCount > 0
              ? "Save flagged photos to a folder you choose  (⌘E)"
              : "Flag photos as you review, then export them here")
    }
}
