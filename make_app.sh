#!/usr/bin/env bash
# Assemble a minimal Openview.app bundle (no Xcode) so native ⌘O menus, Dock identity, and
# Launch Services PDF registration work. Release build by default for a fair native-scroll test
# (override with CONFIG=debug). Mirrors the proven prior-build script (files/migration_appkit.md).
#
# IMPORTANT (crash fix): the finished app is INSTALLED TO AND RUN FROM the internal disk
# (~/Applications by default, override with OPENVIEW_INSTALL_DIR). Running the executable from the
# external SSD caused hard SIGBUS crashes: when the volume momentarily unmounts/sleeps, the
# memory-mapped Mach-O __TEXT pages lose their backing vnode and the next instruction fetch is a
# bus error. The source tree and PDFs may stay on the SSD; only the running binary must not.
set -euo pipefail
cd "$(dirname "$0")"
CONFIG="${CONFIG:-release}"
INSTALL_DIR="${OPENVIEW_INSTALL_DIR:-$HOME/Applications}"
APP_NAME="Openview.app"

swift build -c "$CONFIG" -q
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Openview"

# Assemble in a staging dir, then install onto the internal disk. (Building/staging on the SSD is fine
# — only the *running* binary must live on the internal volume.)
STAGE="$(mktemp -d)/$APP_NAME"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN" "$STAGE/Contents/MacOS/Openview"
cp Info.plist "$STAGE/Contents/Info.plist"
printf 'APPL????' > "$STAGE/Contents/PkgInfo"
# App icon (Info.plist CFBundleIconFile = AppIcon). Generated from the logo by tools/make_icon.sh.
[ -f tools/artifacts/AppIcon.icns ] && cp tools/artifacts/AppIcon.icns "$STAGE/Contents/Resources/AppIcon.icns"
# No Python sidecar. Embeddings = e5-small-v2 via Core ML (bundled .mlpackage) + a pure-Swift tokenizer, so
# a plain .dmg download runs the AI features with ZERO extra installs (inference is Swift+CoreML, no torch).
# Built once by tools/convert_e5.py → tools/artifacts/. Falls back to NLEmbedding if the model is absent.
if [ -d tools/artifacts/e5-small-v2.mlpackage ]; then
  cp -R tools/artifacts/e5-small-v2.mlpackage "$STAGE/Contents/Resources/"
  cp tools/artifacts/e5-vocab.txt tools/artifacts/e5-tokenizer.json "$STAGE/Contents/Resources/"
  echo "bundled e5-small-v2 Core ML model + tokenizer"
else
  echo "WARNING: tools/artifacts/e5-small-v2.mlpackage missing — app will use the NLEmbedding fallback. Run tools/convert_e5.py."
fi

# Ad-hoc sign → stable code identity so Keychain items stay readable across relaunches of the SAME
# binary (a rebuild changes the signature and orphans prior items — expected in dev). No --deep: the
# bundle has a single Mach-O. Failures are NOT masked — signing is a
# foundation gate (migration_appkit.md), so set -e must abort and show stderr. Sign the staged bundle
# (ad-hoc signatures are path-independent, so the post-copy bundle stays valid).
codesign --force --sign - "$STAGE" && echo "ad-hoc signed"

# Install onto the internal disk.
mkdir -p "$INSTALL_DIR"
APP="$INSTALL_DIR/$APP_NAME"
rm -rf "$APP"
ditto "$STAGE" "$APP"
rm -rf "$(dirname "$STAGE")"
echo "installed $APP"

# Remove any stale copy sitting on the SSD next to the sources — running THAT is the crash we just fixed.
if [ -d "$PWD/$APP_NAME" ]; then rm -rf "$PWD/$APP_NAME"; echo "removed stale $PWD/$APP_NAME (do not run from the SSD)"; fi

# Register with Launch Services so it picks up CFBundleDocumentTypes (PDF) → 'Open With → Openview'.
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREG" -f "$APP" && echo "lsregister OK"
echo "built $APP"
echo "run:  open '$APP' --args '$PWD/PDF Samples/1706.03762v7.pdf'"
