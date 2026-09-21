#!/bin/bash
# Regenerate Resources/Sandglass.icns from Scripts/make-icon.swift.
#
# The icon is drawn in code, so it is reproducible and reviewable as a diff
# rather than an opaque binary. Run this after editing the generator.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

mkdir -p "$ROOT/Resources" "$ROOT/.cache/clang"

CLANG_MODULE_CACHE_PATH="$ROOT/.cache/clang" \
    swift "$ROOT/Scripts/make-icon.swift" \
    "$ROOT/Resources/Sandglass.icns" \
    "$ROOT/.cache/iconwork"
