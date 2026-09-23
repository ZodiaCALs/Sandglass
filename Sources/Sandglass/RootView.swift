import SwiftUI

/// Top-level layout: header, filmstrip + preview, and the floating control bar.
struct RootView: View {
    @StateObject private var model: LibraryModel

    @State private var toast: Toast?
    @State private var showingExportSheet = false
    @State private var showingHelp = false
    @State private var toastToken = UUID()
    @State private var showingBackgroundPicker = false
    @StateObject private var zoom = ZoomBridge()
    @State private var showingMetadata = false

    // Backdrop preferences, persisted across launches.
    @AppStorage("backgroundMode") private var backgroundModeRaw = BackgroundMode.preset.rawValue
    @AppStorage("backgroundPreset") private var backgroundPresetID = "slate"
    @AppStorage("backgroundImageDim") private var backgroundImageDim = 0.35
    /// Stored as hex so the wheel selection survives relaunch.
    @AppStorage("backgroundCustomHex") private var backgroundCustomHex = "#2B3550"
    @AppStorage("layoutMode") private var layoutModeRaw = LayoutMode.filmstripLeft.rawValue

    private var layoutMode: LayoutMode {
        LayoutMode(rawValue: layoutModeRaw) ?? .filmstripLeft
    }
    @StateObject private var backgroundImage = BackgroundImageLoader()

    private var backgroundMode: BackgroundMode {
        BackgroundMode(rawValue: backgroundModeRaw) ?? .preset
    }
    private var backgroundPreset: BackgroundPreset {
        BackgroundPreset.preset(id: backgroundPresetID)
    }
    private var customColor: Color { Color(hex: backgroundCustomHex) ?? Color(red: 0.17, green: 0.21, blue: 0.31) }

    /// Light backdrops need dark text, and vice versa.
    private var prefersDarkAppearance: Bool {
        switch backgroundMode {
        case .image: return !backgroundImage.isLight
        case .custom: return !customColor.isLight
        case .preset: return !backgroundPreset.isLight
        }
    }

