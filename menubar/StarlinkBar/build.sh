#!/bin/bash
# Builds StarlinkBar.app (universal: Apple Silicon + Intel) with the Xcode toolchain.
#   ./build.sh            -> build/StarlinkBar.app
#   ./build.sh --open     -> build and launch it
#   ./build.sh --zip      -> build and package dist/StarlinkBar-<version>.zip
#
# Sparkle (automatic updates) is downloaded once into vendor/ and checked against
# its published SHA-256 before use. Nothing is vendored in git.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/StarlinkBar.app
BIN="$APP/Contents/MacOS/StarlinkBar"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)

SPARKLE_VERSION=2.10.0
SPARKLE_SHA256=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
SPARKLE_DIR=vendor/Sparkle-$SPARKLE_VERSION

if [[ ! -d "$SPARKLE_DIR/Sparkle.framework" ]]; then
  echo "Fetching Sparkle $SPARKLE_VERSION..."
  mkdir -p vendor
  TARBALL="vendor/Sparkle-$SPARKLE_VERSION.tar.xz"
  curl -fsSL -o "$TARBALL" \
    "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
  echo "$SPARKLE_SHA256  $TARBALL" | shasum -a 256 -c - >/dev/null || { echo "Sparkle checksum mismatch"; rm -f "$TARBALL"; exit 1; }
  rm -rf "$SPARKLE_DIR" && mkdir -p "$SPARKLE_DIR"
  tar -xJf "$TARBALL" -C "$SPARKLE_DIR"
  rm -f "$TARBALL"
fi

rm -rf "$APP" build/obj
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks" build/obj

for ARCH in arm64 x86_64; do
  xcrun swiftc -O -swift-version 5 \
    -target "$ARCH-apple-macosx13.0" \
    -F "$SPARKLE_DIR" -framework Sparkle \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -o "build/obj/StarlinkBar-$ARCH" Sources/*.swift
done
lipo -create -output "$BIN" build/obj/StarlinkBar-arm64 build/obj/StarlinkBar-x86_64

cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
ditto "$SPARKLE_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

# Ad-hoc signature, inside out (Sparkle's helpers first, then the framework, then the app).
# For downloads without the Gatekeeper warning, sign with a Developer ID and notarize.
FW="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for item in "$FW"/XPCServices/*.xpc "$FW/Autoupdate" "$FW/Updater.app"; do
  [[ -e "$item" ]] && codesign --force --sign - "$item" >/dev/null
done
codesign --force --sign - "$APP/Contents/Frameworks/Sparkle.framework" >/dev/null
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP ($VERSION, $(lipo -archs "$BIN"))"

case "${1:-}" in
  --open)
    pkill -x StarlinkBar 2>/dev/null || true
    open "$APP"
    ;;
  --zip)
    mkdir -p dist
    ZIP="dist/StarlinkBar-$VERSION.zip"
    rm -f "$ZIP"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
    echo "Packaged $ZIP"
    ;;
esac
