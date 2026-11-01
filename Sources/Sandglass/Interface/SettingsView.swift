import SwiftUI
import AppKit

/// Preferences, as grouped cards — the System Settings look, which is also
/// Fluent's settings-page pattern.
struct SettingsView: View {
    @Bindable var settings: AppSettings
    let choosePicture: @MainActor () -> Void
    let removePicture: @MainActor () -> Void
    let hasPicture: Bool

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $settings.appearance) {
                    ForEach(AppSettings.Appearance.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                Picker("Backdrop", selection: $settings.backdrop) {
                    ForEach(AppSettings.Backdrop.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                if settings.backdrop == .glass {
                    LabeledContent("Glass tint") {
                        Slider(value: $settings.glassTint, in: 0...1) {
                            Text("Glass tint")
                        } minimumValueLabel: {
                            Text("Clear").font(Theme.caption)
                        } maximumValueLabel: {
                            Text("Solid").font(Theme.caption)
                        }
                        .labelsHidden()
                    }
                }

                if settings.backdrop != .picture {
                    LabeledContent("Colour") {
                        HStack(spacing: 6) {
                            ForEach(AppSettings.colorPresets, id: \.hex) { preset in
                                swatch(preset.name, hex: preset.hex)
                            }
                            ColorPicker("Custom colour", selection: customColor, supportsOpacity: false)
                                .labelsHidden()
                        }
                    }
                } else {
                    LabeledContent("Picture") {
                        HStack {
                            Button(hasPicture ? "Replace…" : "Choose…", action: choosePicture)
                            if hasPicture {
                                Button("Remove", role: .destructive, action: removePicture)
                            }
                        }
                    }
                    LabeledContent("Dimming") {
                        Slider(value: $settings.pictureDim, in: 0...0.85)
                    }
                }

                Picker("Behind photos", selection: $settings.stageTone) {
                    ForEach(AppSettings.StageTone.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Text("The backdrop only frames the interface. Photos are always shown unmodified — no tint, filter or colour shift is ever applied to them.")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Culling") {
                Picker("Show first", selection: $settings.preferredKind) {
                    ForEach(FileKind.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Go to the next photo after flagging", isOn: $settings.advanceAfterFlag)
                Toggle("Remember flags for each folder", isOn: $settings.rememberFlags)
                Toggle("Reopen the last folder at launch", isOn: $settings.reopenLastFolder)
                Toggle("Show photo info over the photo", isOn: $settings.showsInfoOverlay)
                Picker("Double-click zooms to", selection: $settings.zoomTarget) {
                    ForEach(AppSettings.ZoomTarget.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section {
                Toggle("Load full resolution in the background", isOn: $settings.preloadFullResolution)
                Toggle("Develop raw data when a NEF’s preview is small", isOn: $settings.decodeRawWhenZooming)
            } header: {
                Text("Performance")
            } footer: {
                Text("Photos open at the size of the window and are sharpened to every pixel when you zoom. Loading in the background makes zooming instant after a short pause on a photo, using memory for one full-size image. NEFs show the full-size JPEG the camera stored inside them; raw data is only developed when that preview is small.")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .frame(minHeight: 560)
    }

    private func swatch(_ name: String, hex: String) -> some View {
        let colour = RGBColor(hex: hex) ?? RGBColor(red: 0, green: 0, blue: 0)
        let isSelected = settings.backdropColorHex.caseInsensitiveCompare(hex) == .orderedSame
        return Button {
            settings.backdropColorHex = hex
        } label: {
            Circle()
                .fill(Color(nsColor: NSColor(colour)))
                .frame(width: 18, height: 18)
                .overlay(Circle().strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.2), lineWidth: isSelected ? 2.5 : 1))
        }
        .buttonStyle(.plain)
        .help(name)
    }

    private var customColor: Binding<Color> {
        let settings = settings
        return Binding(
            get: {
                MainActor.assumeIsolated {
                    let colour = RGBColor(hex: settings.backdropColorHex) ?? RGBColor(red: 0.08, green: 0.1, blue: 0.18)
                    return Color(nsColor: NSColor(colour))
                }
            },
            set: { newValue in
                guard let srgb = NSColor(newValue).usingColorSpace(.sRGB) else { return }
                let hex = RGBColor(
                    red: Double(srgb.redComponent),
                    green: Double(srgb.greenComponent),
                    blue: Double(srgb.blueComponent)
                ).hex
                MainActor.assumeIsolated { settings.backdropColorHex = hex }
            }
        )
    }
}

/// The keyboard reference.
struct ShortcutsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keyboard Shortcuts")
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                        Text("Flag what you keep — JPG, NEF, or both.")
                            .font(Theme.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(KeyMap.reference) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.title.uppercased())
                            .font(.system(size: 10, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(.tertiary)
                        VStack(spacing: 0) {
                            ForEach(group.rows, id: \.self) { row in
                                HStack(spacing: 12) {
                                    Text(row.keys)
                                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                                        .frame(width: 150, alignment: .leading)
                                    Text(row.action)
                                        .font(Theme.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                            }
                        }
                        .card()
                    }
                }
            }
            .padding(22)
        }
        .frame(width: 460, height: 620)
    }
}
