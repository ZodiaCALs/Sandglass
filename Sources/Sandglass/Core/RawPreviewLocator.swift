import Foundation

/// A JPEG stream embedded in a TIFF-based raw file.
struct EmbeddedJPEG: Equatable, Sendable {
    /// Byte offset of the JPEG's start-of-image marker within the file.
    let offset: Int
    let length: Int
    /// Pixel size from the JPEG's own frame header, in stored (unrotated) order.
    let width: Int
    let height: Int

    var pixelCount: Int { width * height }
    var longEdge: Int { max(width, height) }
    var byteRange: Range<Int> { offset ..< offset + length }
}

/// What a raw file says about its embedded previews.
struct RawContainer: Equatable, Sendable {
    /// Every decodable JPEG preview found, in discovery order.
    var previews: [EmbeddedJPEG] = []
    /// EXIF orientation from the first IFD (1…8). Embedded previews are stored the
    /// way the sensor saw the scene, so this is what turns a portrait upright.
    var orientation = 1
    var make: String?
    var model: String?

    /// The preview with the most pixels — for a modern Nikon NEF, the full-size
    /// JPEG the camera rendered at capture.
    var largestPreview: EmbeddedJPEG? {
        previews.max { ($0.pixelCount, $0.length) < ($1.pixelCount, $1.length) }
    }
}

/// Finds the JPEG previews inside a NEF (or any TIFF-based raw file) by walking
/// its IFDs, without decoding anything.
///
/// This is what makes NEFs as quick to show as JPEGs. Demosaicing a 24 MP raw
/// takes on the order of a second; the camera already stored a full-size JPEG
/// rendering of the same frame, and decoding that takes tens of milliseconds.
///
/// The walk covers IFD0 and its chain, every SubIFD, and Nikon's maker-note
/// preview IFD. Every offset is bounds-checked and loops are cut, so a truncated
/// or hostile file yields fewer previews, never a crash.
enum RawPreviewLocator {

    static func inspect(fileAt url: URL) -> RawContainer? {
        guard let data = try? Data(contentsOf: url, options: [.alwaysMapped]) else { return nil }
        return inspect(data)
    }

    static func inspect(_ data: Data) -> RawContainer? {
        guard let reader = ByteReader(tiff: data, base: 0),
              let first = reader.u32(4) else { return nil }

        var container = RawContainer()
        var queue: [Visit] = [Visit(reader: reader, offset: Int(first), role: .primary)]
        var visited = Set<Int>()
        var seenPreviews = Set<Int>()

        while !queue.isEmpty, visited.count < 64 {
            let visit = queue.removeFirst()
            guard visit.offset > 0, visited.insert(visit.offset).inserted,
                  let table = visit.reader.directory(at: visit.offset) else { continue }

            var fields = PreviewFields()
            for entry in table.entries {
                let reader = visit.reader
                switch entry.tag {
                case 0x0100: fields.width = reader.integers(entry).first
                case 0x0101: fields.height = reader.integers(entry).first
                case 0x0103: fields.compression = reader.integers(entry).first
                case 0x0111: fields.stripOffsets = reader.integers(entry, limit: 2)
                case 0x0117: fields.stripByteCounts = reader.integers(entry, limit: 2)
                case 0x0201: fields.jpegOffset = reader.integers(entry).first
                case 0x0202: fields.jpegLength = reader.integers(entry).first
                case 0x0112 where visit.role == .primary:
                    if let value = reader.integers(entry).first, (1...8).contains(value) {
                        container.orientation = value
                    }
                case 0x010F where visit.role == .primary:
                    container.make = reader.string(entry)
                case 0x0110 where visit.role == .primary:
                    container.model = reader.string(entry)
                case 0x014A:
                    // SubIFDs: Nikon keeps the full-size JPEG and the raw data here.
                    for offset in reader.integers(entry, limit: 16) {
                        queue.append(Visit(reader: reader, offset: reader.base + offset, role: .sub))
                    }
                case 0x8769 where visit.role == .primary:
                    if let offset = reader.integers(entry).first {
                        queue.append(Visit(reader: reader, offset: reader.base + offset, role: .exif))
                    }
                case 0x927C where visit.role == .exif:
                    if let maker = makerNote(in: data, at: entry.valueOffset, length: Int(entry.count)) {
                        queue.append(maker)
                    }
                case 0x0011 where visit.role == .makerNote:
                    // Nikon's PreviewIFD, with offsets relative to the maker note.
                    if let offset = reader.integers(entry).first {
                        queue.append(Visit(reader: reader, offset: reader.base + offset, role: .sub))
                    }
                default:
                    break
                }
            }

            if visit.role == .primary || visit.role == .chain, table.next > 0 {
                queue.append(Visit(reader: visit.reader, offset: visit.reader.base + table.next, role: .chain))
            }

            guard visit.role != .exif, visit.role != .makerNote,
                  let candidate = fields.jpegRange(base: visit.reader.base),
                  seenPreviews.insert(candidate.offset).inserted,
                  let preview = embeddedJPEG(in: data, offset: candidate.offset, length: candidate.length,
                                             fallbackSize: fields.size) else { continue }
            container.previews.append(preview)
        }
        return container
    }

