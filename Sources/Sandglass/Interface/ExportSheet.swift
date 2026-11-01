import SwiftUI
import Observation

/// One flagged photo, as the export sheet lists it.
struct ExportEntry: Identifiable, Sendable {
    let id: Shot.ID
    let name: String
    let available: [FileKind]
    let flagged: FlagSelection
}

/// The export flow: review what will be written, choose where, watch it run.
@MainActor
@Observable
final class ExportModel {
    enum Phase: Equatable {
        case review
        case running(done: Int, total: Int)
        case finished(ExportResult, destination: URL)
    }

    let plan: ExportPlan
    let entries: [ExportEntry]
    var mode: ExportMode
    private(set) var phase: Phase = .review

    @ObservationIgnored private var task: Task<Void, Never>?

    init(plan: ExportPlan, entries: [ExportEntry], mode: ExportMode) {
        self.plan = plan
        self.entries = entries
        self.mode = mode
    }

    var didMoveFiles: Bool {
        if case .finished(let result, _) = phase { return result.moved > 0 }
        return false
    }

    func run(to destination: URL) {
        guard case .review = phase else { return }
        let files = plan.files
        let exportMode = self.mode
        phase = .running(done: 0, total: files.count)
        task = Task { [weak self] in
            let result = await Exporter.run(files: files, destination: destination, mode: exportMode) { [weak self] done, total in
                Task { @MainActor [weak self] in self?.progress(done, total) }
            }
            self?.phase = .finished(result, destination: destination)
        }
    }

    func cancel() {
        task?.cancel()
    }

    private func progress(_ done: Int, _ total: Int) {
        guard case .running = phase else { return }
        phase = .running(done: done, total: total)
    }
}

/// The export sheet. The JPG / NEF / both rule is made visible here: the list
/// shows exactly which files of which photos will be written.
struct ExportSheetView: View {
    @Bindable var model: ExportModel
    let chooseDestination: @MainActor () -> URL?
    let reveal: @MainActor (URL) -> Void
    let close: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            switch model.phase {
            case .review:
                review
            case .running(let done, let total):
                running(done: done, total: total)
            case .finished(let result, let destination):
                finished(result, destination: destination)
            }
        }
        .padding(22)
        .frame(width: 500)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.arrow.up.on.square")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.flag)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Theme.flag.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text("Export Flagged Photos")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                Text("\(model.plan.shotCount) photo\(model.plan.shotCount == 1 ? "" : "s") · \(model.plan.files.count) file\(model.plan.files.count == 1 ? "" : "s") · \(Format.bytes(model.plan.totalBytes))")
                    .font(Theme.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Picker("After exporting", selection: $model.mode) {
                    ForEach(ExportMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Text(model.mode.help + " Existing files are never overwritten.")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.entries) { entry in
                        HStack(spacing: 8) {
                            Text(entry.name)
                                .font(Theme.caption.weight(.medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 6)
                            KindChips(available: entry.available, flagged: entry.flagged)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        Divider().opacity(0.4)
                    }
                }
            }
            .frame(height: 200)
            .card()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: close)
                    .keyboardShortcut(.cancelAction)
                Button(model.mode == .move ? "Choose Folder & Move…" : "Choose Folder & Copy…") {
                    if let destination = chooseDestination() {
                        model.run(to: destination)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(model.plan.isEmpty)
            }
        }
    }

    private func running(done: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView(value: Double(done), total: Double(max(total, 1)))
            HStack {
                Text("\(model.mode == .move ? "Moving" : "Copying") \(done) of \(total)…")
                    .font(Theme.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Stop") { model.cancel() }
            }
        }
        .padding(.vertical, 8)
    }

    private func finished(_ result: ExportResult, destination: URL) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                result.failures.isEmpty ? "Done — \(result.summary)" : "Finished with problems — \(result.summary)",
                systemImage: result.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .font(Theme.body.weight(.semibold))
            .foregroundStyle(result.failures.isEmpty ? Color.green : Theme.flag)

            Text("Saved to \((destination.path as NSString).abbreviatingWithTildeInPath)")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if !result.failures.isEmpty {
                ScrollView {
                    Text(result.failures.joined(separator: "\n"))
                        .font(.system(size: 10.5, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(10)
                }
                .frame(height: 90)
                .card()
            }

            HStack {
                Button("Show in Finder") { reveal(destination) }
                Spacer()
                Button("Done", action: close)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
