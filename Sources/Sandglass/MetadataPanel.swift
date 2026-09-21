import SwiftUI

/// Side panel listing whatever EXIF / camera / location data a file carries.
///
/// Read-only: the panel never writes back to the file.
struct MetadataPanel: View {
    @ObservedObject var model: LibraryModel
    var onClose: () -> Void

    private var shot: Shot? { model.currentShot }
    private var metadata: FileMetadata? {
        guard let shot else { return nil }
        return model.metadata(for: shot, kind: model.kind)
    }
    private var isLoading: Bool {
        guard let shot else { return false }
        return model.isLoadingMetadata(for: shot, kind: model.kind)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider().opacity(0.35)

            if isLoading {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Reading metadata…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let metadata, !metadata.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(metadata.sections) { section in
                            if !section.items.isEmpty {
                                sectionView(section)
                            }
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.automatic)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "doc.questionmark")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("No metadata in this file")
                        .font(.system(size: 11.5, weight: .medium))
                    Text("It carries no EXIF, camera or location data.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 258)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.vertical, 10)
        .padding(.trailing, 10)
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "info.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Info")
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
            Spacer()
            if let shot {
                KindBadge(kinds: [model.kind], flagged: model.flagFor(shot))
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 18, height: 18)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Hide the info panel  (M)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func sectionView(_ section: MetadataSection) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(section.title.uppercased(), systemImage: section.systemImage)
                .font(.system(size: 9, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)

            VStack(alignment: .leading, spacing: 5) {
                ForEach(section.items) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Text(item.label)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .frame(width: 84, alignment: .leading)
                        Text(item.value)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}