    /// Frame size of a JPEG stream and whether it is lossless (raw sensor data
    /// stored as lossless JPEG, which is not a viewable preview).
    static func jpegFrame(in data: Data, offset: Int, length: Int) -> (width: Int, height: Int, lossless: Bool)? {
        let bytes = ByteReader(data: data, littleEndian: false, base: 0)
        let end = min(offset + length, data.count)
        guard offset >= 0, offset + 4 <= end,
              bytes.u8(offset) == 0xFF, bytes.u8(offset + 1) == 0xD8 else { return nil }

        var position = offset + 2
        var segments = 0
        while position + 4 <= end, segments < 512 {
            guard bytes.u8(position) == 0xFF else { return nil }
            var markerPosition = position + 1
            while markerPosition < end, bytes.u8(markerPosition) == 0xFF { markerPosition += 1 }
            guard let marker = bytes.u8(markerPosition) else { return nil }
            position = markerPosition + 1

            switch marker {
            case 0xD8, 0x01, 0xD0...0xD7:
                continue                                   // markers without a length
            case 0xD9, 0xDA:
                return nil                                 // image data before any frame header
            default:
                break
            }
            guard let segmentLength = bytes.u16(position), segmentLength >= 2 else { return nil }
            if isStartOfFrame(marker) {
                guard let height = bytes.u16(position + 3), let width = bytes.u16(position + 5) else { return nil }
                let lossless = [0xC3, 0xC7, 0xCB, 0xCF].contains(marker)
                return (Int(width), Int(height), lossless)
            }
            position += Int(segmentLength)
            segments += 1
        }
        return nil
    }

    // MARK: Internals

    private enum Role { case primary, chain, sub, exif, makerNote }

    private struct Visit {
        let reader: ByteReader
        let offset: Int
        let role: Role
    }

    private struct PreviewFields {
        var width: Int?
        var height: Int?
        var compression: Int?
        var stripOffsets: [Int] = []
        var stripByteCounts: [Int] = []
        var jpegOffset: Int?
        var jpegLength: Int?

        var size: (Int, Int)? {
            guard let width, let height, width > 0, height > 0 else { return nil }
            return (width, height)
        }

        /// Where this IFD's JPEG lives, if it describes one: either the explicit
        /// JPEG interchange tags, or a single JPEG-compressed strip.
        func jpegRange(base: Int) -> (offset: Int, length: Int)? {
            if let jpegOffset, let jpegLength, jpegLength > 0 {
                return (base + jpegOffset, jpegLength)
            }
            if let compression, compression == 6 || compression == 7,
               stripOffsets.count == 1, stripByteCounts.count == 1, stripByteCounts[0] > 0 {
                return (base + stripOffsets[0], stripByteCounts[0])
            }
            return nil
        }
    }

    private static func isStartOfFrame(_ marker: UInt8) -> Bool {
        (0xC0...0xCF).contains(marker) && marker != 0xC4 && marker != 0xC8 && marker != 0xCC
    }

    private static func embeddedJPEG(in data: Data, offset: Int, length: Int, fallbackSize: (Int, Int)?) -> EmbeddedJPEG? {
        guard offset >= 0, length > 64, offset <= data.count - length else { return nil }
        let frame = jpegFrame(in: data, offset: offset, length: length)
        if frame?.lossless == true { return nil }
        let width = frame?.width ?? fallbackSize?.0 ?? 0
        let height = frame?.height ?? fallbackSize?.1 ?? 0
        guard frame != nil || (width > 0 && height > 0) else { return nil }
        return EmbeddedJPEG(offset: offset, length: length, width: width, height: height)
    }

    /// Nikon maker notes begin "Nikon\0", a version, then a TIFF header of their own
    /// whose offsets are relative to that header.
    private static func makerNote(in data: Data, at offset: Int, length: Int) -> Visit? {
        let signature: [UInt8] = [0x4E, 0x69, 0x6B, 0x6F, 0x6E, 0x00]   // "Nikon\0"
        guard offset >= 0, length >= 18, offset + 18 <= data.count else { return nil }
        for (index, byte) in signature.enumerated() where data[data.startIndex + offset + index] != byte {
            return nil
        }
        let header = offset + 10
        guard let reader = ByteReader(tiff: data, base: header), let first = reader.u32(header + 4) else { return nil }
        return Visit(reader: reader, offset: header + Int(first), role: .makerNote)
    }
}

