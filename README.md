# Sandglass

A small, fast macOS app for culling **JPG + NEF** photo pairs.

Open a folder, step through the photos, flip between the JPG and the NEF with one
key, flag what you want to keep, then save everything you flagged into a folder
you choose. Built with SwiftUI and the macOS 26 **Liquid Glass** design language.

<p align="center">
  <em>Header · filmstrip of paired shots · large preview · floating glass control bar</em>
</p>

---

## What it does

- **One tile per photo, not per file.** A `DSC_0001.JPG` and a `DSC_0001.NEF` are
  recognised as the same shot and shown once. Files with no sibling
  (a NEF-only or JPG-only) still appear, marked as such.
- **Switch variants.** A toggle (or `T`) flips the preview between JPG and NEF.
  With only one variant on disk the control tells you instead of failing silently.
- **Flag per variant.** Flagging records *which* file you want, not just *that*
  you liked the shot:
  - flag while viewing JPG → the `.JPG` is exported
  - flag while viewing NEF → the `.NEF` is exported
  - flag both → **both files** are exported
- **You choose the destination.** The export sheet lists exactly what will be
  written, then asks for a folder.
- **Copy or move.** Default is copy (originals stay put). Move removes the
  originals from the source folder.
- **Nothing is ever overwritten.** A name collision becomes `DSC_0001 2.NEF`.
- **Full-resolution preview.** The large pane is decoded at the image's native
  size — never a scaled-up thumbnail — and no tint, filter or colour transform is
  ever applied. Verified by test against real files.
- **Metadata on demand.** Press `M` (or the ⓘ button) for EXIF: camera, lens,
  exposure, dates, GPS coordinates and file facts.
- **Your choice of backdrop.** Six dark presets, or use any picture as the window
  background with an adjustable dimming level.

## Requirements

- macOS 26 or later (the Liquid Glass APIs require it)
- Xcode 26+ / Swift 6.2+ to build
- No third-party dependencies

## Build and run

```bash
./Scripts/build-app.sh              # release build → dist/Sandglass.app
open dist/Sandglass.app
```

For a debug build: `./Scripts/build-app.sh debug`.
For a universal build (Intel + Apple silicon): `./Scripts/build-app.sh release universal`.

## Release DMG

```bash
./Scripts/make-dmg.sh               # → dist/Sandglass-1.0.dmg
```

Builds a universal binary and packages it with an `Applications` shortcut for
drag-install plus a short read-me. The result is ad-hoc signed but **not
notarised**, so the first launch needs right-click → Open, or
System Settings → Privacy & Security → "Open Anyway".

Note: creating a disk image attaches a device to the system. If `hdiutil` is
blocked (sandboxed shells, some CI images) the script falls back to
`diskutil image create from`.

You can also open a shoot straight from a terminal:

```bash
open -a dist/Sandglass.app --args ~/Pictures/Wedding
# or run the binary directly
dist/Sandglass.app/Contents/MacOS/Sandglass ~/Pictures/Wedding
```

## Using it

1. Click the folder chip in the header (or press `⌘O`) and pick a folder of photos.
2. Move through the folder. The filmstrip shows everything; the large pane shows
   the shot you are on.
3. Press `T` to flip between the JPG and the NEF. The header badge shows which
   variants a photo has, and the flag marker says which ones you kept.
4. Press `F` to flag what is on screen, or `B` to keep both halves of the pair.
5. When you reach the end, press `⌘E`, check the list, and choose a destination.
6. Sandglass copies (or moves) the flagged files and tells you what it did.

### Keyboard

| Key | Action |
| --- | --- |
| `←` `→` / `↑` `↓` / `Space` | Previous / next photo |
| `J` / `K` | Next / previous photo |
| `T` | Switch between JPG and NEF |
| `F` | Flag the variant on screen |
| `B` | Flag both JPG and NEF |
| `1` / `2` | Flag only the JPG / only the NEF |
| `+` `−` `0` | Zoom in / out / reset |
| `M` | Show or hide the file info panel |
| `⌘O` | Open a folder |
| `⌘E` | Export flagged photos |
| `⌘J` / `⌘K` | Show the JPG / show the NEF |
| `B` | Background colour or picture |
| `⌘R` | Reload the folder |
| `?` (header button) | Shortcut reference in-app |

## Preview quality and speed

The large preview is the point of the app, so it is decoded properly and quickly:

- **Native resolution.** The pane requests up to a 3200 px long edge; ImageIO
  returns the image's own pixels when it is smaller than that, so a 1600 px JPG is
  shown at 1600 px, not interpolated up from a thumbnail. Downscaling only
  happens for images larger than the request.
- **No colour management surprises.** Pixels are decoded in the file's own colour
  space (sRGB stays sRGB) and drawn with high-quality interpolation. Sandglass
  never applies a filter, tint, saturation change or blend mode to a photo.
- **Small prefetch, then the sharp pass.** While you move through a folder, only
  the neighbouring shots are prefetched, at a modest 1400 px, so the pane is
  filled instantly. The full-resolution decode for the shot you actually stop on
  is debounced by 90 ms, so holding an arrow key does not start a heavy decode for
  every photo you pass. A small "Loading full resolution…" chip shows while the
  sharp version is still on its way.
- **Bounded cache.** Decoded previews are held in an LRU cache capped at 384 MB,
  so a long culling session cannot grow without limit.

