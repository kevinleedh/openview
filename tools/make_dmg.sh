#!/usr/bin/env bash
# Build a downloadable Openview.dmg (drag-to-Applications) — AD-HOC signed, NOT notarized.
# Good for: testing the download/install experience, or sharing with people who can right-click → Open.
# For a real online release with NO Gatekeeper warning, use ./build_and_notarize.sh (needs a Developer ID cert).
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Openview"
OUT="build"; APP="$OUT/$APP_NAME.app"; DMG="$OUT/$APP_NAME.dmg"

rm -rf "$OUT"; mkdir -p "$OUT/Contents" >/dev/null 2>&1 || true
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> build (release)"
swift build -c release -q
BIN="$(swift build -c release --show-bin-path)/Openview"
[ -f "$BIN" ] || { echo "✗ build product missing: $BIN"; exit 1; }

echo "==> assemble $APP_NAME.app (icon + Core ML model)"
cp "$BIN" "$APP/Contents/MacOS/Openview"
cp Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
[ -f tools/artifacts/AppIcon.icns ] && cp tools/artifacts/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if [ -d tools/artifacts/e5-small-v2.mlpackage ]; then
  cp -R tools/artifacts/e5-small-v2.mlpackage "$APP/Contents/Resources/"
  cp tools/artifacts/e5-vocab.txt tools/artifacts/e5-tokenizer.json "$APP/Contents/Resources/"
fi
codesign --force --deep --sign - "$APP" >/dev/null && echo "ad-hoc signed"

echo "==> build $DMG (with Applications symlink)"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "✓ $DMG  ($(du -h "$DMG" | cut -f1))"
echo "  NOTE: ad-hoc (not notarized) — recipients must right-click → Open the first time."
