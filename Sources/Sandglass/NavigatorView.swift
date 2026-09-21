import SwiftUI

/// A small navigator in the corner of the preview.
///
/// Shows the whole photo with a rectangle marking the part currently on screen,
/// so when you are zoomed into a corner you can still see where you are. Clicking
/// or dragging inside it moves the view.
struct NavigatorView: View {
    /// The whole photo, used as the map.
    let image: CGImage?
    /// The visible portion, in normalised image coordinates.
    let region: CGRect
    /// Move the view so it is centred on this normalised point.
    let onMove: (CGPoint) -> Void

    private let width: CGFloat = 132

    private var aspect: CGFloat {
        guard let image, image.height > 0 else { return 1.5 }
        return CGFloat(image.width) / CGFloat(image.height)
    }

    private var size: CGSize {
        CGSize(width: width, height: max(38, (width / aspect).rounded()))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .clipped()
            } else {
                Rectangle()
                    .fill(Color.black.opacity(0.5))
                    .frame(width: size.width, height: size.height)
            }

            // The portion of the photo currently filling the pane.
            Rectangle()
                .fill(Color.white.opacity(0.16))
                .overlay(
                    Rectangle().strokeBorder(Color.white, lineWidth: 1.5)
                )
                .frame(
                    width: max(6, size.width * region.width),
                    height: max(6, size.height * region.height)
                )
                .offset(
                    x: size.width * region.minX,
                    y: size.height * region.minY
                )
                .shadow(color: .black.opacity(0.5), radius: 2)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    // Map the click into normalised image coordinates.
                    let point = CGPoint(
                        x: min(max(value.location.x / size.width, 0), 1),
                        y: min(max(value.location.y / size.height, 0), 1)
                    )
                    onMove(point)
                }
        )
        .help("Where you are in the photo — click or drag to move")
    }
}
