#!/bin/bash
# Regenerate the macOS app icon (Resources/AppIcon.icns) from Tools/AppIcon/main.swift.
#
#   ./Tools/AppIcon/make.sh
#
# Uses only system frameworks (SwiftUI/AppKit) and built-in tools (sips,
# iconutil) — no Xcode project or third-party dependencies. Run this after
# editing the icon design, then commit Resources/AppIcon.icns.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="$ROOT/Resources/AppIcon.icns"
WORK="$(mktemp -d)"
ICONSET="$WORK/AppIcon.iconset"
BIN="$WORK/appicon-gen"

ARCH="$(uname -m)"
xcrun swiftc -swift-version 5 -O -target "${ARCH}-apple-macosx14.0" \
    -framework SwiftUI -framework AppKit \
    "$HERE/main.swift" -o "$BIN"

"$BIN" "$WORK/master-1024.png"
mkdir -p "$ICONSET"

emit() { sips -z "$2" "$2" "$WORK/master-1024.png" --out "$ICONSET/$1" >/dev/null; }
emit icon_16x16.png 16
emit icon_16x16@2x.png 32
emit icon_32x32.png 32
emit icon_32x32@2x.png 64
emit icon_128x128.png 128
emit icon_128x128@2x.png 256
emit icon_256x256.png 256
emit icon_256x256@2x.png 512
emit icon_512x512.png 512
emit icon_512x512@2x.png 1024

iconutil -c icns "$ICONSET" -o "$OUT"
rm -rf "$WORK"

echo "✅ Wrote $OUT"
