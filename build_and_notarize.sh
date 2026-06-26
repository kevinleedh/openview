#!/usr/bin/env bash
# Openview — build → Developer ID sign (Hardened Runtime) → .dmg → notarize → staple → verify.
#
# NOTE: this project is a Swift Package (NOT an Xcode project), so there is no scheme / `xcodebuild
# archive`. We build with `swift build -c release` and assemble the .app by hand (same shape as make_app.sh).
# Feature code / pipeline are NOT touched — this only builds, signs, packages, and notarizes.
#
# One-time prerequisites (you must do these — they need your Apple Developer login & secrets):
#   1. Create a "Developer ID Application" certificate for team 7ZK3PB84L8 at
#      https://developer.apple.com/account/resources/certificates → download → double-click to install.
#      Verify:  security find-identity -v -p codesigning   (must list "Developer ID Application: … (7ZK3PB84L8)")
#      Put that EXACT string in SIGN_IDENTITY below.  (An "Apple Development" cert will NOT work.)
#   2. Make an app-specific password at https://appleid.apple.com (Sign-In & Security → App-Specific Passwords).
#   3. Store notary credentials once (run it yourself — do not paste secrets into this file):
#        xcrun notarytool store-credentials "AC_NOTARY" \
#          --apple-id "<your-apple-id-email>" --team-id 7ZK3PB84L8 --password "<app-specific-password>"
#   Then:  ./build_and_notarize.sh
set -euo pipefail
cd "$(dirname "$0")"

# ----------------------------------------------------------------------------- config (EDIT THESE)
APP_NAME="Openview"
BUNDLE_ID="com.openview.app"
TEAM_ID="7ZK3PB84L8"
SIGN_IDENTITY="Developer ID Application: YOUR NAME (7ZK3PB84L8)"   # <-- from `security find-identity -v -p codesigning`
NOTARY_PROFILE="AC_NOTARY"                                          # <-- the name you used in `notarytool store-credentials`
SWIFT_PRODUCT="Openview"                                              # the SwiftPM executable target (binary name in build dir)
ENTITLEMENTS="Openview.entitlements"                               # optional; only used if the file exists
# -----------------------------------------------------------------------------

OUT="build"
APP="$OUT/$APP_NAME.app"
DMG="$OUT/$APP_NAME.dmg"
ZIP="$OUT/$APP_NAME.zip"
PB=/usr/libexec/PlistBuddy

# --- preflight: fail early with actionable guidance ---------------------------
if ! security find-identity -v -p codesigning | grep -q "Developer ID Application:.*($TEAM_ID)"; then
  echo "✗ No 'Developer ID Application: … ($TEAM_ID)' certificate in the keychain."
  echo "  Create one at developer.apple.com (see the header of this script), then set SIGN_IDENTITY."
  security find-identity -v -p codesigning || true
  exit 1
fi
if [[ "$SIGN_IDENTITY" == *"YOUR NAME"* ]]; then
  echo "✗ Set SIGN_IDENTITY to the exact identity string from: security find-identity -v -p codesigning"; exit 1
fi
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "✗ Notary profile '$NOTARY_PROFILE' not found. Run notarytool store-credentials first (see header)."; exit 1
fi

rm -rf "$OUT"; mkdir -p "$OUT"

echo "==> 1/7  Release build (swift build -c release)"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/$SWIFT_PRODUCT"
[ -f "$BIN" ] || { echo "✗ build product not found: $BIN"; exit 1; }

echo "==> 2/7  Assemble $APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# No Python sidecar — embeddings = e5-small-v2 via Core ML (bundled .mlpackage) + Swift tokenizer, zero installs.
if [ -d tools/artifacts/e5-small-v2.mlpackage ]; then
  cp -R tools/artifacts/e5-small-v2.mlpackage "$APP/Contents/Resources/"
  cp tools/artifacts/e5-vocab.txt tools/artifacts/e5-tokenizer.json "$APP/Contents/Resources/"
fi
# Rebrand the STAGED Info.plist to Openview (the repo Info.plist stays "Openview" so dev's make_app.sh is unaffected).
"$PB" -c "Set :CFBundleName $APP_NAME"        "$APP/Contents/Info.plist"
"$PB" -c "Set :CFBundleDisplayName $APP_NAME" "$APP/Contents/Info.plist"
"$PB" -c "Set :CFBundleExecutable $APP_NAME"  "$APP/Contents/Info.plist"
"$PB" -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"

echo "==> 3/7  Sign (Developer ID + Hardened Runtime + secure timestamp)"
ENT=(); [ -f "$ENTITLEMENTS" ] && ENT=(--entitlements "$ENTITLEMENTS")
# Inside-out: nested code first (none today beyond the single Mach-O), then the bundle.
codesign --force --timestamp --options runtime "${ENT[@]}" --sign "$SIGN_IDENTITY" "$APP/Contents/MacOS/$APP_NAME"
codesign --force --timestamp --options runtime "${ENT[@]}" --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "--- authority ---"; codesign -dvvv "$APP" 2>&1 | grep -E "Authority|TeamIdentifier|flags|Runtime" || true

echo "==> 4/7  Notarize the app (zip → notarytool → staple)"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"        # ticket now travels with the .app even offline

echo "==> 5/7  Build the .dmg from the stapled app"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"

echo "==> 6/7  Notarize + staple the .dmg"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

echo "==> 7/7  Verify"
codesign --verify --deep --strict --verbose=2 "$APP"
spctl -a -t open --context context:primary-signature -vvv "$DMG" || true   # "accepted" = good
echo "✓ DONE → $DMG"
echo "  Next: attach $DMG to a GitHub Release, copy the asset URL into index.html, deploy the page."
