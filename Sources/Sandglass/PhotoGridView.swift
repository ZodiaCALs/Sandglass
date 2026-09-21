import SwiftUI

/// Left-hand filmstrip: every shot in the folder, one tile each.
///
/// Both variants share a single tile, so a JPG + NEF pair never appears twice.
struct PhotoGridView: View {
    @ObservedObject var model: LibraryModel

    /// Fixed geometry rather than an adaptive grid.
    ///
    /// The strip is a fixed width, so asking for two columns of a known size is
    /// exact. An `.adaptive` grid decides its own column count from the space it
    /// is offered, which can silently drop to a single column.
    private static let tileWidth: CGFloat = 152
    private static let tileGap: CGFloat = 8
    private static let contentInset: CGFloat = 10

    /// Width of the whole strip: two tiles, the gap between them and the insets.
    static let stripWidth: CGFloat = tileWidth * 2 + tileGap + contentInset * 2

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.fixed(Self.tileWidth), spacing: Self.tileGap),
                            count: 2
                        ),
                        spacing: Self.tileGap
                    ) {
                        ForEach(Array(model.shots.enumerated()), id: \.element.id) { offset, shot in
                            PhotoCell(
                                model: model,
                                shot: shot,
                                isSelected: offset == model.index
                            )
                            .id(shot.id)
                            .onTapGesture { model.go(to: offset) }
                        }
                    }
                    .padding(Self.contentInset)
                }
                .scrollIndicators(.automatic)
                .onChange(of: model.index) { _, _ in
                    guard let current = model.currentShot else { return }
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(current.id, anchor: .center)
                    }
                }
            }

            Divider().opacity(0.4)

            HStack(spacing: 8) {
                SubtleIconButton(systemName: "arrow.up.to.line", help: "Jump to the last photo",
                                 isEnabled: !model.isEmpty) {
                    model.jumpToEnd()
                }
                SubtleIconButton(systemName: "arrow.counterclockwise", help: "Reload folder") {
                    model.reload()
                }
                Spacer()
                Text("\(model.totalCount) photo\(model.totalCount == 1 ? "" : "s")")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .frame(width: Self.stripWidth)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.vertical, 10)
        .padding(.leading, 10)
    }
}

/// One tile: the preview of the selected variant, its pairing badge and flags.
private struct PhotoCell: View {
    @ObservedObject var model: LibraryModel
    let shot: Shot
    let isSelected: Bool

    @State private var isHovering = false

    private var selection: FlagSelection { model.flagFor(shot) }

    /// Always show the JPG side in the grid when it exists — it decodes faster
    /// and keeps the strip visually stable while switching variants.
    private var tileKind: FileKind { shot.defaultKind }

    private var thumbnail: CGImage? {
        model.cachedThumbnail(for: shot, kind: tileKind)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black.opacity(0.22)

                if let thumbnail {
                    // Drawn straight from the decoded bitmap, at the size that
                    // maps one image pixel to one device pixel.
                    Image(decorative: thumbnail, scale: LibraryModel.retinaScale)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 18))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(height: 106)
            .clipped()
            .overlay(alignment: .topTrailing) {
                if !selection.isEmpty {
                    flagBadge
                        .padding(5)
                }
            }

            HStack(spacing: 5) {
                Text(shot.displayName)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 2)
            }
            .padding(.horizontal, 7)
            .padding(.top, 5)

            HStack(spacing: 4) {
                KindBadge(
                    kinds: shot.availableKinds,
                    flagged: selection,
                    dimmed: Set(FileKind.allCases).subtracting(shot.availableKinds)
                )
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .padding(.bottom, 6)
            .padding(.top, 2)
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(isSelected ? 0.10 : (isHovering ? 0.06 : 0.03)))
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.accentColor.opacity(0.95) : Color.white.opacity(0.08),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .shadow(color: .black.opacity(isSelected ? 0.22 : 0), radius: 7, y: 2)
        .onHover { isHovering = $0 }
        .onAppear {
            model.requestThumbnail(for: shot, kind: tileKind, maxPixel: ThumbnailLoader.tilePixel)
        }
        .help("\(shot.displayName) — \(shot.variantSummary)")
    }

    /// A single flag when one variant is kept, a paired flag when both are.
    private var flagBadge: some View {
        HStack(spacing: 2) {
            Image(systemName: "flag.fill")
                .font(.system(size: 8, weight: .bold))
            if selection.kinds.count > 1 {
                Image(systemName: "flag.fill")
                    .font(.system(size: 8, weight: .bold))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(
            Capsule(style: .continuous)
                .fill(Color.orange)
        )
        .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
    }
}
