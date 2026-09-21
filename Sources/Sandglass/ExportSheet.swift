import SwiftUI

/// Confirms exactly what will be written before asking for a destination folder.
///
/// This is where the JPG / NEF / both rule is made visible to the user.
struct ExportSheet: View {
    @ObservedObject var model: LibraryModel
    var onComplete: () -> Void

    @AppStorage("exportMode") private var modeRaw: String = Exporter.Mode.copy.rawValue
    @State private var isRunning = false

    private var mode: Exporter.Mode {
        Exporter.Mode(rawValue: modeRaw) ?? .copy
    }

    private var plan: Exporter.Plan {
        Exporter.plan(shots: model.shots, flags: model.flags)
    }

    /// Flagged shots grouped by what they will contribute.
    private var breakdown: [(shot: Shot, selection: FlagSelection)] {
        model.shots.compactMap { shot in
            let selection = model.flagFor(shot)
            return selection.isEmpty ? nil : (shot, selection)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            summary

            Divider().opacity(0.4)

            if isRunning {
                running
            } else {
                modePicker
                fileList
            }

            Divider().opacity(0.4)
            footer
        }
        .padding(20)
        .frame(width: 460)
        .onChange(of: model.isExporting) { _, exporting in
            if isRunning && !exporting {
                isRunning = false
                onComplete()
            }
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Export flagged photos")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text("You choose the destination folder next.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var summary: some View {
        HStack(spacing: 8) {
            InfoChip(systemName: "photo.stack", text: "\(plan.shotCount) photo\(plan.shotCount == 1 ? "" : "s")")
            InfoChip(systemName: "doc.on.doc", text: "\(plan.files.count) file\(plan.files.count == 1 ? "" : "s")")
            InfoChip(systemName: "internaldrive", text: Format.bytes(plan.totalBytes))
            Spacer()
        }
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("After exporting")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Picker("", selection: $modeRaw) {
                ForEach(Exporter.Mode.allCases, id: \.rawValue) { candidate in
                    Text(candidate.label).tag(candidate.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(mode.help)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
    }

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("What gets saved")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(breakdown.prefix(200).enumerated()), id: \.element.shot.id) { index, entry in
                        HStack(spacing: 8) {
                            Text(entry.shot.displayName)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 6)
                            KindBadge(
                                kinds: entry.shot.availableKinds,
                                flagged: entry.selection,
                                dimmed: Set(FileKind.allCases)
                                    .subtracting(entry.shot.availableKinds)
                                    .union(entry.shot.availableKinds.filter { !entry.selection.contains(.kind($0)) })
                            )
                        }
                        .padding(.vertical, 4)
                        if index < min(breakdown.count, 200) - 1 {
                            Divider().opacity(0.25)
                        }
                    }
                }
            }
            .frame(height: 168)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )

            if breakdown.count > 200 {
                Text("…and \(breakdown.count - 200) more")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var running: some View {
        VStack(spacing: 10) {
            ProgressView(
                value: Double(model.exportProgress.done),
                total: Double(max(model.exportProgress.total, 1))
            )
            Text("Copying \(model.exportProgress.done) of \(model.exportProgress.total)…")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if model.flaggedShotIDs.count > 0 && !isRunning {
                Button("Clear all flags") {
                    model.clearAllFlags()
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }
            Spacer()
            Button("Cancel") { onComplete() }
                .keyboardShortcut(.cancelAction)
                .disabled(isRunning)
            Button(mode == .move ? "Choose Folder & Move" : "Choose Folder & Copy") {
                isRunning = true
                model.exportFlagged(mode: mode)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isRunning || plan.isEmpty)
        }
    }
}
