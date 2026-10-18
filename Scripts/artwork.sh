#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p build/visuals
xcrun swiftc -O -parse-as-library -target "$(uname -m)-apple-macosx13.0" \
    Sources/BoggartApp/SpiderIcon.swift Scripts/RenderAssets.swift \
    -framework SwiftUI -framework AppKit -o build/RenderAssets
./build/RenderAssets build/visuals
/usr/bin/iconutil -c icns build/visuals/AppIcon.iconset -o build/visuals/AppIcon.icns
