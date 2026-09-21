import SwiftUI

/// Title, folder picker, session progress and the export entry point.
struct HeaderBar: View {
    @ObservedObject var model: LibraryModel
    @Binding var showingHelp: Bool
    @Binding var showingBackgroundPicker: Bool
    @Binding var showingMetadata: Bool

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
