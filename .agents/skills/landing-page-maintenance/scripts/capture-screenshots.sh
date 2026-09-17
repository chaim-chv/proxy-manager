#!/bin/bash
# Capture landing-page screenshots from the demo build.
#
#   ./capture-screenshots.sh [output-dir]
#
# Requires: a demo build (run ./build-demo.sh first, or set APP=/path/to/ProxyManager.app),
# Screen Recording permission for your terminal, and a display (captures are 2x on Retina).
#
# Writes <screen>-<appearance>.png for every screen in SCREENS below, in both
# dark and light appearances. It never touches the system proxy, the shell env,
# the Keychain, or the real watchdog: the demo runs against a sandboxed support
# directory, and the process is killed with SIGKILL (no terminate handler runs).
set -euo pipefail
set +m  # no "Killed: 9" job-control chatter when we SIGKILL the demo between shots

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
OUT="${1:-$ROOT/.screenshots}"
APP="${APP:-/tmp/pm-demo/ProxyManager.app}"
BIN="$APP/Contents/MacOS/ProxyManager"
SANDBOX="${SANDBOX:-/tmp/proxymanager-demo}"

if [ ! -x "$BIN" ]; then
  echo "Demo app not found at $BIN — run ./build-demo.sh first." >&2
  exit 1
fi

# screen-key:PROXYMANAGER_SCREEN
SCREENS=(
  "dashboard:dashboard"
  "dashboard-detail:dashboard-detail"
  "tunnel:settings-tunnel"
  "tunnel-managed:settings-tunnel-managed"
  "targets:settings-targets"
  "onboarding:onboarding"
)
APPEARANCES=("dark" "light")

HELPER="$(mktemp -d)/window-id"
xcrun swiftc -O "$HERE/window-id.swift" -o "$HELPER"

mkdir -p "$OUT"

cleanup() { pkill -9 -f "$BIN" 2>/dev/null || true; }
trap cleanup EXIT

for appearance in "${APPEARANCES[@]}"; do
  for entry in "${SCREENS[@]}"; do
    name="${entry%%:*}"
    screen="${entry##*:}"
    file="$OUT/$name-$appearance.png"

    cleanup
    sleep 0.4

    PROXYMANAGER_DEMO=1 \
    PROXYMANAGER_SCREEN="$screen" \
    PROXYMANAGER_APPEARANCE="$appearance" \
    PROXYMANAGER_SUPPORT_DIR="$SANDBOX/support" \
    PROXYMANAGER_LAUNCHAGENTS_DIR="$SANDBOX/LaunchAgents" \
      "$BIN" >/dev/null 2>&1 &
    pid=$!

    if ! wid="$("$HELPER" "$pid" 400 20)"; then
      echo "SKIP $name ($appearance): no window" >&2
      kill -9 "$pid" 2>/dev/null || true
      continue
    fi
    sleep 0.8
    screencapture -x -o -l "$wid" "$file"
    echo "captured $file"
    kill -9 "$pid" 2>/dev/null || true
  done
done

echo "Done. Screenshots in $OUT"
