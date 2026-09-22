#!/bin/bash
# ProxyManager standalone test driver (no XCTest / SPM).
#
#   ./Tests/run-all.sh
#
# Compiles each harness/probe against the relevant Sources/*.swift and runs it.
# Crash probes are run in a subprocess: a signal exit (>= 128) is a FAILURE,
# which is how we catch traps (SIGTRAP/133) and SIGPIPE (141) that would
# otherwise kill the real app.
set -u

cd "$(dirname "$0")/.." || exit 1
OUT="$(mktemp -d)"
SWIFTC=(xcrun swiftc -swift-version 5 -target arm64-apple-macosx14.0)
ARCH_TARGET="arm64-apple-macosx14.0"
if [ "$(uname -m)" = "x86_64" ]; then
  SWIFTC=(xcrun swiftc -swift-version 5 -target x86_64-apple-macosx14.0)
fi

pass=0
fail=0
failures=()

run_harness() {
  local name="$1"; shift
  echo ""
  echo "=============================================================="
  echo "HARNESS: $name"
  echo "=============================================================="
  if ! "${SWIFTC[@]}" "$@" -o "$OUT/$name" 2>"$OUT/$name.build.log"; then
    echo "BUILD FAILED ($name):"
    sed 's/^/    /' "$OUT/$name.build.log"
    fail=$((fail+1)); failures+=("$name (build)")
    return
  fi
  "$OUT/$name"
  local rc=$?
  if [ $rc -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); failures+=("$name (exit $rc)"); fi
}

# Crash probe: expects the process to survive (exit 0). A signal (>=128) or any
# non-zero exit is a failure.
run_probe() {
  local name="$1"; shift
  echo ""
  echo "--------------------------------------------------------------"
  echo "CRASH PROBE: $name"
  echo "--------------------------------------------------------------"
  if ! "${SWIFTC[@]}" "$@" -o "$OUT/$name" 2>"$OUT/$name.build.log"; then
    echo "BUILD FAILED ($name):"; sed 's/^/    /' "$OUT/$name.build.log"
    fail=$((fail+1)); failures+=("$name (build)"); return
  fi
  "$OUT/$name"
  local rc=$?
  if [ $rc -eq 0 ]; then
    pass=$((pass+1))
  else
    if [ $rc -ge 128 ]; then
      echo "    *** CRASHED: signal $((rc-128)) (exit $rc) ***"
    fi
    fail=$((fail+1)); failures+=("$name (exit $rc)")
  fi
}

run_harness RegressionHarness \
  Sources/Config/ConfigModels.swift Sources/Routing/RoutingEngine.swift \
  Sources/Routing/AppIdentity.swift \
  Sources/Proxy/Atomic.swift Sources/Proxy/HTTPParser.swift \
  Sources/Proxy/HostClassifier.swift \
  Sources/System/HelperProtocol.swift \
  Tests/RegressionHarness/main.swift

run_harness ProxyE2E \
  Sources/Config/ConfigModels.swift Sources/Routing/RoutingEngine.swift \
  Sources/Routing/AppIdentity.swift Sources/Routing/AppResolver.swift \
  Sources/Proxy/Atomic.swift Sources/Proxy/HTTPParser.swift \
  Sources/Proxy/HostClassifier.swift \
  Sources/Support/Log.swift \
  Sources/Socks/Socket.swift Sources/Socks/SOCKS5.swift \
  Sources/Proxy/ProxyServer.swift Sources/Telemetry/TelemetryStore.swift \
  Tests/ProxyE2E/main.swift

run_probe CrashProbe_oversized_port \
  Sources/Proxy/HTTPParser.swift \
  Tests/CrashProbes/oversized_port/main.swift

run_probe CrashProbe_sigpipe_send \
  Sources/Socks/Socket.swift \
  Tests/CrashProbes/sigpipe_send/main.swift

run_probe CrashProbe_dns_timeout \
  Sources/Socks/Socket.swift \
  Tests/CrashProbes/dns_timeout/main.swift

run_harness AppIdentityHarness \
  Sources/Routing/AppIdentity.swift \
  Sources/Routing/AppResolver.swift \
  Sources/Support/Log.swift \
  Tests/AppIdentityHarness/main.swift

run_harness TelemetryHarness \
  Sources/Config/ConfigModels.swift \
  Sources/Telemetry/TelemetryStore.swift \
  Tests/TelemetryHarness/main.swift

run_harness GuiEnvHarness \
  Sources/Config/ConfigModels.swift Sources/Config/ConfigStore.swift \
  Sources/System/HelperProtocol.swift \
  Sources/Support/Log.swift \
  Sources/System/ShellEnvInjector.swift Sources/System/GuiEnvInjector.swift \
  Tests/GuiEnvHarness/main.swift

run_harness WatchdogHarness \
  -framework AppKit -framework ServiceManagement \
  Sources/Config/ConfigModels.swift Sources/Config/ConfigStore.swift \
  Sources/Support/Log.swift Sources/Support/Watchdog.swift \
  Sources/System/HelperProtocol.swift Sources/System/HelperXPCClient.swift \
  Sources/System/SystemProxyManager.swift Sources/System/ShellEnvInjector.swift \
  Sources/System/GuiEnvInjector.swift \
  Sources/Socks/Socket.swift \
  Tests/WatchdogHarness/main.swift

echo ""
echo "=============================================================="
echo "SUMMARY: $pass passed, $fail failed"
if [ ${#failures[@]} -gt 0 ]; then
  for f in "${failures[@]}"; do echo "  - $f"; done
fi
echo "=============================================================="
rm -rf "$OUT"
[ $fail -eq 0 ]
