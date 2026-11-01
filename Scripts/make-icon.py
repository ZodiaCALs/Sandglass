#!/usr/bin/env python3
"""Regenerate the Sandglass app icon from its SVG design sources.

Renders Resources/Icon/Sandglass.svg (128-1024 px) and
Resources/Icon/Sandglass-small.svg (16-64 px) with resvg, packs
Resources/Sandglass.icns in pure Python, writes
Resources/Icon/Sandglass-1024.png as a preview, then reads the .icns back and
checks every entry.

One-time setup (prebuilt wheels, no compiler or Homebrew needed):

    python3 -m pip install --user --only-binary=:all: resvg-py

Usage:

    python3 Scripts/make-icon.py                  # regenerate + verify
    python3 Scripts/make-icon.py --iconset DIR    # also write DIR/icon_*.png
    python3 Scripts/make-icon.py --check          # only verify the .icns

The output is deterministic. resvg's PNGs are decoded and re-encoded here with
fixed settings, so the .icns is byte-identical for every resvg-py release that
renders the same pixels (0.1.6 through 0.5.0 all do). That covers the stock
macOS Python 3.9, which pip can only serve with older wheels.
"""

import argparse
import io
import os
import re
import struct
import sys
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICON_DIR = os.path.join(ROOT, "Resources", "Icon")
MAIN_SVG = os.path.join(ICON_DIR, "Sandglass.svg")
SMALL_SVG = os.path.join(ICON_DIR, "Sandglass-small.svg")
ICNS_PATH = os.path.join(ROOT, "Resources", "Sandglass.icns")
PREVIEW_PATH = os.path.join(ICON_DIR, "Sandglass-1024.png")

# Renditions at or below this size are drawn from the simplified small variant.
SMALL_VARIANT_MAX = 64

# ICNS entries in write order: (OSType, pixel size, iconset file name).
ICNS_ENTRIES = (
    (b"icp4", 16, "icon_16x16.png"),
    (b"icp5", 32, "icon_32x32.png"),
    (b"ic11", 32, "icon_16x16@2x.png"),
    (b"ic12", 64, "icon_32x32@2x.png"),
    (b"ic07", 128, "icon_128x128.png"),
    (b"ic13", 256, "icon_128x128@2x.png"),
    (b"ic08", 256, "icon_256x256.png"),
    (b"ic14", 512, "icon_256x256@2x.png"),
    (b"ic09", 512, "icon_512x512.png"),
    (b"ic10", 1024, "icon_512x512@2x.png"),
)
SIZES = sorted({size for _, size, _ in ICNS_ENTRIES})


class IconError(Exception):
    pass


def rel(path):
    return os.path.relpath(path, ROOT)


def say(message):
    """Print progress; if stdout is closed (e.g. piped to head), keep working."""
    try:
        print(message, flush=True)
    except BrokenPipeError:
        os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())


# --------------------------------------------------------------------------
# Rendering
# --------------------------------------------------------------------------

def load_renderer():
    """Import resvg-py, or explain exactly how to install it."""
    try:
        import resvg_py
    except ImportError:
        in_venv = sys.prefix != getattr(sys, "base_prefix", sys.prefix)
        user = "" if in_venv else " --user"
        sys.stderr.write(
            "error: the SVG renderer 'resvg-py' is not installed for this Python\n"
            "       (%s).\n\n"
            "Install it (prebuilt wheel, nothing to compile) and run again:\n\n"
            "    %s -m pip install%s --only-binary=:all: resvg-py\n\n"
            "If pip refuses with 'externally-managed-environment', use a venv:\n\n"
            "    python3 -m venv /tmp/icon-venv\n"
            "    /tmp/icon-venv/bin/pip install --only-binary=:all: resvg-py\n"
            "    /tmp/icon-venv/bin/python Scripts/make-icon.py\n"
            % (sys.executable, sys.executable, user)
        )
        sys.exit(1)
    if not hasattr(resvg_py, "svg_to_bytes"):
        raise IconError(
            "this resvg-py (%s) has no svg_to_bytes(); install a release from "
            "0.1.6 to 0.5.x" % getattr(resvg_py, "__version__", "unknown version")
        )
    return resvg_py