## Background

The **◐** button in the header (or `B`) opens the background picker:

- **Colour** — six presets chosen to keep the glass panels and their text legible.
- **Picture** — pick any image. It is copied into Application Support and
  downscaled to a 2560 px long edge, so it keeps working even if you move the
  original. A dimming slider darkens it to taste.

The interface automatically switches between dark and light text based on how
bright your chosen backdrop is. This affects only the backdrop — photographs are
never altered.

## How files are recognised

Pairing is by **base name, case-insensitively**: `DSC_0001.JPG` and `dsc_0001.nef`
are one shot.

Deliberately, it does **not** try to fold numeric suffixes together:
`DSC_0002-2.NEF` is treated as its own shot rather than being guessed to belong to
`DSC_0002`, because camera numbering makes that guess wrong often enough to be
harmful. `IMG_1` and `IMG_10` likewise stay separate.

Managed extensions are `jpg`, `jpeg` and `nef`. Other formats (`.CR2`, `.ARW`,
`.PNG`, …) are ignored. Only the chosen folder is scanned; subfolders are not.

## Project layout

```
Sources/Sandglass/
  main.swift              entry point, CLI dispatch
  AppDelegate.swift       window, menu bar, global keyboard handling
  Models.swift            FileKind, FlagSelection, Shot, base-name pairing
  FolderScanner.swift     folder enumeration → shots
  ThumbnailLoader.swift   concurrent ImageIO decoding + LRU cache
  LibraryModel.swift      app state: folder, selection, flags, previews, export
  Exporter.swift          copy/move engine
  MetadataReader.swift    EXIF / GPS / file facts
  BackgroundSettings.swift  backdrop presets, image store and loader
  RootView.swift          layout, commands, help sheet
  HeaderBar.swift         title, folder picker, progress, background + info
  PhotoGridView.swift     the filmstrip
  PreviewPane.swift       large full-resolution preview, zoom, empty states
  MetadataPanel.swift     the info sidebar
  BackgroundPicker.swift  backdrop chooser popover
  Controls.swift          variant toggle, flag buttons, navigation, zoom
  ExportSheet.swift       export confirmation
  GlassStyle.swift        shared Liquid Glass styling
Tests/SandglassTests/     unit tests over the real logic
Tests/Fixtures/           a sample shoot used by the tests
Scripts/build-app.sh      build + .app assembly
Scripts/make-dmg.sh       universal release DMG
Scripts/make-icon.swift   draws the app icon in code
Resources/Sandglass.icns  generated icon
```

## App icon

The icon is a Liquid Glass hourglass, **drawn programmatically** in
`Scripts/make-icon.swift` with Core Graphics — a smoked-glass squircle tile with a
frosted hourglass and champagne sand. Regenerate it with:

```bash
./Scripts/make-icon.sh
```

Because it is code rather than a binary blob, the icon is reproducible and
reviewable as a diff. It is compiled into `Resources/Sandglass.icns` at build time
if missing.

## Verification

```bash
CLANG_MODULE_CACHE_PATH="$PWD/.cache/clang" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.cache/module" \
swift test --disable-sandbox --cache-path "$PWD/.cache/swiftpm"
```

44 tests cover variant detection, pairing (including the cases above), flag
semantics, export planning, and real files on disk — scanning a folder, copying
exactly the flagged variants, moving them out of the source, and refusing to
overwrite an existing file. Previews are decoded from real files, including a
genuine Nikon NEF, and are asserted to be pixel-exact and colour-space preserving.
Metadata parsing is covered against a fixture with real EXIF and GPS. The preview
pipeline is covered end to end: caching a grid tile first, then asserting the
large preview still reaches full resolution at the correct display size.

There is also a headless end-to-end check that runs the real scan → flag → export
path on a folder of your choosing and prints what it did:

```bash
dist/Sandglass.app/Contents/MacOS/Sandglass --report ~/Pictures/Wedding
```

## Performance notes

Measured on the sample shoot with `Sandglass --bench <folder>`, a cold decode is
only tens of milliseconds, so decode cost is not what makes an interface feel
slow. What matters is not asking for the wrong thing:

- **One cache entry per rendition.** Keys include the pixel budget. Previously a
  small grid tile and the large preview shared a key, so a 320 px tile could win
  the race and then be drawn into the whole preview pane — the single biggest
  cause of a soft-looking preview.
- **Retina-correct sizing.** An `NSImage` made from a `CGImage` is sized in
  points, so it is set to half the pixel count. Sizing it by pixel count makes it
  draw at 1× on a 2× display, stretching each pixel over two device pixels.
- **No filesystem calls in the decode path.** Cache lookup takes a path, not a
  modification-date probe, so a grid render does not serialise hundreds of stats
  behind one actor.
- **Lazy bitmap realisation.** Thumbnails are created without forcing an
  immediate full decode, so a tile that scrolls past never pays for one.

### A note on NEF previews

Previews are decoded with ImageIO, which reads the **embedded preview** inside a
NEF rather than demosaicing the full raw — that is what keeps the grid fast.

Some raw files carry no preview that macOS can read. When that happens Sandglass
does not stall or crash: the tile and the preview pane say *"No preview
available"* and offer **Open in Default App**. Flagging and exporting are
unaffected, so such a file can still be culled and kept.