    init(model: LibraryModel = LibraryModel()) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        ZStack {
            // The chosen backdrop sits behind the glass and gives it something
            // to refract. Photographs are never altered by this.
            StageBackground(
                mode: backgroundMode,
                preset: backgroundPreset,
                customColor: customColor,
                image: backgroundImage.image,
                imageDim: backgroundImageDim
            )

            VStack(spacing: 10) {
                HeaderBar(
                    model: model,
                    layoutModeRaw: $layoutModeRaw,
                    showingHelp: $showingHelp,
                    showingBackgroundPicker: $showingBackgroundPicker,
                    showingMetadata: $showingMetadata
                )
                content
                ControlBar(
                    model: model,
                    zoom: zoom,
                    showingExportSheet: $showingExportSheet,
                    showingMetadata: $showingMetadata
                ) { message, symbol in
                    show(toast: message, symbol: symbol)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 30)
            .padding(.bottom, 12)

            if model.isScanning { ScanningOverlay(folder: model.folder) }
        }
        .frame(minWidth: 900, minHeight: 620)
        .preferredColorScheme(prefersDarkAppearance ? .dark : .light)
        .onAppear { backgroundImage.refresh() }
        .onChange(of: backgroundModeRaw) { _, _ in backgroundImage.refresh() }
        .onChange(of: model.kind) { _, _ in refreshMetadataIfNeeded() }
        .onChange(of: model.index) { _, _ in refreshMetadataIfNeeded() }
        .onChange(of: showingMetadata) { _, isShown in
            if isShown { refreshMetadataIfNeeded() }
        }
        .animation(.easeOut(duration: 0.2), value: toast)
        .animation(.easeOut(duration: 0.15), value: model.isScanning)
        .sheet(isPresented: $showingExportSheet) {
            ExportSheet(model: model) {
                showingExportSheet = false
                show(toast: "Export complete", symbol: "checkmark.circle")
            }
        }
        .sheet(isPresented: $showingHelp) {
            HelpSheet { showingHelp = false }
        }
        .popover(isPresented: $showingBackgroundPicker, arrowEdge: .bottom) {
            BackgroundPicker(
                modeRaw: $backgroundModeRaw,
                presetID: $backgroundPresetID,
                customHex: $backgroundCustomHex,
                imageDim: $backgroundImageDim,
                imageLoader: backgroundImage
            )
        }
        .alert(
            "Sandglass",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            ),
            actions: { Button("OK", role: .cancel) { model.errorMessage = nil } },
            message: { Text(model.errorMessage ?? "") }
        )
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.commandNotification)) { note in
            guard let command = note.object as? AppDelegate.Command else { return }
            handle(command)
        }
        .onReceive(NotificationCenter.default.publisher(for: .sandglassReload)) { _ in
            model.reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .sandglassClearFlags)) { _ in
            model.clearAllFlags()
            show(toast: "All flags cleared", symbol: "flag.slash")
        }
        .onReceive(NotificationCenter.default.publisher(for: .sandglassOpenFolder)) { note in
            guard let url = note.object as? URL else { return }
            model.openFolder(at: url)
        }
        .onAppear {
            // `Sandglass /path/to/shoot` opens that folder immediately.
            guard let path = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") })
            else { return }
            model.openFolder(at: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isEmpty && !model.isScanning {
            EmptyStage()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(10)
        } else {
            filmstripLayout
        }
    }

    /// Arrange the filmstrip, photo and info panel according to the chosen layout.
    @ViewBuilder
    private var filmstripLayout: some View {
        HStack(spacing: 0) {
            if layoutMode == .photoOnly {
                PreviewPane(model: model, zoom: zoom, toast: $toast)
                metadataColumn
            } else if layoutMode == .filmstripRight {
                PreviewPane(model: model, zoom: zoom, toast: $toast)
                metadataColumn
                PhotoGridView(model: model)
            } else {
                PhotoGridView(model: model)
                PreviewPane(model: model, zoom: zoom, toast: $toast)
                metadataColumn
            }
        }
    }

    @ViewBuilder
    private var metadataColumn: some View {
        if showingMetadata {
            MetadataPanel(model: model) {
                showingMetadata = false
            }
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }

    /// Fetch metadata for whatever is on screen, if the panel is open.
    private func refreshMetadataIfNeeded() {
        guard showingMetadata, let shot = model.currentShot else { return }
        model.loadMetadata(for: shot, kind: model.kind)
    }

    // MARK: Commands

    private func handle(_ command: AppDelegate.Command) {
        switch command {
        case .next:
            model.next()
        case .previous:
            model.previous()
        case .toggleKind:
            if let missing = model.toggleKind() {
                show(toast: "No \(missing.label) file for this shot", symbol: "exclamationmark.triangle")
            }
        case .setKind(let kind):
            if !model.setKind(kind), model.currentShot != nil {
                show(toast: "No \(kind.label) file for this shot", symbol: "exclamationmark.triangle")
            }
        case .flagCurrent:
            guard let shot = model.currentShot, shot.url(for: model.kind) != nil else {
                show(toast: "No \(model.kind.label) file to flag", symbol: "exclamationmark.triangle")
                return
            }
            let wasFlagged = model.selectionForCurrent.contains(.kind(model.kind))
            model.toggleFlag()
            show(
                toast: wasFlagged ? "Unflagged \(model.kind.label)" : "Flagged \(model.kind.label)",
                symbol: wasFlagged ? "flag.slash" : "flag.fill"
            )
        case .flagBoth:
            guard let shot = model.currentShot else { return }
            let available = Set(shot.availableKinds)
            let before = model.selectionForCurrent
            model.toggleFlagBoth()
            let nowBoth = available.allSatisfy { model.selectionForCurrent.contains(.kind($0)) }
            let wasBoth = available.allSatisfy { before.contains(.kind($0)) }
            if nowBoth && !wasBoth {
                show(toast: "Flagged \(shot.variantSummary)", symbol: "flag.fill")
            } else if wasBoth {
                show(toast: "Cleared flags", symbol: "flag.slash")
            }
        case .flagOnly(let kind):
            guard let shot = model.currentShot, shot.url(for: kind) != nil else {
                show(toast: "No \(kind.label) file for this shot", symbol: "exclamationmark.triangle")
                return
            }
            let bit = FlagSelection.kind(kind)
            let alreadyOnly = model.selectionForCurrent == bit
            model.setFlag(bit, for: shot.id)
            show(
                toast: alreadyOnly ? "Cleared flags" : "Flagged \(kind.label) only",
                symbol: alreadyOnly ? "flag.slash" : "flag.fill"
            )
        case .openFolder:
            model.chooseFolder()
        case .export:
            if model.flaggedCount == 0 {
                show(toast: "Nothing flagged yet", symbol: "flag")
            } else {
                showingExportSheet = true
            }
        case .toggleMetadata:
            showingMetadata.toggle()
        case .background:
            showingBackgroundPicker.toggle()
        case .zoomIn:
            zoom.setFromUI(min(zoom.level * 1.25, LibraryModel.maxZoom))
        case .zoomOut:
            zoom.setFromUI(max(zoom.level / 1.25, LibraryModel.minZoom))
        case .zoomReset:
            zoom.setFromUI(LibraryModel.minZoom)
        }
    }

    /// Show a toast for a couple of seconds, replacing any current one.
    private func show(toast message: String, symbol: String) {
        let token = UUID()
        toastToken = token
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            toast = Toast(text: message, systemName: symbol)
        }
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard self.toastToken == token else { return }
            withAnimation(.easeOut(duration: 0.25)) { self.toast = nil }
        }
    }
}

/// Shown while a folder is being enumerated.
struct ScanningOverlay: View {
    let folder: URL?

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text(folder == nil ? "Scanning…" : "Scanning \(folder?.lastPathComponent ?? "")…")
                .font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .glassCard()
    }
}

/// Keyboard reference, one shortcut per row.
struct HelpSheet: View {
    let onClose: () -> Void

    private let shortcuts: [(String, String)] = [
        ("← →  /  ↑ ↓", "Previous / next photo"),
        ("Space", "Next photo"),
        ("J / K", "Next / previous photo"),
        ("T", "Switch between JPG and NEF"),
        ("F", "Flag the variant on screen"),
        ("B", "Flag both JPG and NEF"),
        ("1 / 2", "Flag only that variant"),
        ("+ / − / 0", "Zoom in / out / reset"),
        ("Mouse wheel", "Zoom about the pointer"),
        ("Pinch / ⌘-scroll", "Zoom on a trackpad"),
        ("Two-finger scroll", "Pan while zoomed in"),
        ("Double-click", "Fit ↔ 2×"),
        ("M", "Show file info — EXIF, camera, GPS"),
        ("B", "Background colour or picture"),
        ("⌘O", "Open folder"),
        ("⌘E", "Export flagged photos"),
        ("⌘J / ⌘K", "Show JPG / show NEF")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Sandglass")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                    Text("Flag what you keep — JPG, NEF, or both.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(spacing: 0) {
                ForEach(Array(shortcuts.enumerated()), id: \.offset) { index, item in
                    HStack(spacing: 12) {
                        Text(item.0)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .frame(width: 108, alignment: .leading)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.primary.opacity(0.08))
                            )
                        Text(item.1)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 5)
                    if index < shortcuts.count - 1 {
                        Divider().opacity(0.4)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 396)
    }
}