def _root_svg_tag(text):
    for match in re.finditer(r"<svg\b[^>]*>", text):
        before = text[:match.start()]
        if before.rfind("<!--") <= before.rfind("-->"):  # not inside a comment
            return match
    raise IconError("no <svg> root element found")


def svg_at_size(text, size):
    """Return the SVG with its root width/height set to `size` px.

    Older resvg-py releases (0.1.x-0.2.x) accept but ignore svg_to_bytes'
    width/height arguments and always render at the document's intrinsic size,
    so the size goes into the document itself; the viewBox scales the
    1024-unit drawing to it.
    """
    match = _root_svg_tag(text)
    tag = match.group(0)
    if "viewBox" not in tag:
        raise IconError("the root <svg> needs a viewBox to be rendered at other sizes")
    tag = re.sub(r"\s(?:width|height)\s*=\s*(\"[^\"]*\"|'[^']*')", "", tag)
    tag = tag.replace("<svg", '<svg width="%d" height="%d"' % (size, size), 1)
    return text[:match.start()] + tag + text[match.end():]


def render(resvg_py, svg_text, size):
    """Render to `size` x `size` and return straight-alpha RGBA bytes."""
    sized = svg_at_size(svg_text, size)
    try:
        png = resvg_py.svg_to_bytes(svg_string=sized, skip_system_fonts=True)
    except TypeError:  # a release without skip_system_fonts
        png = resvg_py.svg_to_bytes(svg_string=sized)
    width, height, rgba = decode_png(bytes(png))
    if (width, height) != (size, size):
        raise IconError("renderer produced %dx%d, expected %dx%d" % (width, height, size, size))
    return rgba


# --------------------------------------------------------------------------
# PNG codec (8-bit RGBA only, which is what resvg emits)
# --------------------------------------------------------------------------
# Rows are handled as big integers so that the Sub/Up/Average arithmetic runs
# on every byte of a row at once ("SIMD within a register"): masks keep each
# byte's carry or borrow from leaking into its neighbour.

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
_ABS_SIGNED = bytes(min(v, 256 - v) for v in range(256))  # |byte as int8|


def _lane_masks(stride):
    low7 = int.from_bytes(b"\x7f" * stride, "big")
    high = int.from_bytes(b"\x80" * stride, "big")
    no_low_bit = int.from_bytes(b"\xfe" * stride, "big")
    return low7, high, no_low_bit


def _add_lanes(a, b, low7, high):
    return ((a & low7) + (b & low7)) ^ ((a ^ b) & high)


def _sub_lanes(a, b, low7, high):
    return ((a | high) - (b & low7)) ^ ((a ^ ~b) & high)


def png_chunks(data):
    if data[:8] != PNG_SIGNATURE:
        raise IconError("not a PNG file")
    pos = 8
    while pos + 12 <= len(data):
        length, ctype = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        (crc,) = struct.unpack(">I", data[pos + 8 + length:pos + 12 + length])
        if zlib.crc32(ctype + body) & 0xFFFFFFFF != crc:
            raise IconError("PNG chunk %r has a bad CRC" % ctype)
        yield ctype, body
        pos += 12 + length
        if ctype == b"IEND":
            return
    raise IconError("PNG is truncated")


