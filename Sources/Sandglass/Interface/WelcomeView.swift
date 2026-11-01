import SwiftUI
import AppKit

/// Shown while no folder is open: the app's identity, one big way in, and the
/// folders you were working on.
struct WelcomeView: View {
    let recentFolders: [URL]
    let openFolder: () -> Void
    let openRecent: (URL) -> Void

    var body: some View {
        VStack(spacing: 26) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 128, height: 128)
                .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("Sandglass")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                Text("Cull JPG + NEF pairs at the speed of your keyboard.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                Button(action: openFolder) {
                    Label("Open Folder…", systemImage: "folder")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .help("Open a folder of photos  ⌘O")

                Text("or drop a folder anywhere in this window")
                    .font(Theme.caption)
                    .foregroundStyle(.tertiary)
            }

            if !recentFolders.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("RECENT")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.9)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 4)
                    VStack(spacing: 4) {
                        ForEach(Array(recentFolders.prefix(5)), id: \.self) { url in
                            RecentFolderRow(url: url) { openRecent(url) }
                        }
                    }
                }
                .frame(width: 400)
            }
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A recent folder: icon, name and where it lives, highlighted on hover.
private struct RecentFolderRow: View {
    let url: URL
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent)
                        .font(Theme.body.weight(.medium))
                        .lineLimit(1)
                    Text((url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(isHovering ? 1 : 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(Color.primary.opacity(isHovering ? 0.08 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: 1)
        )
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help(url.path)
    }
}
