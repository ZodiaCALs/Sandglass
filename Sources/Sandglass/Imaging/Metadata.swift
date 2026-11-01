import Foundation
import ImageIO
import Observation

/// One row of the inspector.
struct MetadataItem: Hashable, Sendable {
    let label: String
    let value: String
}

/// A titled group of rows.
struct MetadataSection: Identifiable, Hashable, Sendable {
    let title: String
    let systemImage: String
    let items: [MetadataItem]

    var id: String { title }
}

/// What Sandglass learned about one file.
struct PhotoMetadata: Sendable, Equatable {
    var sections: [MetadataSection] = []
    /// "1/250 s · ƒ/2.8 · ISO 400 · 85 mm", for the photo overlay.
    var exposureSummary: String?
    var camera: String?

    var isEmpty: Bool { sections.allSatisfy(\.items.isEmpty) }

    /// The value of the first row with this label, if any.
    func value(for label: String) -> String? {
        for section in sections {
            if let item = section.items.first(where: { $0.label == label }) { return item.value }
        }
        return nil
    }
}

/// Reads EXIF, TIFF and GPS metadata with ImageIO. Only the metadata
/// dictionaries are read — never the pixels — so nothing here can affect how a
/// photo looks.
enum MetadataReader {

    static func read(url: URL) -> PhotoMetadata? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]

        var metadata = PhotoMetadata()
        let camera = cameraName(tiff)
        metadata.camera = camera
        metadata.exposureSummary = exposureSummary(exif)

        let sections = [
            captureSection(camera: camera, exif: exif, tiff: tiff),
            exposureSection(exif),
            imageSection(url: url, source: source, properties: properties),
            locationSection(properties),
            fileSection(url: url)
        ]
        metadata.sections = sections.compactMap { $0 }
        return metadata.isEmpty ? nil : metadata
    }

    // MARK: Sections

    private static func cameraName(_ tiff: [CFString: Any]) -> String? {
        let make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces)
        guard let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces),
              !model.isEmpty else { return make }
        guard let make, !make.isEmpty else { return model }
        // "NIKON CORPORATION" + "NIKON Z 6_2" reads better as just the model.
        let brand = make.split(separator: " ").first.map(String.init) ?? make
        return model.localizedCaseInsensitiveContains(brand) ? model : "\(make) \(model)"
    }

    private static func exposureSummary(_ exif: [CFString: Any]) -> String? {
        var parts: [String] = []
        if let time = number(exif[kCGImagePropertyExifExposureTime]), time > 0 { parts.append(Format.shutter(time)) }
        if let fNumber = number(exif[kCGImagePropertyExifFNumber]), fNumber > 0 { parts.append(Format.aperture(fNumber)) }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first { parts.append("ISO \(iso.intValue)") }
        if let focal = number(exif[kCGImagePropertyExifFocalLength]), focal > 0 { parts.append("\(Format.trim(focal)) mm") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func captureSection(camera: String?, exif: [CFString: Any], tiff: [CFString: Any]) -> MetadataSection? {
        var items: [MetadataItem] = []
        if let camera { items.append(MetadataItem(label: "Camera", value: camera)) }
        if let lens = exif[kCGImagePropertyExifLensModel] as? String, !lens.isEmpty {
            items.append(MetadataItem(label: "Lens", value: lens))
        }
        if let date = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            items.append(MetadataItem(label: "Captured", value: prettyDate(date)))
        }
        if let software = (tiff[kCGImagePropertyTIFFSoftware] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !software.isEmpty {
            items.append(MetadataItem(label: "Firmware", value: software))
        }
        if let artist = tiff[kCGImagePropertyTIFFArtist] as? String, !artist.isEmpty {
            items.append(MetadataItem(label: "Artist", value: artist))
        }
        if let copyright = tiff[kCGImagePropertyTIFFCopyright] as? String, !copyright.isEmpty {
            items.append(MetadataItem(label: "Copyright", value: copyright))
        }
        return items.isEmpty ? nil : MetadataSection(title: "Capture", systemImage: "camera", items: items)
    }

    private static func exposureSection(_ exif: [CFString: Any]) -> MetadataSection? {
        var items: [MetadataItem] = []
        if let time = number(exif[kCGImagePropertyExifExposureTime]), time > 0 {
            items.append(MetadataItem(label: "Shutter", value: Format.shutter(time)))
        }
        if let fNumber = number(exif[kCGImagePropertyExifFNumber]), fNumber > 0 {
            items.append(MetadataItem(label: "Aperture", value: Format.aperture(fNumber)))
        }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first {
            items.append(MetadataItem(label: "ISO", value: "\(iso.intValue)"))
        }
        if let focal = number(exif[kCGImagePropertyExifFocalLength]), focal > 0 {
            var value = "\(Format.trim(focal)) mm"
            if let equivalent = (exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber)?.intValue, equivalent > 0 {
                value += " (\(equivalent) mm equiv.)"
            }
            items.append(MetadataItem(label: "Focal length", value: value))
        }
        if let bias = number(exif[kCGImagePropertyExifExposureBiasValue]), bias != 0 {
            items.append(MetadataItem(label: "Compensation", value: "\(bias > 0 ? "+" : "")\(Format.trim(bias)) EV"))
        }
        if let program = (exif[kCGImagePropertyExifExposureProgram] as? NSNumber)?.intValue {
            items.append(MetadataItem(label: "Program", value: Format.exposureProgram(program)))
        }
        if let metering = (exif[kCGImagePropertyExifMeteringMode] as? NSNumber)?.intValue {
            items.append(MetadataItem(label: "Metering", value: Format.meteringMode(metering)))
        }
        if let flash = (exif[kCGImagePropertyExifFlash] as? NSNumber)?.intValue {
            items.append(MetadataItem(label: "Flash", value: flash & 1 == 1 ? "Fired" : "Did not fire"))
        }
        if let balance = (exif[kCGImagePropertyExifWhiteBalance] as? NSNumber)?.intValue {
            items.append(MetadataItem(label: "White balance", value: balance == 1 ? "Manual" : "Auto"))
        }
        return items.isEmpty ? nil : MetadataSection(title: "Exposure", systemImage: "camera.aperture", items: items)
    }

    private static func imageSection(url: URL, source: CGImageSource, properties: [CFString: Any]) -> MetadataSection? {
        var items: [MetadataItem] = []
        if let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
           let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, width > 0, height > 0 {
            items.append(MetadataItem(label: "Dimensions", value: "\(Format.pixels(width, height)) · \(Format.megapixels(width, height))"))
        }
        if let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, orientation != 1 {
            items.append(MetadataItem(label: "Orientation", value: Format.orientation(orientation)))
        }
        if let profile = properties[kCGImagePropertyProfileName] as? String, !profile.isEmpty {
            items.append(MetadataItem(label: "Colour profile", value: profile))
        }
        if let depth = (properties[kCGImagePropertyDepth] as? NSNumber)?.intValue, depth > 0 {
            items.append(MetadataItem(label: "Bit depth", value: "\(depth)-bit"))
        }
        if FileKind.from(url: url) == .nef {
            if let preview = RawPreviewLocator.inspect(fileAt: url)?.largestPreview {
                items.append(MetadataItem(label: "Camera preview", value: "\(Format.pixels(preview.width, preview.height)) JPEG"))
            } else {
                items.append(MetadataItem(label: "Camera preview", value: "None embedded"))
            }
        }
        if let type = CGImageSourceGetType(source) as String? {
            items.append(MetadataItem(label: "Format", value: type))
        }
        return items.isEmpty ? nil : MetadataSection(title: "Image", systemImage: "photo", items: items)
    }

    private static func locationSection(_ properties: [CFString: Any]) -> MetadataSection? {
        guard let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
              let latitude = number(gps[kCGImagePropertyGPSLatitude]),
              let longitude = number(gps[kCGImagePropertyGPSLongitude]) else { return nil }
        let latitudeRef = gps[kCGImagePropertyGPSLatitudeRef] as? String ?? (latitude >= 0 ? "N" : "S")
        let longitudeRef = gps[kCGImagePropertyGPSLongitudeRef] as? String ?? (longitude >= 0 ? "E" : "W")
        var items = [
            MetadataItem(label: "Latitude", value: String(format: "%.5f° %@", abs(latitude), latitudeRef)),
            MetadataItem(label: "Longitude", value: String(format: "%.5f° %@", abs(longitude), longitudeRef))
        ]
        if let altitude = number(gps[kCGImagePropertyGPSAltitude]) {
            items.append(MetadataItem(label: "Altitude", value: "\(Format.trim(altitude)) m"))
        }
        return MetadataSection(title: "Location", systemImage: "location", items: items)
    }

    private static func fileSection(url: URL) -> MetadataSection? {
        var items = [MetadataItem(label: "Name", value: url.lastPathComponent)]
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])
        if let size = values?.fileSize {
            items.append(MetadataItem(label: "Size", value: Format.bytes(Int64(size))))
        }
        if let created = values?.creationDate {
            items.append(MetadataItem(label: "Created", value: dateFormatter.string(from: created)))
        }
        if let modified = values?.contentModificationDate {
            items.append(MetadataItem(label: "Modified", value: dateFormatter.string(from: modified)))
        }
        items.append(MetadataItem(label: "Folder", value: (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath))
        return MetadataSection(title: "File", systemImage: "doc", items: items)
    }

    // MARK: Helpers

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    /// "2026:09:21 20:48:29" → a localised date.
    private static func prettyDate(_ exifDate: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard let date = parser.date(from: exifDate) else { return exifDate }
        return dateFormatter.string(from: date)
    }

    nonisolated(unsafe) private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

/// Metadata for the inspector and overlay, read in the background and cached.
@MainActor
@Observable
final class MetadataStore {
    private(set) var entries: [URL: PhotoMetadata] = [:]
    private(set) var loading: Set<URL> = []
    @ObservationIgnored private var order: [URL] = []
    @ObservationIgnored private let limit = 400

    func metadata(for url: URL) -> PhotoMetadata? {
        entries[url]
    }

    func isLoading(_ url: URL) -> Bool {
        loading.contains(url)
    }

    func load(_ url: URL) {
        guard entries[url] == nil, !loading.contains(url) else { return }
        loading.insert(url)
        Task { [weak self] in
            let result = await MetadataStore.read(url)
            guard let self else { return }
            self.loading.remove(url)
            self.entries[url] = result ?? PhotoMetadata()
            self.order.append(url)
            if self.order.count > self.limit {
                let excess = self.order.prefix(self.order.count - self.limit)
                for old in excess { self.entries[old] = nil }
                self.order.removeFirst(excess.count)
            }
        }
    }

    func removeAll() {
        entries.removeAll()
        order.removeAll()
    }

    @concurrent
    nonisolated private static func read(_ url: URL) async -> PhotoMetadata? {
        MetadataReader.read(url: url)
    }
}
