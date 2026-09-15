---
name: standalone-swift-regression-harness
description: Build and run regression tests for the ProxyManager macOS app, which has no Xcode project or SPM manifest — only `swiftc` and standalone `main.swift` harnesses. Use this whenever you change anything under Sources/ (proxy core, sockets, SOCKS5, routing, config, telemetry, system proxy, tunnel) and need to verify it, whenever you add a new Swift file that should be tested, whenever you need to reproduce a crash/trap/SIGPIPE, or whenever the user says "test this", "run the harness", "regression test", or "verify the fix". Also use it before declaring any ProxyManager change done, since the repo's definition of done requires the relevant harness to pass.
---

# Standalone Swift regression harnesses (ProxyManager)

ProxyManager deliberately has **no Xcode project and no SPM manifest**. `build.sh`
compiles with `xcrun swiftc`; tests are standalone `main.swift` programs compiled
against the specific `Sources/*.swift` files they exercise. This skill is the
reliable way to build, run, and extend those harnesses without fighting the
toolchain.

## When to use

- You changed `Sources/**` and need to prove behavior.
- You need to reproduce a crash: trap (`Fatal error`), force-unwrap, SIGPIPE, or
  a hang.
- You are adding a new source file and want to know it is testable.
- You need a quick end-to-end check of the proxy relay without touching the real
  system proxy or network.

## The golden rules (learned the hard way)

1. **Top-level code must be in a file literally named `main.swift`.** If a probe
   is not `main.swift`, `swiftc` errors with "expressions are not allowed at the
   top level". Give each probe its own directory with a `main.swift`.
2. **Pass the exact file list you exercise.** There is no auto-discovery in the
   harness. Use `Tests/run-all.sh` as the source of truth for which files each
   harness needs. A missing file shows up as `cannot find 'X' in scope`.
3. **Use `Thread.detachNewThread`, never `DispatchQueue.global`, for mock servers
   and load.** GCD's global pool caps concurrent *blocking* work at ~64 threads;
   a 200-connection test will fail spuriously. The production proxy already does
   this (`ProxyServer.acceptLoop`).
4. **Disable stdout buffering** (`setbuf(stdout, nil)`) in any harness that can
   crash. A signal-killed process loses block-buffered output, so you would not
   see which scenario died.
5. **Run crash probes in a subprocess and treat signal exits as failures.**
   `exit 133` = SIGTRAP (a Swift trap), `exit 141` = 128+SIGPIPE. Bash reports
   these directly. Do not run a known-crashing probe in the same process as your
   other assertions.
6. **The proxy needs `Sources/Support/Log.swift`** (it calls `Log.proxy`), and the
   e2e needs the full set: `ConfigModels`, `RoutingEngine`, `Atomic`,
   `HTTPParser`, `Log`, `Socket`, `SOCKS5`, `ProxyServer`, `TelemetryStore`.

## Quick start

```bash
# Run everything (pure harness + e2e + crash probes). Exits non-zero on failure.
./Tests/run-all.sh
```

Individual harnesses:

```bash
# Pure logic: routing, parser, config migration, validation. Fast, no network.
xcrun swiftc -swift-version 5 -target arm64-apple-macosx14.0 \
  Sources/Config/ConfigModels.swift Sources/Routing/RoutingEngine.swift \
  Sources/Proxy/Atomic.swift Sources/Proxy/HTTPParser.swift \
  Sources/System/HelperProtocol.swift \
  Tests/RegressionHarness/main.swift -o /tmp/regression && /tmp/regression
```

To compile against the host architecture portably, compute the target:
`TARGET="$(uname -m)-apple-macosx14.0"`.

## Writing a new harness

1. Create `Tests/<Name>/main.swift`.
2. Copy the `check(name, condition)` helper pattern from
   `Tests/RegressionHarness/main.swift`; it prints `ok`/`FAIL` and exits non-zero
   on any failure.
3. Add a `run_harness` (or `run_probe`) block to `Tests/run-all.sh` listing the
   `Sources/*.swift` files the harness needs.
4. For network behavior, reuse the mock patterns in `Tests/ProxyE2E/main.swift`:
   `MockOrigin` (reads to EOF, then replies — this is how you test half-close)
   and `MockSOCKS5` (RFC-1928 no-auth handshake + a half-close-correct `bridge`).
5. Add the scenario to `docs/testing.md` so it stays a living checklist.

See `references/harness-patterns.md` for the exact helper snippets (free-port
binding, mock origin, mock SOCKS5, RST peers, subprocess crash-probe driver).

## What to test when you touch an area

| Area | Minimum harness coverage |
|---|---|
| Routing | exact/wildcard/apex/case/trailing-dot; wildcard must NOT overmatch `evil-example.com`; IPv6 literals are normalized and match rules |
| HTTP parser | duplicate-case headers (no crash), IPv6 `[::1]:443`, malformed/incomplete, oversized port must not trap |
| Sockets / SOCKS5 | partial reads/writes, RST peer must not raise SIGPIPE, fd cleanup |
| Proxy relay | direct + tunneled CONNECT, half-close full body, 200-way concurrency, RST-burst reaping |
| Config | legacy JSON missing new keys must decode; unknown keys must not wipe data |
| Validation | service names with `/`, PAC `(null)`, port range |
| System proxy | use the watchdog harness (`Tests/WatchdogHarness`) and isolated dirs — see the `system-proxy-safety-testing` skill |

## Anti-patterns

- Don't add XCTest or a `Package.swift` — the repo intentionally avoids them.
- Don't assert on `Log` output; assert on observable state (return values, bytes,
  exit codes, files).
- Don't test system-proxy mutations directly in a plain harness. Use the
  `system-proxy-safety-testing` skill; a wrong test can leave the machine with no
  internet.
- Don't "fix" a failing assertion by loosening it. Each failing line in
  `Tests/RegressionHarness` maps to a real bug or a documented invariant.
