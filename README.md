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
| Mouse wheel | Zoom about the pointer |
| Pinch, or ⌘-scroll | Zoom on a trackpad |
| Two-finger scroll / drag | Pan while zoomed in |
| Double-click | Toggle fit ↔ 2× |
| Pinch / ⌘-scroll | Zoom about the pointer |

When you zoom in, a **navigator** appears in the bottom-right corner: the whole
photo with a rectangle marking the part on screen. The rectangle tracks every
zoom and pan, so it always shows where you are. Click or drag inside it to move
around; it hides again at fit.

A mouse wheel zooms about the pointer; on a trackpad, pinch or ⌘-scroll zooms and
two-finger scroll pans.
| `M` | Show or hide the file info panel |
| `⌘O` | Open a folder |
| `⌘E` | Export flagged photos |
| `⌘J` / `⌘K` | Show the JPG / show the NEF |
| `B` | Background colour wheel, presets or a picture |
| `⌘R` | Reload the folder |
| `?` (header button) | Shortcut reference in-app |

## Preview quality and speed

The large pane is not a preview — it is the file, opened. That distinction turned
out to matter:

- **The file is decoded, not thumbnailed.** `CGImageSourceCreateImageAtIndex`
  returns the image proper; `CGImageSourceCreateThumbnailAtIndex` can answer with
  an embedded preview instead, which is exactly the softness this app must not
  show. EXIF orientation is applied here as a transform, since the direct decode
  does not apply it.
- **The whole image, verified.** The app compares the decoded bitmap against the
  dimensions the file reports about itself, and `--inspect` prints the result:
  `file 6000x6000 -> 6000x6000  whole image`. A downscaled proxy would be
  reported as `PARTIAL` rather than passing silently.
- **Faster, as well as sharper.** Bypassing the thumbnail path took the average
  from ~95 ms to under 10 ms per photo, because the system no longer decodes and
  resamples synchronously.
- **No colour management surprises.** Pixels are decoded in the file's own colour
  space and drawn without filters, tint, saturation changes or blend modes.
- **Zoom magnifies real pixels**, because what is on screen is already the whole
  file, and the framing is derived from state rather than accumulated movement,
  so zooming and resizing can never drift the photo into a corner.
- **Bounded memory.** The native bitmap is held only for the photo on screen and
  kept out of the shared tile cache; one 24 MP decode is ~144 MB. Files above
  12000 px on the long edge are scaled on decode so an extreme scan cannot
  exhaust memory.

## Background

The **◐** button in the header (or `B`) opens the background picker:

- **Preset** — six ready-made backdrops.
- **Wheel** — a full colour picker for any colour you like, plus a row of neutral
  starting points and a live hex readout.
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
  ImageCanvas.swift       layer-backed zoom/pan surface
  NavigatorView.swift     the corner navigator shown while zoomed in
  PreviewPane.swift       preview states and overlays
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

52 tests cover variant detection, pairing (including the cases above), flag
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

And two diagnostics for image quality and speed, which report facts rather than
impressions:

```bash
# Is the pane receiving each file's whole image, or a proxy?
dist/Sandglass.app/Contents/MacOS/Sandglass --inspect ~/Pictures/Wedding

# How long does opening a folder and moving through it really take?
dist/Sandglass.app/Contents/MacOS/Sandglass --flow ~/Pictures/Wedding

# Cold decode cost at every size the app requests
dist/Sandglass.app/Contents/MacOS/Sandglass --bench ~/Pictures/Wedding
```

## How the preview is rendered

The large pane is a `CALayer` whose `contents` is the decoded `CGImage`, sized to
the image's **own pixel dimensions** and fitted to the pane by a single
`CATransform3D`. Zoom and pan change that transform and nothing else.

This matters more than it sounds. The obvious approach — a SwiftUI `Image` with
`scaleEffect` — fails in two separate ways:

1. **It cannot keep up.** Every gesture change invalidates layout for the whole
   view tree, so zoom lags the cursor instead of tracking it. A layer transform
   is handled by the compositor, so it follows the hand at refresh rate.
2. **It cannot stay sharp.** `contentsGravity = .resizeAspect` rasterises the
   bitmap to fit the *view rectangle*. Magnifying that flattened layer is
   magnifying a screenshot, so zooming in only ever gets softer. Sizing the layer
   to the photo's true pixels and scaling geometrically means zoom magnifies real
   pixels.

Three further details, each of which independently softens the image if missed:

- **The image layer's `contentsScale` is pinned to `1`.** Left at the screen's
  scale (2 on Retina) the layer allocates a 2× backing store and interpolates the
  photo up into it before the transform even runs.
- **The view's own layer composites at the display scale.** Left at the default 1
  the whole pane is rendered into a 1× backing store and then blown up to fill a
  Retina screen, softening every pixel.
- **Decode budgets are part of the cache key.** Without that, a 320 px grid tile
  and the large preview collide: whichever finishes first wins, and the pane ends
  up drawing a tile-sized image across the whole window.

The pane also refuses to show a low-resolution bitmap at all. It will fall back to
a rendition decoded at the *current* budget, but never to a grid tile — briefly
showing a loading state is far better than showing a mosaic of the photo.

These are covered by tests that render the canvas and *measure* the output:
magnifying a 3 px checkerboard by 2×/3×/4× must produce runs of exactly 6/9/12
pixels with **zero** intermediate grey pixels. Interpolation of any kind fails
that assertion.

## Performance notes

Measured with `Sandglass --bench <folder>` and `Sandglass --flow <folder>` on
24 MP files, a cold decode is tens of milliseconds, so raw decode speed is not
what makes a viewer feel slow. What matters is not asking for the wrong thing:

- **Decode only what the pane can show.** The pixel budget is derived from the
  pane's real size (`--flow` reports it), not a fixed number. A fixed 4200 px
  budget on a 6000 px file costs ~70 MB per image, which thrashes the cache and
  forces a fresh decode on every step. The shipping window asks for ~1968 px.
- **The visible photo goes first.** Single-file requests are independent
  high-priority tasks; filmstrip tiles go through a lower-priority group, so
  hundreds of queued tiles cannot starve the photo on screen.
- **No filesystem calls in the decode path.** Cache lookup takes a path, not a
  modification-date probe, so a grid render does not serialise hundreds of stat
  calls behind one actor.
- **Lazy bitmap realisation.** Thumbnails are created without forcing an
  immediate full decode, so a tile that scrolls past never pays for one.
- **Zooming is already sharp.** Because the pane always holds a native decode,
  zooming magnifies real pixels with nothing further to fetch.

Measured on a 24 MP shoot: folder open 18 ms, average preview 42 ms.

### A note on NEF previews

Previews are decoded with ImageIO, which reads the **embedded preview** inside a
NEF rather than demosaicing the full raw — that is what keeps the grid fast.

Some raw files carry no preview that macOS can read. When that happens Sandglass
does not stall or crash: the tile and the preview pane say *"No preview
available"* and offer **Open in Default App**. Flagging and exporting are
unaffected, so such a file can still be culled and kept.