// MARK: - Byte access

/// Bounds-checked reads from a TIFF structure.
private struct ByteReader {
    let data: Data
    let littleEndian: Bool
    /// Offsets inside this structure are relative to `base`.
    let base: Int

    struct Entry {
        let tag: UInt16
        let type: UInt16
        let count: UInt32
        /// Absolute offset of the value bytes.
        let valueOffset: Int
    }

    init(data: Data, littleEndian: Bool, base: Int) {
        self.data = data
        self.littleEndian = littleEndian
        self.base = base
    }

    /// Reads a TIFF header ("II*\0" or "MM\0*") at `base`.
    init?(tiff data: Data, base: Int) {
        guard base >= 0, base + 8 <= data.count else { return nil }
        let first = data[data.startIndex + base]
        let second = data[data.startIndex + base + 1]
        switch (first, second) {
        case (0x49, 0x49): littleEndian = true
        case (0x4D, 0x4D): littleEndian = false
        default: return nil
        }
        self.data = data
        self.base = base
        guard u16(base + 2) == 42 else { return nil }
    }

    func u8(_ offset: Int) -> UInt8? {
        guard offset >= 0, offset < data.count else { return nil }
        return data[data.startIndex + offset]
    }

    func u16(_ offset: Int) -> UInt16? {
        guard offset >= 0, offset <= data.count - 2 else { return nil }
        let a = UInt16(data[data.startIndex + offset])
        let b = UInt16(data[data.startIndex + offset + 1])
        return littleEndian ? (a | b << 8) : (a << 8 | b)
    }

    func u32(_ offset: Int) -> UInt32? {
        guard offset >= 0, offset <= data.count - 4 else { return nil }
        var value: UInt32 = 0
        for index in 0..<4 {
            let byte = UInt32(data[data.startIndex + offset + index])
            value |= littleEndian ? byte << (8 * UInt32(index)) : byte << (8 * UInt32(3 - index))
        }
        return value
    }

    func directory(at offset: Int) -> (entries: [Entry], next: Int)? {
        guard let count = u16(offset), count > 0, count <= 1024 else { return nil }
        let tableEnd = offset + 2 + Int(count) * 12
        guard tableEnd <= data.count else { return nil }

        var entries: [Entry] = []
        entries.reserveCapacity(Int(count))
        for index in 0..<Int(count) {
            let position = offset + 2 + index * 12
            guard let tag = u16(position), let type = u16(position + 2), let valueCount = u32(position + 4),
                  let size = Self.size(ofType: type) else { continue }
            let byteCount = Int(valueCount) * size
            let valueOffset: Int
            if byteCount <= 4 {
                valueOffset = position + 8
            } else {
                guard let pointer = u32(position + 8) else { continue }
                valueOffset = base + Int(pointer)
            }
            entries.append(Entry(tag: tag, type: type, count: valueCount, valueOffset: valueOffset))
        }
        let next = u32(tableEnd).map(Int.init) ?? 0
        return (entries, next)
    }

    func integers(_ entry: Entry, limit: Int = 1) -> [Int] {
        let count = min(Int(entry.count), limit)
        guard count > 0 else { return [] }
        var values: [Int] = []
        values.reserveCapacity(count)
        for index in 0..<count {
            let value: Int?
            switch entry.type {
            case 1, 7: value = u8(entry.valueOffset + index).map(Int.init)
            case 3: value = u16(entry.valueOffset + index * 2).map(Int.init)
            case 4, 13: value = u32(entry.valueOffset + index * 4).map(Int.init)
            default: value = nil
            }
            if let value { values.append(value) }
        }
        return values
    }

    func string(_ entry: Entry) -> String? {
        guard entry.type == 2, entry.count > 0, entry.count <= 256 else { return nil }
        let start = entry.valueOffset
        let end = start + Int(entry.count)
        guard start >= 0, end <= data.count else { return nil }
        let bytes = data[(data.startIndex + start)..<(data.startIndex + end)].prefix { $0 != 0 }
        let text = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    private static func size(ofType type: UInt16) -> Int? {
        switch type {
        case 1, 2, 6, 7: 1
        case 3, 8: 2
        case 4, 9, 11, 13: 4
        case 5, 10, 12: 8
        default: nil
        }
    }
}
