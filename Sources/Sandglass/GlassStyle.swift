import SwiftUI

// MARK: - Reusable Liquid Glass styling

extension View {
    /// Standard floating panel treatment used for bars and cards.
    func glassCard(cornerRadius: CGFloat = 18, tint: Color? = nil) -> some View {
        let glass: Glass = tint.map { .regular.tint($0) } ?? .regular
        return glassEffect(glass, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// A pill-shaped glass chip, used for badges and small controls.
    func glassChip(tint: Color? = nil) -> some View {
        let glass: Glass = tint.map { .regular.tint($0) } ?? .regular
        return glassEffect(glass, in: Capsule(style: .continuous))
    }
}

/// A circular glass icon button — the app's primary control shape.
struct GlassIconButton: View {
    let systemName: String
    var help: String = ""
    var tint: Color? = nil
    var isActive: Bool = false
    var size: CGFloat = 38
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var isHovering = false

    private var resolvedTint: Color? {
        if isActive, let tint { return tint.opacity(0.55) }
        return isHovering && isEnabled ? Color.primary.opacity(0.06) : nil
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.42, weight: .medium))
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(resolvedTint).interactive(), in: Circle())
        .opacity(isEnabled ? 1 : 0.35)
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
        .help(help)
        .animation(.easeOut(duration: 0.14), value: isHovering)
        .animation(.easeOut(duration: 0.14), value: isActive)
    }
}

/// Flat icon button for dense areas such as the filmstrip footer.
struct SubtleIconButton: View {
    let systemName: String
    var help: String = ""
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 24, height: 22)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(isHovering ? 0.10 : 0))
        )
        .foregroundStyle(isEnabled ? Color.primary : Color.secondary.opacity(0.5))
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

// MARK: - Badges

/// Compact `JPG + NEF` style indicator with per-variant states.
struct KindBadge: View {
    let kinds: [FileKind]
    var flagged: FlagSelection = []
    var dimmed: Set<FileKind> = []

    var body: some View {
        HStack(spacing: 3) {
            ForEach(kinds, id: \.self) { kind in
                Text(kind.label)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(0.4)
                    .foregroundStyle(foreground(for: kind))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(background(for: kind))
                    )
            }
        }
    }

    private func foreground(for kind: FileKind) -> Color {
        if dimmed.contains(kind) { return .secondary.opacity(0.5) }
        return flagged.contains(.kind(kind)) ? .white : .primary.opacity(0.75)
    }

    private func background(for kind: FileKind) -> Color {
        if dimmed.contains(kind) { return Color.primary.opacity(0.05) }
        return flagged.contains(.kind(kind)) ? Color.orange : Color.primary.opacity(0.12)
    }
}

/// Small pill used for the "JPG + NEF" pairing indicator in the header.
struct InfoChip: View {
    let systemName: String
    let text: String
    var tint: Color? = nil

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(tint ?? .secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .glassChip()
    }
}
