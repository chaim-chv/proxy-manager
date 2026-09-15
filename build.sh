#!/bin/bash
set -euo pipefail

VERSION="${1:-1.0.0}"
APP_NAME="ProxyManager"
BUNDLE_ID="com.proxymanager.app"
HELPER_NAME="com.proxymanager.helper"
MIN_MACOS="14.0"
OUTPUT_DIR="${OUTPUT_DIR:-.}"
APP_BUNDLE="$OUTPUT_DIR/$APP_NAME.app"
MACOS_DIR="$APP_BUNDLE/Contents/MacOS"
RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"
DAEMONS_DIR="$APP_BUNDLE/Contents/Library/LaunchDaemons"

# App sources: everything except the helper's own target.
APP_SOURCES=()
while IFS= read -r -d '' f; do
    APP_SOURCES+=("$f")
done < <(find Sources -name '*.swift' -not -path 'Sources/Helper/*' -print0 | sort -z)

# Helper sources: shared protocol + the helper target.
HELPER_SOURCES=(Sources/System/HelperProtocol.swift)
while IFS= read -r -d '' f; do
    HELPER_SOURCES+=("$f")
done < <(find Sources/Helper -name '*.swift' -print0 | sort -z)

# Honor optional override of target architecture (default: native host arch).
if [ -z "${ARCH:-}" ]; then
    ARCH="$(uname -m)"
fi

# Signing identity: default ad-hoc. Override with a Developer ID to enable
# SMAppService.daemon registration, e.g.:
#   IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build.sh 1.0.0
IDENTITY="${IDENTITY:--}"

echo "🔨 Building $APP_NAME v$VERSION for $ARCH (macOS $MIN_MACOS+)..."

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$DAEMONS_DIR"

cat > "$APP_BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>Proxy Manager</string>
    <key>LSMinimumSystemVersion</key>
    <string>$MIN_MACOS</string>
    <key>LSUIElement</key>
    <false/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Proxy Manager</string>
</dict>
</plist>
EOF

# Compile. Swift auto-links imported frameworks (SwiftUI, Charts, Network,
# ServiceManagement, Security, SQLite3). Use Swift 5 language mode to avoid
# strict-concurrency diagnostics in the proxy core.
compile() {
    local target="$1"
    local out="$2"
    shift 2
    xcrun swiftc \
        -swift-version 5 \
        -O \
        -target "${target}-apple-macosx${MIN_MACOS}" \
        -framework AppKit \
        -framework SwiftUI \
        -framework Charts \
        -framework Network \
        -framework ServiceManagement \
        -framework Security \
        "$@" \
        -o "$out"
}

if [ "${UNIVERSAL:-0}" = "1" ] && [ "$ARCH" = "arm64" ]; then
    echo "🛠  Building universal (arm64 + x86_64)…"
    compile arm64 "$MACOS_DIR/$APP_NAME.arm64" "${APP_SOURCES[@]}"
    compile x86_64 "$MACOS_DIR/$APP_NAME.x86_64" "${APP_SOURCES[@]}"
    lipo -create -output "$MACOS_DIR/$APP_NAME" \
        "$MACOS_DIR/$APP_NAME.arm64" "$MACOS_DIR/$APP_NAME.x86_64"
    rm -f "$MACOS_DIR/$APP_NAME.arm64" "$MACOS_DIR/$APP_NAME.x86_64"
else
    compile "$ARCH" "$MACOS_DIR/$APP_NAME" "${APP_SOURCES[@]}"
fi

# Compile the privileged helper daemon.
compile "$ARCH" "$DAEMONS_DIR/$HELPER_NAME" "${HELPER_SOURCES[@]}"

# Embed the launch daemon plist (used by SMAppService.daemon).
cat > "$DAEMONS_DIR/$HELPER_NAME.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$HELPER_NAME</string>
    <key>MachServices</key>
    <dict>
        <key>$HELPER_NAME</key>
        <true/>
    </dict>
</dict>
</plist>
EOF

# Copy localizations if present.
if [ -d "Resources" ] && [ -n "$(ls -A Resources 2>/dev/null)" ]; then
    cp -R Resources/*.lproj "$RESOURCES_DIR/" 2>/dev/null || true
    echo "📦 Copied resource files"
fi

codesign --force --deep --sign "$IDENTITY" "$APP_BUNDLE"

echo "✅ Done! $APP_NAME.app v$VERSION is ready in $OUTPUT_DIR"
