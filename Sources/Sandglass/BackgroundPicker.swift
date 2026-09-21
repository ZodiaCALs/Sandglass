import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Popover for choosing the window backdrop: a colour preset or your own picture.
struct BackgroundPicker: View {
    @Binding var modeRaw: String
    @Binding var presetID: String
    @Binding var imageDim: Double
    @ObservedObject var imageLoader: BackgroundImageLoader
    @State private var importError: String?

    private var mode: BackgroundMode { BackgroundMode(rawValue: modeRaw) ?? .preset }
    private var selected: BackgroundPreset { BackgroundPreset.preset(id: presetID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Background")
                .font(.system(size: 13, weight: .semibold, design: .rounded))

            Picker("", selection: $modeRaw) {
                ForEach(BackgroundMode.allCases, id: \.rawValue) { candidate in
                    Text(candidate.label).tag(candidate.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if mode == .preset {
                colourGrid
            } else {
                pictureControls
            }

            Divider().opacity(0.4)

            Text("The backdrop only. Photos are always shown unmodified — no tint, filter or colour shift is ever applied to a preview.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if let importError {
                Text(importError)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
        }
        .padding(16)
        .frame(width: 268)
    }

    // MARK: Colour

    private var colourGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(BackgroundPreset.all) { candidate in
                Button {
                    presetID = candidate.id
                    modeRaw = BackgroundMode.preset.rawValue
                } label: {
                    VStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [candidate.top, candidate.bottom],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(height: 38)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(
                                        candidate.id == presetID ? Color.accentColor : Color.white.opacity(0.18),
                                        lineWidth: candidate.id == presetID ? 2.5 : 1
                                    )
                            )
                        Text(candidate.name)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(candidate.id == presetID ? Color.primary : Color.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Use the \(candidate.name) background")
            }
        }
    }

    // MARK: Picture

    private var pictureControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let image = imageLoader.image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: 92)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                    )
            } else {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 92)
                    .overlay(
                        VStack(spacing: 5) {
                            Image(systemName: "photo")
                                .font(.system(size: 17))
                            Text("No picture chosen")
                                .font(.system(size: 10))
                        }
                        .foregroundStyle(.secondary)
                    )
            }

            HStack(spacing: 8) {
                Button(imageLoader.image == nil ? "Choose Picture…" : "Replace…") {
                    choosePicture()
                }
                if imageLoader.image != nil {
                    Button("Remove") {
                        BackgroundImageStore.removeImage()
                        imageLoader.refresh()
                    }
                }
            }
            .controlSize(.small)

            if imageLoader.image != nil {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Dimming")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Slider(value: $imageDim, in: 0...0.85)
                        .controlSize(.small)
                }
                .help("Darken the picture so glass panels and text stay readable")
            }
        }
    }

    private func choosePicture() {
        importError = nil
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.prompt = "Use Picture"
        panel.message = "Choose an image to use as the window background"
        panel.title = "Choose Background Picture"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try BackgroundImageStore.importImage(from: url)
            imageLoader.refresh()
            modeRaw = BackgroundMode.image.rawValue
        } catch {
            importError = "Could not use that image: \(error.localizedDescription)"
        }
    }
}