def decode_png(data):
    """Return (width, height, rgba) for an 8-bit RGBA, non-interlaced PNG."""
    header, idat = None, []
    for ctype, body in png_chunks(data):
        if ctype == b"IHDR":
            header = struct.unpack(">IIBBBBB", body)
        elif ctype == b"IDAT":
            idat.append(body)
    if header is None:
        raise IconError("PNG has no IHDR")
    width, height, depth, color, _, _, interlace = header
    if (depth, color, interlace) != (8, 6, 0):
        raise IconError("expected an 8-bit RGBA non-interlaced PNG")
    raw = zlib.decompress(b"".join(idat))
    stride = width * 4
    if len(raw) != height * (stride + 1):
        raise IconError("PNG image data has the wrong length")

    low7, high, _ = _lane_masks(stride)
    out = bytearray()
    prev = bytes(stride)
    prev_int = 0
    pos = 0
    for _ in range(height):
        kind = raw[pos]
        line = raw[pos + 1:pos + 1 + stride]
        pos += stride + 1
        if kind == 0:  # None
            cur = line
        elif kind == 1:  # Sub: running sum of each channel, in log2(width) steps
            x = int.from_bytes(line, "big")
            shift = 4
            while shift < stride:
                x = _add_lanes(x, x >> (8 * shift), low7, high)
                shift *= 2
            cur = x.to_bytes(stride, "big")
        elif kind == 2:  # Up
            cur = _add_lanes(int.from_bytes(line, "big"), prev_int, low7, high).to_bytes(stride, "big")
        elif kind == 3:  # Average (sequential)
            row = bytearray(line)
            for i in range(4):
                row[i] = (row[i] + (prev[i] >> 1)) & 0xFF
            for i in range(4, stride):
                row[i] = (row[i] + ((row[i - 4] + prev[i]) >> 1)) & 0xFF
            cur = bytes(row)
        elif kind == 4:  # Paeth (sequential)
            row = bytearray(line)
            for i in range(4):
                row[i] = (row[i] + prev[i]) & 0xFF
            for i in range(4, stride):
                a, b, c = row[i - 4], prev[i], prev[i - 4]
                pa, pb = b - c, a - c
                pc = abs(pa + pb)
                pa, pb = abs(pa), abs(pb)
                if pa <= pb and pa <= pc:
                    pred = a
                elif pb <= pc:
                    pred = b
                else:
                    pred = c
                row[i] = (row[i] + pred) & 0xFF
            cur = bytes(row)
        else:
            raise IconError("PNG uses unknown filter type %d" % kind)
        out += cur
        prev = cur
        prev_int = int.from_bytes(cur, "big")
    return width, height, bytes(out)


def _png_chunk(ctype, body):
    crc = zlib.crc32(ctype + body) & 0xFFFFFFFF
    return struct.pack(">I", len(body)) + ctype + body + struct.pack(">I", crc)


def encode_png(width, height, rgba):
    """Deterministic PNG: per-row None/Sub/Up/Average chosen by the usual
    minimum-sum-of-absolute-differences rule, zlib level 9, no metadata."""
    stride = width * 4
    low7, high, no_low_bit = _lane_masks(stride)
    data = bytearray()
    prev = 0
    for y in range(height):
        row = rgba[y * stride:(y + 1) * stride]
        x = int.from_bytes(row, "big")
        left = x >> 32
        average = (left & prev) + (((left ^ prev) & no_low_bit) >> 1)
        candidates = (
            (0, row),
            (1, _sub_lanes(x, left, low7, high).to_bytes(stride, "big")),
            (2, _sub_lanes(x, prev, low7, high).to_bytes(stride, "big")),
            (3, _sub_lanes(x, average, low7, high).to_bytes(stride, "big")),
        )
        kind, filtered = min(candidates, key=lambda c: sum(c[1].translate(_ABS_SIGNED)))
        data.append(kind)
        data += filtered
        prev = x
    header = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    return (
        PNG_SIGNATURE
        + _png_chunk(b"IHDR", header)
        + _png_chunk(b"IDAT", zlib.compress(bytes(data), 9))
        + _png_chunk(b"IEND", b"")
    )


# --------------------------------------------------------------------------
# ICNS container
# --------------------------------------------------------------------------

def build_icns(png_by_size):
    body = b"".join(
        ostype + struct.pack(">I", 8 + len(png_by_size[size])) + png_by_size[size]
        for ostype, size, _ in ICNS_ENTRIES
    )
    return b"icns" + struct.pack(">I", 8 + len(body)) + body


