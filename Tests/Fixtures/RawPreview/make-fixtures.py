#!/usr/bin/env python3
"""Builds the synthetic NEF fixtures used by the raw-preview tests.

Real NEFs are tens of megabytes, so these files reproduce only the structure
that matters: TIFF IFDs pointing at embedded JPEG previews the way Nikon lays
them out (SubIFDs, the IFD0 chain, the maker-note PreviewIFD), plus decoys that
must be ignored (raw data, lossless-JPEG strips) and a truncated file.

Each embedded JPEG is drawn in *stored* orientation with a red square in its
top-left corner and a green bar along its bottom edge, so tests can check that
the IFD0 orientation is applied correctly.

Run from anywhere:  python3 Tests/Fixtures/RawPreview/make-fixtures.py
Requires Pillow.
"""
import io
import os
import struct

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))

BYTE, ASCII, SHORT, LONG, UNDEFINED = 1, 2, 3, 4, 7
TYPE_SIZE = {BYTE: 1, ASCII: 1, SHORT: 2, LONG: 4, UNDEFINED: 1}


def jpeg(width, height, quality=88):
    image = Image.new("RGB", (width, height), (128, 128, 128))
    draw = ImageDraw.Draw(image)
    side = max(8, min(width, height) // 4)
    draw.rectangle([0, 0, side - 1, side - 1], fill=(220, 30, 30))                 # top-left marker
    draw.rectangle([0, height - max(4, height // 10), width - 1, height - 1], fill=(30, 200, 60))
    out = io.BytesIO()
    image.save(out, "JPEG", quality=quality)
    return out.getvalue()


class Tiff:
    """A tiny TIFF writer: IFDs are laid out after the blobs they reference."""

    def __init__(self, endian):
        self.e = "<" if endian == "II" else ">"
        self.magic = endian.encode()
        self.data = bytearray(self.magic + struct.pack(self.e + "H", 42) + b"\0\0\0\0")

    def blob(self, payload, align=2):
        while len(self.data) % align:
            self.data.append(0)
        offset = len(self.data)
        self.data += payload
        return offset

    def ifd(self, entries, next_offset=0, base=0):
        """entries: list of (tag, type, values). Returns the IFD's offset."""
        while len(self.data) % 2:
            self.data.append(0)
        entries = sorted(entries, key=lambda item: item[0])
        # Values that do not fit in four bytes go after the table.
        table_offset = len(self.data)
        table_size = 2 + 12 * len(entries) + 4
        extra = bytearray()
        packed = []
        for tag, kind, values in entries:
            if kind == ASCII:
                raw = values.encode() + b"\0"
                count = len(raw)
            elif kind == UNDEFINED:
                raw = bytes(values)
                count = len(raw)
            else:
                fmt = {BYTE: "B", SHORT: "H", LONG: "I"}[kind]
                raw = b"".join(struct.pack(self.e + fmt, v) for v in values)
                count = len(values)
            if len(raw) <= 4:
                field = raw.ljust(4, b"\0")
            else:
                if len(extra) % 2:
                    extra.append(0)
                field = struct.pack(self.e + "I", table_offset + table_size + len(extra) - base)
                extra += raw
            packed.append(struct.pack(self.e + "HHI", tag, kind, count) + field)
        self.data += struct.pack(self.e + "H", len(entries))
        for item in packed:
            self.data += item
        self.data += struct.pack(self.e + "I", next_offset)
        self.data += extra
        return table_offset

    def set_first_ifd(self, offset):
        self.data[4:8] = struct.pack(self.e + "I", offset)

    def patch_next(self, ifd_offset, next_offset):
        count = struct.unpack(self.e + "H", self.data[ifd_offset:ifd_offset + 2])[0]
        position = ifd_offset + 2 + 12 * count
        self.data[position:position + 4] = struct.pack(self.e + "I", next_offset)


def embedded_little_endian():
    """Nikon-style layout: thumbnail in IFD0, small preview in IFD1, full-size JPEG in SubIFD0."""
    t = Tiff("II")
    small = jpeg(160, 107)
    small_offset = t.blob(small)
    big = jpeg(640, 427)
    big_offset = t.blob(big)
    raw_offset = t.blob(bytes(1024))
    thumb_offset = t.blob(bytes(160 * 120 * 3))

    sub0 = t.ifd([
        (254, LONG, [1]),
        (259, SHORT, [6]),
        (513, LONG, [big_offset]),
        (514, LONG, [len(big)]),
    ])
    sub1 = t.ifd([
        (254, LONG, [0]),
        (256, LONG, [6048]),
        (257, LONG, [4024]),
        (259, SHORT, [34713]),
        (273, LONG, [raw_offset]),
        (279, LONG, [1024]),
    ])
    exif = t.ifd([(36867, ASCII, "2026:09:21 20:48:29")])
    ifd1 = t.ifd([
        (259, SHORT, [6]),
        (513, LONG, [small_offset]),
        (514, LONG, [len(small)]),
    ])
    ifd0 = t.ifd([
        (254, LONG, [1]),
        (256, LONG, [160]),
        (257, LONG, [120]),
        (259, SHORT, [1]),
        (271, ASCII, "NIKON CORPORATION"),
        (272, ASCII, "SANDGLASS TEST"),
        (273, LONG, [thumb_offset]),
        (274, SHORT, [6]),
        (277, SHORT, [3]),
        (279, LONG, [160 * 120 * 3]),
        (330, LONG, [sub0, sub1]),
        (34665, LONG, [exif]),
    ], next_offset=ifd1)
    t.set_first_ifd(ifd0)
    return bytes(t.data), small_offset, big_offset, sub0


def strip_big_endian():
    """Motorola byte order, JPEG stored as a single strip, plus a lossless-JPEG decoy."""
    t = Tiff("MM")
    preview = jpeg(480, 320)
    preview_offset = t.blob(preview)
    # Lossless JPEG (SOF3) is how some raws store sensor data; it is not a preview.
    lossless = bytes([0xFF, 0xD8, 0xFF, 0xC3, 0x00, 0x0B, 0x0C, 0x0F, 0xC0, 0x17, 0x80, 0x01, 0x01, 0x11, 0x00]) + bytes(200)
    lossless_offset = t.blob(lossless)
    sub0 = t.ifd([
        (254, LONG, [1]),
        (256, LONG, [480]),
        (257, LONG, [320]),
        (259, SHORT, [7]),
        (273, LONG, [preview_offset]),
        (279, LONG, [len(preview)]),
    ])
    sub1 = t.ifd([
        (254, LONG, [0]),
        (256, LONG, [4032]),
        (257, LONG, [3008]),
        (259, SHORT, [7]),
        (273, LONG, [lossless_offset]),
        (279, LONG, [len(lossless)]),
    ])
    ifd0 = t.ifd([
        (254, LONG, [1]),
        (271, ASCII, "NIKON CORPORATION"),
        (272, ASCII, "SANDGLASS BE"),
        (274, SHORT, [1]),
        (330, LONG, [sub0, sub1]),
    ])
    t.set_first_ifd(ifd0)
    return bytes(t.data)


def maker_note_preview():
    """The only preview lives in Nikon's maker-note PreviewIFD, with offsets
    relative to the maker note's own (big-endian) TIFF header."""
    t = Tiff("II")
    preview = jpeg(320, 213)

    # Build the maker note as its own TIFF structure.
    maker = Tiff("MM")
    maker_preview_offset = maker.blob(preview)
    preview_ifd = maker.ifd([
        (259, SHORT, [6]),
        (513, LONG, [maker_preview_offset]),
        (514, LONG, [len(preview)]),
    ])
    maker_ifd = maker.ifd([
        (0x0001, UNDEFINED, b"0210"),
        (0x0011, LONG, [preview_ifd]),
    ])
    maker.set_first_ifd(maker_ifd)
    note = b"Nikon\0\x02\x10\0\0" + bytes(maker.data)

    exif = t.ifd([(0x927C, UNDEFINED, note)])
    ifd0 = t.ifd([
        (271, ASCII, "NIKON CORPORATION"),
        (272, ASCII, "SANDGLASS MAKERNOTE"),
        (274, SHORT, [8]),
        (34665, LONG, [exif]),
    ])
    t.set_first_ifd(ifd0)
    return bytes(t.data)


def main():
    embedded, small_offset, big_offset, sub0 = embedded_little_endian()
    with open(os.path.join(HERE, "Embedded.NEF"), "wb") as handle:
        handle.write(embedded)
    # A length that runs past the end of the file: the full-size preview must be
    # rejected and the small one used instead. Entry 4 of SubIFD0 is tag 514.
    corrupt = bytearray(embedded)
    value = sub0 + 2 + 3 * 12 + 8
    corrupt[value:value + 4] = struct.pack("<I", 0x7FFFFFF0)
    with open(os.path.join(HERE, "CorruptLength.NEF"), "wb") as handle:
        handle.write(bytes(corrupt))
    with open(os.path.join(HERE, "EmbeddedStrip_BE.NEF"), "wb") as handle:
        handle.write(strip_big_endian())
    with open(os.path.join(HERE, "MakerNotePreview.NEF"), "wb") as handle:
        handle.write(maker_note_preview())
    # Cut off mid-way: the IFDs (written last) are gone, so nothing is found.
    with open(os.path.join(HERE, "Truncated.NEF"), "wb") as handle:
        handle.write(embedded[:big_offset + 600])
    print("wrote fixtures; small preview at", small_offset, "big preview at", big_offset)


if __name__ == "__main__":
    main()
