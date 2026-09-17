#!/bin/bash
# Build a screenshot-enabled ProxyManager.app.
#
# Compiles the app with -D SCREENSHOT_MODE, which enables Sources/Support/DemoMode.swift.
# The shipping build (plain ./build.sh) never defines this flag, so the demo code is
# compiled out of released binaries.
#
#   ./build-demo.sh [output-dir]
#
# Defaults to /tmp/pm-demo. VERSION=<x.y.z> overrides the version string.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
OUT="${1:-/tmp/pm-demo}"

cd "$ROOT"
rm -rf "$OUT"
mkdir -p "$OUT"

SWIFT_FLAGS="-D SCREENSHOT_MODE" OUTPUT_DIR="$OUT" ./build.sh "${VERSION:-1.0.0}"

echo "Demo app ready: $OUT/ProxyManager.app"
