import Foundation
import ImageIO
import CoreGraphics

/// A single row in the metadata panel.
struct MetadataItem: Identifiable, Hashable {
    let id = UUID()
    let label: String
    let value: String

    static func == (lhs: MetadataItem, rhs: MetadataItem) -> Bool {
        lhs.label == rhs.label && lhs.value == rhs.value
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(label)
        hasher.combine(value)
    }
}

/// A titled group of metadata rows.
struct MetadataSection: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String
    let items: [MetadataItem]
}

/// What Sandglass could learn about one file.
struct FileMetadata {
    let sections: [MetadataSection]

    var isEmpty: Bool { sections.allSatisfy(\.items.isEmpty) }

    /// Flattened view used for the compact summary line.
    var allItems: [MetadataItem] { sections.flatMap(\.items) }

    func value(for label: String) -> String? {
        allItems.first { $0.label == label }?.value
    }
}

/// Reads EXIF / TIFF / GPS metadata with ImageIO.
///
/// Only reads the metadata dictionaries — the pixels are never touched, so
/// nothing here can affect how a photo looks.
enum MetadataReader {

    /// Full metadata for one file, or nil when it cannot be read.
    static func read(url: URL) -> FileMetadata? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]

        var sections: [MetadataSection] = []

        if let file = fileSection(url: url, properties: properties) { sections.append(file) }
        if let camera = cameraSection(properties) { sections.append(camera) }
        if let exposure = exposureSection(properties) { sections.append(exposure) }
        if let location = locationSection(properties) { sections.append(location) }

        let metadata = FileMetadata(sections: sections)
        return metadata.isEmpty ? nil : metadata
    }

    // MARK: Sections

    private static func fileSection(url: URL, properties: [CFString: Any]) -> MetadataSection? {
        var items: [MetadataItem] = [
            MetadataItem(label: "Name", value: url.lastPathComponent)
        ]

        let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        if let type = source.flatMap({ CGImageSourceGetType($0) }) as String? {
            let friendly = FileKind.from(url: url)?.label ?? type
            items.append(MetadataItem(label: "Type", value: "\(friendly) · \(type)"))
        }

        if let size = Exporter.fileSize(url) {
            items.append(MetadataItem(label: "File size", value: Format.bytes(size)))
        }

        // How many images the container holds — a NEF carries a JPEG preview,
        // which is what Sandglass displays.
        if let count = source.map(CGImageSourceGetCount), count > 0 {
            items.append(MetadataItem(label: "Embedded previews", value: "\(count)"))
        }

        if let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int {
            items.append(MetadataItem(label: "Dimensions", value: "\(width) × \(height)"))
        }

        let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        if let created {
            items.append(MetadataItem(label: "Created", value: dateFormatter.string(from: created)))
        }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let modified {
            items.append(MetadataItem(label: "Modified", value: dateFormatter.string(from: modified)))
        }

        return MetadataSection(title: "File", systemImage: "doc", items: items)
    }

    private static func cameraSection(_ properties: [CFString: Any]) -> MetadataSection? {
        var items: [MetadataItem] = []

        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            if let model = tiff[kCGImagePropertyTIFFModel] as? String {
                items.append(MetadataItem(label: "Camera", value: model))
            }
            if let make = tiff[kCGImagePropertyTIFFMake] as? String,
               let model = tiff[kCGImagePropertyTIFFModel] as? String,
               !model.localizedCaseInsensitiveContains(make) {
                items.append(MetadataItem(label: "Make", value: make))
            }
            if let software = tiff[kCGImagePropertyTIFFSoftware] as? String, !software.isEmpty {
                items.append(MetadataItem(label: "Software", value: software.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            if let artist = tiff[kCGImagePropertyTIFFArtist] as? String, !artist.isEmpty {
                items.append(MetadataItem(label: "Artist", value: artist))
            }
            if let copyright = tiff[kCGImagePropertyTIFFCopyright] as? String, !copyright.isEmpty {
                items.append(MetadataItem(label: "Copyright", value: copyright))
            }
        }

        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let date = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                items.append(MetadataItem(label: "Captured", value: date))
            }
            if let lens = exif[kCGImagePropertyExifLensModel] as? String, !lens.isEmpty {
                items.append(MetadataItem(label: "Lens", value: lens))
            }
        }

        return items.isEmpty ? nil : MetadataSection(title: "Camera", systemImage: "camera", items: items)
    }

    private static func exposureSection(_ properties: [CFString: Any]) -> MetadataSection? {
        guard let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] else { return nil }
        var items: [MetadataItem] = []

        if let exposure = exif[kCGImagePropertyExifExposureTime] as? Double, exposure > 0 {
            items.append(MetadataItem(label: "Shutter", value: shutterString(exposure)))
        }
        if let aperture = exif[kCGImagePropertyExifFNumber] as? Double, aperture > 0 {
            items.append(MetadataItem(label: "Aperture", value: "ƒ/\(trim(aperture))"))
        }
        if let iso = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int], let first = iso.first {
            items.append(MetadataItem(label: "ISO", value: "\(first)"))
        }
        if let focal = exif[kCGImagePropertyExifFocalLength] as? Double, focal > 0 {
            var value = "\(trim(focal)) mm"
            if let eq = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int, eq > 0 {
                value += " (\(eq) mm eq.)"
            }
            items.append(MetadataItem(label: "Focal length", value: value))
        }
        if let bias = exif[kCGImagePropertyExifExposureBiasValue] as? Double, bias != 0 {
            items.append(MetadataItem(label: "Exposure bias", value: "\(bias > 0 ? "+" : "")\(trim(bias)) EV"))
        }
        if let program = exif[kCGImagePropertyExifExposureProgram] as? Int {
            items.append(MetadataItem(label: "Program", value: exposureProgram(program)))
        }
        if let metering = exif[kCGImagePropertyExifMeteringMode] as? Int {
            items.append(MetadataItem(label: "Metering", value: meteringMode(metering)))
        }
        if let flash = exif[kCGImagePropertyExifFlash] as? Int {
            items.append(MetadataItem(label: "Flash", value: (flash & 1) == 1 ? "Fired" : "Did not fire"))
        }
        if let white = exif[kCGImagePropertyExifWhiteBalance] as? Int {
            items.append(MetadataItem(label: "White balance", value: white == 1 ? "Manual" : "Auto"))
        }

        return items.isEmpty ? nil : MetadataSection(title: "Exposure", systemImage: "camera.aperture", items: items)
    }

    private static func locationSection(_ properties: [CFString: Any]) -> MetadataSection? {
        guard let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
              let latitude = gps[kCGImagePropertyGPSLatitude] as? Double,
              let longitude = gps[kCGImagePropertyGPSLongitude] as? Double else { return nil }

        let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String ?? (latitude >= 0 ? "N" : "S")
        let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String ?? (longitude >= 0 ? "E" : "W")
        var items = [
            MetadataItem(label: "Latitude", value: "\(trim(abs(latitude)))° \(latRef)"),
            MetadataItem(label: "Longitude", value: "\(trim(abs(longitude)))° \(lonRef)")
        ]
        if let altitude = gps[kCGImagePropertyGPSAltitude] as? Double {
            items.append(MetadataItem(label: "Altitude", value: "\(trim(altitude)) m"))
        }
        return MetadataSection(title: "Location", systemImage: "location", items: items)
    }

    // MARK: Formatting

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// Trim trailing zeros so 2.80 reads as 2.8 and 4.0 as 4.
    static func trim(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? String(Int(rounded))
            : String(format: "%.1f", rounded)
    }

    static func shutterString(_ seconds: Double) -> String {
        if seconds >= 1 {
            return "\(trim(seconds)) s"
        }
        // Express fast speeds the way cameras show them: 1/250.
        return "1/\(Int((1 / seconds).rounded())) s"
    }

    static func exposureProgram(_ value: Int) -> String {
        switch value {
        case 1: return "Manual"
        case 2: return "Program AE"
        case 3: return "Aperture priority"
        case 4: return "Shutter priority"
        case 5: return "Creative"
        case 6: return "Action"
        case 7: return "Portrait"
        case 8: return "Landscape"
        default: return "Not defined"
        }
    }

    static func meteringMode(_ value: Int) -> String {
        switch value {
        case 1: return "Average"
        case 2: return "Center-weighted"
        case 3: return "Spot"
        case 4: return "Multi-spot"
        case 5: return "Pattern"
        case 6: return "Partial"
        default: return "Unknown"
        }
    }
}
