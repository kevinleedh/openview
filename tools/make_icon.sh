#!/usr/bin/env bash
# Regenerate the macOS app icon (tools/artifacts/AppIcon.icns) from the 1024×1024 master logo.
# The committed AppIcon.icns is what the build scripts bundle; rerun this only if the logo changes.
#   ./tools/make_icon.sh ["path/to/1024.png"]
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="${1:-Logo/Openview Logo-iOS-Default-1024x1024@1x.png}"
[ -f "$SRC" ] || { echo "✗ source logo not found: $SRC"; exit 1; }

ISET="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$ISET"
gen() { sips -z "$1" "$1" "$SRC" --out "$ISET/$2" >/dev/null; }   # square: H==W
gen 16   icon_16x16.png
gen 32   icon_16x16@2x.png
gen 32   icon_32x32.png
gen 64   icon_32x32@2x.png
gen 128  icon_128x128.png
gen 256  icon_128x128@2x.png
gen 256  icon_256x256.png
gen 512  icon_256x256@2x.png
gen 512  icon_512x512.png
cp "$SRC" "$ISET/icon_512x512@2x.png"      # 1024 master as-is

mkdir -p tools/artifacts
iconutil -c icns "$ISET" -o tools/artifacts/AppIcon.icns
rm -rf "$(dirname "$ISET")"
echo "✓ tools/artifacts/AppIcon.icns"
