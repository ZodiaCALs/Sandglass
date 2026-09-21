#!/bin/bash
# Package Sandglass as a distributable DMG.
#
# Produces dist/Sandglass-<version>.dmg containing the app, an Applications
# shortcut for drag-install, and a short read-me.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="Sandglass"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
APP_DIR="$ROOT/dist/$APP_NAME.app"
DMG_PATH="$ROOT/dist/$APP_NAME-$VERSION.dmg"
STAGE="$ROOT/.cache/dmg-stage"

# Build universal so the release runs natively on Intel and Apple silicon alike.
"$ROOT/Scripts/build-app.sh" release universal

echo "==> Staging DMG contents"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP_DIR" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/Read Me.txt" <<'TXT'
Sandglass — JPG / NEF culling for macOS
=======================================

Install
-------
Drag Sandglass into the Applications folder.

First launch
------------
Sandglass is not notarised by Apple, so macOS will warn the first time.
Right-click the app and choose "Open", then confirm. After that it opens
normally by double-click. (Or: System Settings > Privacy & Security >
"Open Anyway".)

Requires macOS 26 or later.

Use
---
1. Open a folder of photos with the folder button in the header.
2. A JPG and a NEF that share a name are shown as one photo.
3. Press T to switch between the JPG and the NEF.
4. Press F to flag what is on screen, or B to keep both halves of the pair.
5. Press Cmd-E and choose where the flagged files should be saved.

Press the ? button in the header for the full keyboard reference.
TXT

echo "==> Building $DMG_PATH"
rm -f "$DMG_PATH"

# `hdiutil` is deprecated on macOS 27 but is still the only writer that honours
# -srcfolder; `diskutil image create from` is the supported replacement but does
# not lay out a drag-install window. Prefer hdiutil, fall back to diskutil.
created=0
if hdiutil create \
        -volname "$APP_NAME" \
        -srcfolder "$STAGE" \
        -ov \
        -format UDZO \
        -imagekey zlib-level=9 \
        "$DMG_PATH" >/dev/null 2>&1; then
    created=1
else
    echo "    hdiutil unavailable, falling back to diskutil"
    if diskutil image create from \
            --format UDZO \
            --volumeName "$APP_NAME" \
            "$STAGE" \
            "$DMG_PATH" >/dev/null 2>&1; then
        created=1
    fi
fi

rm -rf "$STAGE"

if [[ "$created" != "1" || ! -f "$DMG_PATH" ]]; then
    echo "error: could not create $DMG_PATH" >&2
    echo "note: building a disk image attaches a device and may be blocked in a sandbox." >&2
    exit 1
fi

# Report what was built, including the architectures inside.
echo ""
echo "==> Done: $DMG_PATH ($(du -h "$DMG_PATH" | cut -f1))"
echo "    architectures: $(lipo -archs "$APP_DIR/Contents/MacOS/$APP_NAME")"
echo "    verify with:   hdiutil verify \"$DMG_PATH\""
