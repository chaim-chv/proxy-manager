#!/bin/bash
set -euo pipefail

VERSION="${1:-1.0.0}"
# Build date stamped into Info.plist (BuildDate) and shown next to the version.
# Override with BUILD_DATE for reproducible builds.
BUILD_DATE="${BUILD_DATE:-$(date -u +%Y-%m-%d)}"
APP_NAME="ProxyManager"
BUNDLE_ID="com.proxymanager.app"
HELPER_NAME="com.proxymanager.helper"
MIN_MACOS="14.0"
OUTPUT_DIR="${OUTPUT_DIR:-.}"
# Extra swiftc flags (e.g. SWIFT_FLAGS="-D SCREENSHOT_MODE" for the screenshot
# demo build; see .agents/skills/landing-page-maintenance).
SWIFT_FLAGS="${SWIFT_FLAGS:-}"
APP_BUNDLE="$OUTPUT_DIR/$APP_NAME.app"
MACOS_DIR="$APP_BUNDLE/Contents/MacOS"
RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"
DAEMONS_DIR="$APP_BUNDLE/Contents/Library/LaunchDaemons"
FRAMEWORKS_DIR="$APP_BUNDLE/Contents/Frameworks"

# Sparkle (vendored): linked, embedded, and signed into the bundle. The feed URL
# can be overridden for testing; the public key is read from the committed file
# (the private key never leaves the maintainer's Keychain / CI secret).
SPARKLE_DIR="${SPARKLE_DIR:-Vendor/Sparkle}"
SPARKLE_FRAMEWORK="$SPARKLE_DIR/Sparkle.framework"
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-https://github.com/chaim-chv/proxy-manager/releases/latest/download/appcast.xml}"
if [ -z "${SPARKLE_PUBLIC_KEY:-}" ] && [ -f "$SPARKLE_DIR/public_ed_key.txt" ]; then
    SPARKLE_PUBLIC_KEY="$(tr -d '[:space:]' < "$SPARKLE_DIR/public_ed_key.txt")"
fi

if [ ! -d "$SPARKLE_FRAMEWORK" ]; then
    echo "❌ Sparkle.framework not found at $SPARKLE_FRAMEWORK" >&2
    echo "   Run from the repo root, or set SPARKLE_DIR." >&2
    exit 1
fi
if [ -z "${SPARKLE_PUBLIC_KEY:-}" ]; then
    echo "⚠️  No Sparkle public key (SPARKLE_PUBLIC_KEY / $SPARKLE_DIR/public_ed_key.txt);" >&2
    echo "    updates will be disabled in this build. Run ./Vendor/Sparkle/bin/generate_keys." >&2
fi

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
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$DAEMONS_DIR" "$FRAMEWORKS_DIR"

if [ -n "${SPARKLE_PUBLIC_KEY:-}" ]; then
    SPARKLE_KEY_PLIST="    <key>SUPublicEDKey</key>
    <string>$SPARKLE_PUBLIC_KEY</string>"
else
    SPARKLE_KEY_PLIST=""
fi

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
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>BuildDate</key>
    <string>$BUILD_DATE</string>
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
    <string>Copyright © 2026 chaim-chv · MIT License</string>
    <key>SUFeedURL</key>
    <string>$SPARKLE_FEED_URL</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>SUAutomaticallyUpdate</key>
    <false/>
    <key>SUScheduledCheckInterval</key>
    <integer>86400</integer>
$SPARKLE_KEY_PLIST
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
        $SWIFT_FLAGS \
        -framework AppKit \
        -framework SwiftUI \
        -framework Charts \
        -framework Network \
        -framework ServiceManagement \
        -framework Security \
        ${EXTRA_LINK_FLAGS[@]+"${EXTRA_LINK_FLAGS[@]}"} \
        "$@" \
        -o "$out"
}

# The app links Sparkle and finds it in Contents/Frameworks at runtime. The
# helper daemon is a separate target and must NOT link Sparkle.
APP_LINK_FLAGS=(-F "$SPARKLE_DIR" -framework Sparkle
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks)

if [ "${UNIVERSAL:-0}" = "1" ] && [ "$ARCH" = "arm64" ]; then
    echo "🛠  Building universal (arm64 + x86_64)…"
    EXTRA_LINK_FLAGS=("${APP_LINK_FLAGS[@]}")
    compile arm64 "$MACOS_DIR/$APP_NAME.arm64" "${APP_SOURCES[@]}"
    compile x86_64 "$MACOS_DIR/$APP_NAME.x86_64" "${APP_SOURCES[@]}"
    lipo -create -output "$MACOS_DIR/$APP_NAME" \
        "$MACOS_DIR/$APP_NAME.arm64" "$MACOS_DIR/$APP_NAME.x86_64"
    rm -f "$MACOS_DIR/$APP_NAME.arm64" "$MACOS_DIR/$APP_NAME.x86_64"
else
    EXTRA_LINK_FLAGS=("${APP_LINK_FLAGS[@]}")
    compile "$ARCH" "$MACOS_DIR/$APP_NAME" "${APP_SOURCES[@]}"
fi

# Embed Sparkle. `ditto` (not `cp -R`) preserves the framework's symlinks,
# which are load-bearing for its code signature.
ditto "$SPARKLE_FRAMEWORK" "$FRAMEWORKS_DIR/Sparkle.framework"

# Compile the privileged helper daemon (no Sparkle).
unset EXTRA_LINK_FLAGS
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

# Copy localizations and the app icon if present.
if [ -d "Resources" ] && [ -n "$(ls -A Resources 2>/dev/null)" ]; then
    cp -R Resources/*.lproj "$RESOURCES_DIR/" 2>/dev/null || true
    [ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$RESOURCES_DIR/AppIcon.icns"
    echo "📦 Copied resource files"
fi

# Sign inside-out. `--deep` is deliberately NOT used: Sparkle's XPC services
# and helpers carry their own entitlements, and --deep would smear the wrong
# entitlements across them (and is deprecated). The app bundle is signed last,
# which seals everything nested.
sign_sparkle() {
    local fw="$FRAMEWORKS_DIR/Sparkle.framework"
    local b="$fw/Versions/B"
    [ -d "$fw" ] || return 0
    for xpc in Installer Downloader; do
        [ -d "$b/XPCServices/$xpc.xpc" ] && \
            codesign --force --options runtime --preserve-metadata=entitlements \
                --sign "$IDENTITY" "$b/XPCServices/$xpc.xpc"
    done
    [ -f "$b/Autoupdate" ] && \
        codesign --force --options runtime --sign "$IDENTITY" "$b/Autoupdate"
    [ -d "$b/Updater.app" ] && \
        codesign --force --options runtime --sign "$IDENTITY" "$b/Updater.app"
    codesign --force --options runtime --sign "$IDENTITY" "$fw"
}

sign_sparkle
codesign --force --sign "$IDENTITY" "$DAEMONS_DIR/$HELPER_NAME"
codesign --force --sign "$IDENTITY" "$APP_BUNDLE"

echo "✅ Done! $APP_NAME.app v$VERSION is ready in $OUTPUT_DIR"
