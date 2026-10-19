#!/bin/bash
# Regenerates appicon.png and Resources/AppIcon.icns from tools/dish.svg (via DishShape.swift).
set -euo pipefail
cd "$(dirname "$0")/.."
TMP=$(mktemp -d)
cat Sources/DishShape.swift tools/make-icon.swift > "$TMP/main.swift"
xcrun swift "$TMP/main.swift"
rm -rf "$TMP"
