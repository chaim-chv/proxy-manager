# Testing & verification

There is no XCTest target or SPM manifest. Testing is done with **standalone `main.swift` harnesses** compiled against the relevant `Sources/*.swift` files.

## Quick start

```bash
./Tests/run-all.sh          # regression + proxy e2e + watchdog + crash probes; non-zero on failure
```

The driver compiles each harness/probe with `xcrun swiftc -swift-version 5`, runs it, and treats a **signal exit as failure** (`133` = SIGTRAP, a Swift trap; `141` = 128+SIGPIPE). This is how crash classes are caught without killing the driver.

For the full workflow and copy-paste mock helpers, see the project skill
[`skills/standalone-swift-regression-harness`](../skills/standalone-swift-regression-harness/SKILL.md).

## Build a harness

```bash
mkdir -p /tmp/harness && cat > /tmp/harness/main.swift <<'EOF'
// ... top-level test code ...
EOF
xcrun swiftc -swift-version 5 -target arm64-apple-macosx14.0 \
  Sources/Config/ConfigModels.swift Sources/Routing/RoutingEngine.swift \
  Sources/Routing/AppIdentity.swift Sources/Routing/AppResolver.swift \
  Sources/Proxy/Atomic.swift Sources/Proxy/HTTPParser.swift \
  Sources/Proxy/HostClassifier.swift \
  Sources/Socks/Socket.swift Sources/Socks/SOCKS5.swift \
  Sources/Proxy/ProxyServer.swift Sources/Telemetry/TelemetryStore.swift \
  Sources/Support/Log.swift \
  /tmp/harness/main.swift -o /tmp/harness/run
/tmp/harness/run
```

- Top-level code must live in a file named `main.swift` (give each probe its own directory).
- Add the file list that matches what you exercise; the full proxy needs `ProxyServer` + `SOCKS5` + `Socket` + `HTTPParser` + `RoutingEngine` + `Telemetry` + `Config` models + `Support/Log.swift`.
- Use `Thread.detachNewThread` (never `DispatchQueue.global`) for mocks/load — GCD caps concurrent blocking work at ~64 threads.
- Any harness that can crash must call `setbuf(stdout, nil)`, or a signal-killed process loses buffered output.

## Harnesses in the repo

| Harness | Covers |
|---|---|
| `Tests/RegressionHarness/main.swift` | Routing, SSRF host classification, HTTP parser safety, `HTTPParser.rewrite` / WebSocket-upgrade detection, config schema migration, snapshot migration, `networksetup` argument validation, snapshot/PAC validation |
| `Tests/ProxyE2E/main.swift` | Direct + tunneled CONNECT, half-close full body, 200-way concurrency, dead-peer (RST) reaping, dead-peer with a held-open upstream (no busy-spin / no teardown trap), `ws://` upgrade + full-duplex frames direct and through a mock SOCKS5 — live BSD sockets with mock origin + mock SOCKS5 + mock WebSocket origin |
| `Tests/CrashProbes/oversized_port` | `GET http://host:99999/` must not trap |
| `Tests/CrashProbes/sigpipe_send` | Send to an RST peer must not raise SIGPIPE |
| `Tests/CrashProbes/dns_timeout` | A timed-out `getaddrinfo` must not leak the `addrinfo` list (the `delay` seam forces the resolver thread to outlive the caller) |
| `Tests/WatchdogHarness/main.swift` | Crash watchdog decision logic (see below) |
| `Tests/GuiEnvHarness/main.swift` | GUI-session proxy env publish/restore with a fake `launchctl` runner: originals snapshotted and restored, no-op without a snapshot, invalid bind host rejected, idempotent re-apply |
| `Tests/AppIdentityHarness/main.swift` | Per-app identity layer: `enclosingBundle` (plain app, nested helper -> outermost app, code-sign-clone `.app.bundle`, CLI -> none), helper-path classification, the private responsible-process API, and the live `libproc` scan (accepted loopback connection -> client PID -> bundle/executable identity) with cache stability and negative cases |
| `Tests/TelemetryHarness/main.swift` | Per-app telemetry: a fresh DB creates/writes `app`/`app_bundle`, `topApps` groups; a pre-per-app DB is migrated (`ALTER TABLE`) with its legacy row preserved and new rows writing the app |

All of the above pass on the current code. A failing check is a regression — do not loosen the assertion to match the bug.

## What must be covered (regression)

1. **Routing engine** — exact / wildcard / leading-dot / apex / case / trailing-dot / empty-host; wildcard must NOT overmatch `evil-example.com`; `matches` requires a pre-normalized host; IPv6 literals are normalized and match rules.
2. **SSRF classification** — loopback/link-local/RFC1918 + IPv6 ULA (`fc00::`/`fd00::`) are private; ordinary hostnames that merely start with `fc`/`fd` (`fcdn.example.com`, `fdroid.org`) are **not**.
3. **HTTP parser** — duplicate-case headers (no crash), IPv6 `[::1]:443`, malformed/incomplete, oversized port must not trap.
   - **`rewrite` / upgrade** — a `Connection: Upgrade` + `Upgrade: websocket` request keeps both headers (and `Sec-WebSocket-*`), rewrites to origin-form, and never gets `Connection: close`; a normal request still strips `Upgrade` and forces `Connection: close`; `isUpgrade` is token-list and case aware and false without either header.
