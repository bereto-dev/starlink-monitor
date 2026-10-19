#!/bin/bash
# Builds StarlinkBar.app (universal: Apple Silicon + Intel) with the Xcode toolchain.
#   ./build.sh            -> build/StarlinkBar.app
#   ./build.sh --open     -> build and launch it
#   ./build.sh --zip      -> build and package dist/StarlinkBar-<version>.zip
set -euo pipefail
cd "$(dirname "$0")"

APP=build/StarlinkBar.app
BIN="$APP/Contents/MacOS/StarlinkBar"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)

rm -rf "$APP" build/obj
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj

for ARCH in arm64 x86_64; do
  xcrun swiftc -O -parse-as-library -swift-version 5 \
    -target "$ARCH-apple-macosx13.0" \
    -o "build/obj/StarlinkBar-$ARCH" Sources/*.swift
done
lipo -create -output "$BIN" build/obj/StarlinkBar-arm64 build/obj/StarlinkBar-x86_64

cp Info.plist "$APP/Contents/Info.plist"
# Ad-hoc signature. For downloads without the Gatekeeper warning, sign with a
# Developer ID and notarize (see README).
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
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "Packaged $ZIP"
    ;;
esac