def read_icns(data):
    if data[:4] != b"icns":
        raise IconError("not an .icns file")
    (total,) = struct.unpack(">I", data[4:8])
    if total != len(data):
        raise IconError(".icns header says %d bytes, file has %d" % (total, len(data)))
    entries, pos = [], 8
    while pos < total:
        if pos + 8 > total:
            raise IconError(".icns entry header is truncated")
        ostype, length = struct.unpack(">4sI", data[pos:pos + 8])
        if length < 8 or pos + length > total:
            raise IconError(".icns entry %r has a bad length" % ostype)
        entries.append((ostype, data[pos + 8:pos + length]))
        pos += length
    return entries


def verify_icns(path):
    """Read the .icns back and check each entry decodes at the right size."""
    try:
        from PIL import Image  # optional second opinion
    except ImportError:
        Image = None
    with open(path, "rb") as f:
        data = f.read()
    entries = read_icns(data)
    expected = [(ostype, size) for ostype, size, _ in ICNS_ENTRIES]
    found = [ostype for ostype, _ in entries]
    if found != [ostype for ostype, _ in expected]:
        raise IconError("unexpected entries %s" % ", ".join(t.decode() for t in found))

    say("Verified %s (%d bytes, %d entries%s):"
        % (rel(path), len(data), len(entries), ", PNGs also decoded by Pillow" if Image else ""))
    for (ostype, png), (_, size) in zip(entries, expected):
        width, height, rgba = decode_png(png)
        if (width, height) != (size, size) or len(rgba) != size * size * 4:
            raise IconError("%s is %dx%d, expected %dx%d" % (ostype.decode(), width, height, size, size))
        if Image is not None:
            image = Image.open(io.BytesIO(png))
            image.load()
            if image.size != (size, size) or image.mode != "RGBA":
                raise IconError("Pillow reads %s as %s %s" % (ostype.decode(), image.size, image.mode))
        say("  %s  %4d x %-4d  %8d bytes" % (ostype.decode(), width, height, len(png)))


# --------------------------------------------------------------------------

def write_bytes(path, data):
    directory = os.path.dirname(path)
    if directory:
        os.makedirs(directory, exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)


def generate(iconset_dir):
    resvg_py = load_renderer()
    sources = {}
    for path in (MAIN_SVG, SMALL_SVG):
        if os.path.exists(path):
            with open(path, encoding="utf-8") as f:
                sources[path] = f.read()
    if MAIN_SVG not in sources:
        raise IconError("missing design source %s" % rel(MAIN_SVG))

    version = getattr(resvg_py, "__version__", "?")
    engine = getattr(resvg_py, "__resvg_version__", None)
    say("Rendering with resvg-py %s%s" % (version, " (resvg %s)" % engine if engine else ""))
    png_by_size = {}
    for size in SIZES:
        source = SMALL_SVG if size <= SMALL_VARIANT_MAX and SMALL_SVG in sources else MAIN_SVG
        png_by_size[size] = encode_png(size, size, render(resvg_py, sources[source], size))
        say("  %4d px  from %-22s %8d bytes" % (size, os.path.basename(source), len(png_by_size[size])))

    write_bytes(ICNS_PATH, build_icns(png_by_size))
    write_bytes(PREVIEW_PATH, png_by_size[1024])
    say("Wrote %s and %s" % (rel(ICNS_PATH), rel(PREVIEW_PATH)))
    if iconset_dir:
        for _, size, name in ICNS_ENTRIES:
            write_bytes(os.path.join(iconset_dir, name), png_by_size[size])
        say("Wrote %d PNGs to %s" % (len(ICNS_ENTRIES), iconset_dir))


def main(argv=None):
    parser = argparse.ArgumentParser(description="Regenerate Resources/Sandglass.icns from the SVG sources.")
    parser.add_argument("--iconset", metavar="DIR",
                        help="also write each rendition as DIR/icon_<size>.png (an .iconset layout)")
    parser.add_argument("--check", action="store_true",
                        help="only verify the existing Resources/Sandglass.icns; render nothing")
    args = parser.parse_args(argv)
    try:
        if not args.check:
            generate(args.iconset)
        verify_icns(ICNS_PATH)
    except (IconError, OSError, struct.error, zlib.error) as exc:
        sys.stderr.write("error: %s\n" % exc)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