4. **Config migration** — a legacy `config.json` missing newer keys must decode; unknown keys must not wipe data; a legacy `system-proxy-snapshot.json` missing `bypassDomains` must decode.
5. **Validation** — service names with `/` (`USB 10/100/1000 LAN`), PAC `(null)`, port range.
6. **Proxy end-to-end** — against a mock origin + mock SOCKS5 (detached threads):
   - direct `CONNECT` + response body;
   - tunneled `CONNECT` through mock SOCKS5;
   - **half-close** (client `shutdown(SHUT_WR)` after the request, still receives the full response);
   - **concurrency** — 200 parallel connections all succeed;
   - **dead-peer reaping** — a burst of RST peers must not accumulate relay threads/fds and the proxy must still serve (this is the SIGPIPE integration regression);
   - **dead-peer + held-open upstream** — after a client RST with the upstream still open and idle, the relay must not busy-spin, and the server must not deallocate while a relay permit is outstanding (catches the libdispatch "semaphore deallocated while in use" trap).
   - **`ws://` upgrade** — an absolute-form WebSocket handshake returns `101` (the origin must actually see `Upgrade`/`Connection: Upgrade`), then raw frames echo client→origin→client full-duplex; the same over a mock SOCKS5 with an allow-listed host proves the upgrade is tunneled.
   - **per-app rules** — with an app rule keyed on this process's executable name, an allow-listed host routed `Direct all` must bypass the tunnel and an unlisted host routed `Tunnel all` must use it (two mock origins with distinct bodies prove which route was taken).
7. **Crash classes** — every trap/SIGPIPE/force-unwrap regression gets a subprocess probe; timed-out DNS must not leak `addrinfo` (`CrashProbes/dns_timeout`).
8. **Crash watchdog** — `Tests/WatchdogHarness/main.swift` (see below).
9. **GUI env injection** — `Tests/GuiEnvHarness/main.swift`: a fake `launchctl` runner asserts the exact managed vars (`HTTP_PROXY`/`HTTPS_PROXY`/`ALL_PROXY`/`WSS_PROXY`/`NO_PROXY`/`PROXY_MANAGER_ACTIVE`), that pre-existing user values are snapshotted and restored, that `remove()` is a no-op without a snapshot, that an invalid bind host writes nothing, and that an unchanged value set is not re-published.
10. **Per-app identity** — `Tests/AppIdentityHarness/main.swift`: `enclosingBundle` resolves a plain app, a nested helper to its **outermost** app bundle, a code-sign-clone `.app.bundle`, and returns none for a CLI; helper-path classification; the responsible-process API (self is responsible for self); and the live `libproc` scan finds the PID of a spawned client and resolves its executable/bundle identity, with a stable cache and nil for unmatched ports / dead PIDs.
11. **Per-app telemetry** — `Tests/TelemetryHarness/main.swift`: a fresh DB gets `app`/`app_bundle` and stores them (NULL when absent); `topApps` groups non-empty apps; and a **pre-per-app** `requests` table is migrated in place (`ALTER TABLE`), keeping its legacy row (app NULL) while new writes succeed. `Tests/ProxyE2E` additionally asserts a recorded event carries the resolved app name.

## Crash watchdog harness

```bash
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx14.0 \
  -framework AppKit -framework ServiceManagement \
  Sources/Config/ConfigModels.swift Sources/Config/ConfigStore.swift \
  Sources/Support/Log.swift Sources/Support/Watchdog.swift \
  Sources/System/HelperProtocol.swift Sources/System/HelperXPCClient.swift \
  Sources/System/SystemProxyManager.swift Sources/System/ShellEnvInjector.swift \
  Sources/Socks/Socket.swift \
  Tests/WatchdogHarness/main.swift -o /tmp/watchdog-harness && /tmp/watchdog-harness

# Include the (opt-in) real launchd install/uninstall test; uses a temp
# LaunchAgents dir so the real ~/Library/LaunchAgents is never touched:
WD_TEST_AGENT=1 /tmp/watchdog-harness
```

Covers, with fake hooks (no real proxy mutation): restore only when armed **and** the app is dead **and** a snapshot exists **and** the proxy points at localhost on the configured port; idempotent no-op when the proxy is already clean; retry without ever permanently disarming; `kqueue NOTE_EXIT` fires the restore well before the safety tick; **idle CPU < 0.2 s over 1.2 s** (proves it does not busy-poll); legacy-config decode defaults `crashWatchdog` to true. `PROXYMANAGER_SUPPORT_DIR` / `PROXYMANAGER_LAUNCHAGENTS_DIR` isolate paths for tests.

## Mock helpers

- Mock origin: accept loop (`Thread.detachNewThread`), read once, send a fixed response, close.
- Mock SOCKS5: accept, do the RFC-1928 no-auth handshake, connect to the origin, relay.
- Use `Thread.detachNewThread` (not `DispatchQueue.global`) for mocks, or the mock itself hits GCD's ~64-thread cap and the concurrency test fails spuriously.

## When you change behavior

Extend the relevant harness and re-run. Add the scenario to this file so it stays a living checklist.
