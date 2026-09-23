import SwiftUI

/// Title, folder picker, session progress and the export entry point.
struct HeaderBar: View {
    @ObservedObject var model: LibraryModel
    @Binding var layoutModeRaw: String
    @Binding var showingHelp: Bool
    @Binding var showingBackgroundPicker: Bool
    @Binding var showingMetadata: Bool
    @State private var showingLayoutPicker = false

    var body: some View {
        HStack(spacing: 12) {
            brand
            folderChip

            Spacer(minLength: 8)

            if !model.isEmpty {
                progress
                InfoChip(
                    systemName: "flag.fill",
                    text: "\(model.flaggedCount)",
                    tint: model.flaggedCount > 0 ? .orange : .secondary
                )
                InfoChip(
                    systemName: "photo.on.rectangle.angled",
                    text: "\(model.flaggedFileCount) file\(model.flaggedFileCount == 1 ? "" : "s")"
                )
            }

            layoutPicker

            GlassIconButton(
                systemName: "circle.lefthalf.filled",
                help: "Background colour or picture",
                size: 34
            ) {
                showingBackgroundPicker.toggle()
            }

            GlassIconButton(
                systemName: "info.circle",
                help: "Show file information  (M)",
                tint: .accentColor,
                isActive: showingMetadata,
                size: 34
            ) {
                showingMetadata.toggle()
            }

            GlassIconButton(
                systemName: "questionmark",
                help: "Keyboard shortcuts",
                size: 34
            ) {
                showingHelp = true
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .glassCard(cornerRadius: 20)
    }

    // MARK: Pieces

    private var brand: some View {
        HStack(spacing: 8) {
            Image(systemName: "hourglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.orange, .pink],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            Text("Sandglass")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
        }
    }

    /// Choose where the filmstrip sits.
    ///
    /// A popover rather than a menu, so the current mode is visible at a glance
    /// and switching is one click.
    private var layoutPicker: some View {
        Button {
            showingLayoutPicker.toggle()
        } label: {
            Image(systemName: selectedLayout.systemImage)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .help("Layout: \(selectedLayout.label) — click to change")
        .popover(isPresented: $showingLayoutPicker, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Layout")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                ForEach(LayoutMode.allCases) { mode in
                    Button {
                        layoutModeRaw = mode.rawValue
                        showingLayoutPicker = false
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: mode.systemImage)
                                .frame(width: 18)
                            Text(mode.label)
                                .font(.system(size: 12))
                            Spacer(minLength: 12)
                            if mode == selectedLayout {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                            }
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(mode == selectedLayout ? Color.accentColor.opacity(0.22) : .clear)
                        )
                    }
                    .buttonStyle(.plain)
                    .help(mode.help)
                }
            }
            .padding(14)
            .frame(width: 190)
        }
    }

    private var selectedLayout: LayoutMode {
        LayoutMode(rawValue: layoutModeRaw) ?? .filmstripLeft
    }

    private var folderChip: some View {
        Button {
            model.chooseFolder()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "folder")
                    .font(.system(size: 11, weight: .semibold))
                Text(model.folder.map { $0.lastPathComponent } ?? "Choose a folder…")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .glassChip()
        .help(model.folder.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "Open a folder of photos")
    }

    private var progress: some View {
        HStack(spacing: 8) {
            Text("\(model.position) / \(model.totalCount)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            // Reviewed progress, so you can see how much of the folder is left.
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.orange.opacity(0.9), .pink.opacity(0.8)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(96 * model.progressFraction, 2))
            }
            .frame(width: 96, height: 4)
            .animation(.easeOut(duration: 0.2), value: model.progressFraction)
        }
    }
}
