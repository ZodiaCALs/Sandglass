import SwiftUI

/// The inspector: what is kept, then everything the file says about itself,
/// grouped into cards.
struct InspectorView: View {
    let library: Library
    let metadata: MetadataStore
    let perform: (Command) -> Void

    var body: some View {
        Group {
            if let shot = library.currentShot, let url = library.currentURL {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header(shot)
                        keepCard(shot)
                        details(for: url)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 16)
                }
                .onAppear { metadata.load(url) }
                .onChange(of: url) { _, newURL in metadata.load(newURL) }
            } else {
                ContentUnavailableView(
                    "No Photo",
                    systemImage: "photo.on.rectangle",
                    description: Text("Open a folder to see a photo’s details.")
                )
            }
        }
        .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
    }

    private func header(_ shot: Shot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(shot.displayName)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                KindChips(available: shot.availableKinds, flagged: library.selection(for: shot), showsMissing: true)
                Text(shot.variantSummary)
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// One switch per variant: exactly what will be exported.
    private func keepCard(_ shot: Shot) -> some View {
        let selection = library.selection(for: shot)
        return VStack(alignment: .leading, spacing: 10) {
            Label("Keep", systemImage: "flag")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(.secondary)
            ForEach(FileKind.allCases, id: \.self) { kind in
                let exists = shot.url(for: kind) != nil
                Toggle(isOn: Binding(
                    get: { selection.contains(.kind(kind)) },
                    set: { _ in perform(.toggleFlag(kind)) }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(kind.label)
                            .font(Theme.body.weight(.semibold))
                        Text(exists ? (shot.url(for: kind)?.lastPathComponent ?? "") : "No file")
                            .font(Theme.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .toggleStyle(.switch)
                .tint(Theme.flag)
                .disabled(!exists)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    @ViewBuilder
    private func details(for url: URL) -> some View {
        if let data = metadata.metadata(for: url) {
            if data.isEmpty {
                Text("This file carries no metadata.")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()
            } else {
                ForEach(data.sections) { section in
                    sectionCard(section)
                }
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading metadata…")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
        }
    }

    private func sectionCard(_ section: MetadataSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(section.title, systemImage: section.systemImage)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(section.items, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(item.label)
                            .font(Theme.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 92, alignment: .leading)
                        Text(item.value)
                            .font(Theme.caption.weight(.medium))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
