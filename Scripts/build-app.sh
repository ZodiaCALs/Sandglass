#!/bin/bash
# Build Sandglass and assemble a double-clickable .app bundle.
#
# Everything (including SwiftPM's caches) stays inside the project folder so the
# build works in restricted environments and leaves no stray state elsewhere.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG="${1:-release}"
# Pass "universal" as a second argument to build for Intel and Apple silicon.
UNIVERSAL="${2:-}"
APP_NAME="Sandglass"
BUILD_DIR="$ROOT/.build"
APP_DIR="$ROOT/dist/$APP_NAME.app"

mkdir -p "$ROOT/.cache/module" "$ROOT/.cache/clang" "$ROOT/.cache/swiftpm"

export CLANG_MODULE_CACHE_PATH="$ROOT/.cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.cache/module"

ARCH_FLAGS=()
if [[ "$UNIVERSAL" == "universal" ]]; then
    ARCH_FLAGS=(--arch arm64 --arch x86_64)
    echo "==> Building ($CONFIG, universal)"
else
    echo "==> Building ($CONFIG)"
fi

swift build \
    --configuration "$CONFIG" \
    --disable-sandbox \
    --cache-path "$ROOT/.cache/swiftpm" \
    "${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}"

BINARY="$(swift build --configuration "$CONFIG" --disable-sandbox \
    --cache-path "$ROOT/.cache/swiftpm" \
    "${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}" --show-bin-path)/$APP_NAME"

if [[ ! -x "$BINARY" ]]; then
    echo "error: built binary not found at $BINARY" >&2
    exit 1
fi

echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BINARY" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

# The icon is drawn in code; regenerate it if it is missing.
if [[ ! -f "$ROOT/Resources/$APP_NAME.icns" ]]; then
    echo "==> Generating app icon"
    "$ROOT/Scripts/make-icon.sh"
fi
cp "$ROOT/Resources/$APP_NAME.icns" "$APP_DIR/Contents/Resources/$APP_NAME.icns"

# Ad-hoc signature: keeps macOS happy about a stable identity for the bundle.
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 \
    || echo "note: ad-hoc codesign skipped"

echo "==> Done: $APP_DIR"
echo "    open \"$APP_DIR\""
