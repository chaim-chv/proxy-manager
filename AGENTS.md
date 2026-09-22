# AGENTS.md — ProxyManager

Guidance for AI agents (and humans) working on this repository. **Read this file first, then the relevant doc in [`docs/`](docs/README.md), then the code.**

## What this project is

ProxyManager is a native macOS menu-bar app (Swift, built with `swiftc` — **no Xcode project**) that runs a local HTTP CONNECT/forward proxy on `127.0.0.1:8888`. It routes an allow-list of hostnames (user-defined, empty by default) through an existing SOCKS5 proxy (default `127.0.0.1:1080`, configurable) and passes everything else **directly**. It also sets the macOS system proxy (so browsers/system apps route through it), injects `HTTP_PROXY`/`HTTPS_PROXY` into shell rc files (so CLI tools route through it), and records per-request telemetry to SQLite.

The app is **generic** — no service is assumed. Users configure their tunnel and target list via the **first-run onboarding** wizard (or Settings). A small **preset library** (`Sources/Config/Presets.swift`) seeds common allow-lists (DeepSeek, OpenAI, Anthropic, Gemini, GitHub, NVIDIA, WhatsApp), but the shipped default is an empty list.

The tunnel can be provided **two ways** (`TunnelSettings.mode`): **MANUAL** (the user runs their own SOCKS5 proxy; the app just points at it) or **MANAGED** (the app runs `ssh -N -D` itself via `Sources/Tunnel/SSHTunnelRunner.swift`, storing the optional password in the Keychain via `SSHKeychain.swift`).

The proxy is a **policy router, not a MITM** — TLS passes through untouched. The app self-updates via the vendored **Sparkle 2** framework (`Vendor/Sparkle/`, see `docs/updates.md`).

## Hard requirements (non-negotiable)

1. **Performant** — enabling the tunnel must be imperceptible. Streaming must not buffer whole bodies; telemetry must stay off the hot path. (See `docs/performance.md`.)
2. **Reliable, no crashes/bugs** — the proxy must handle malformed input, aborts, and half-closes without crashing or hanging. (See `docs/proxy-core.md`, `docs/http-parser.md`.)
3. **Never break the user's internet** — a crash must never leave the system proxy pointed at a dead `127.0.0.1:8888`. (See "Critical lessons" below and `docs/app-model-lifecycle.md`.)
4. **Debuggable & logged** — log lifecycle/errors via the unified log (`Log` in `Sources/Support/Log.swift`). See `docs/debugging-logging.md`.

## Repo layout

```
ProxyManager/
├── AGENTS.md                  ← this file
├── PLAN.md                    ← high-level spec + decisions (source of truth)
├── revert.sh                  ← EMERGENCY: undo all app effects (restore internet)
├── build.sh                   ← build script (version param, links/embeds/signs Sparkle, embeds helper)
├── Sources/                   ← all Swift (no Xcode project)
│   ├── App.swift              ← @main, Settings scene, AppDelegate
│   ├── AppModel.swift         ← state machine, enable/disable lifecycle, crash recovery
│   ├── Support/Log.swift      ← unified-log logger
│   ├── Support/Watchdog.swift ← crash watchdog (`--watchdog` LaunchAgent)
│   ├── Config/                ← config models + JSON store (persistence, snapshot)
│   ├── Routing/               ← allow-list matching engine
│   ├── Socks/                 ← raw BSD sockets + RFC 1928 SOCKS5 client
│   ├── Proxy/                 ← HTTP CONNECT/forward proxy core + relay + parser
│   ├── System/                ← system proxy mgr, XPC client, shell + GUI env injectors, helper protocol
│   ├── Helper/                ← privileged helper daemon (separate binary)
│   ├── Telemetry/             ← batched SQLite telemetry + live feed
│   ├── Tunnel/                ← SOCKS5 health probe + supervisor + SSH tunnel runner + keychain
│   └── UI/                    ← dashboard, settings, targets, onboarding, updater, help popovers, status menu
├── Resources/                 ← app icon + localizations (copied into the bundle)
├── Tools/                     ← dev tools (app-icon generator, no runtime code)
├── Vendor/Sparkle/            ← vendored Sparkle 2 auto-update framework
├── Tests/                     ← standalone regression harnesses + crash probes
├── skills/                    ← project skills (e.g. standalone-swift-regression-harness)
├── docs/                      ← area-specific deep dives (READ FIRST)
└── .github/                   ← release workflow + changelog script
```

## Commands

```bash
# Build (version as parameter) → produces ProxyManager.app
./build.sh 1.0.0
# Universal build
UNIVERSAL=1 ./build.sh 1.0.0
# Sign with a Developer ID (enables the privileged helper daemon)
IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build.sh 1.0.0

# EMERGENCY revert — run if the app crashed and the internet died
./revert.sh

# Run the standalone regression harnesses + crash probes (non-zero on failure)
./Tests/run-all.sh

# Watch the unified log
log stream --predicate 'subsystem == "com.proxymanager.app"' --level debug
```

There is no `xcodebuild` target or SPM manifest. The build links the vendored Sparkle framework from `Vendor/Sparkle` (override with `SPARKLE_DIR`). To compile a subset for a test harness, pass the needed `Sources/*.swift` files to `xcrun swiftc -swift-version 5 -target arm64-apple-macosx14.0 ...` (see `docs/testing.md`).

## ⚠️ Critical lessons learned (do NOT repeat these mistakes)

These are hard-won from this codebase's history. **Violating any of them causes the exact bugs that are now fixed (and tested).**

1. **Upstream connections MUST use raw BSD sockets — never `Network.framework` (`NWConnection`/`NWListener`).**
   `NWConnection` honors the macOS *system proxy*; raw `connect()` does not. Since this app sets the system proxy to `127.0.0.1:8888`, an `NWConnection` outbound "direct" connection loops back into the proxy → `Connection refused` → dead internet. The proxy core must use `Sources/Socks/Socket.swift`.

2. **Never leave the system proxy dangling.**
   Setting the system proxy to `127.0.0.1:8888` and then dying (crash / SIGKILL / a bug) makes the *entire machine* lose internet. Required mitigations (all present):
   - Persist the user's original proxy **snapshot to disk** (`system-proxy-snapshot.json`) *before* applying, so restore is always correct even after a crash.
   - Roll back on partial `enable()` failure.
   - Restore on disable and on quit (`restoreOnQuit`).
   - Auto-re-enable on relaunch (`wasOnKey`), and provide `./revert.sh`.
   - **Crash watchdog** (`Sources/Support/Watchdog.swift`): the app binary's `--watchdog` mode runs as a `KeepAlive` user LaunchAgent that restores the proxy within ms of the app dying (event-driven via `kqueue NOTE_EXIT`, ~0 idle CPU). Armed before `applyProxy`, disarmed after restore; it acts only when a snapshot exists *and* the proxy points at `127.0.0.1`, so it never clobbers a user-set proxy. `revert.sh` boots it out first.

3. **The proxy must not use `DispatchQueue.global()` for per-connection blocking work.**
   GCD's global queue caps ~64 concurrent *blocking* threads. A thread-per-connection proxy hits that ceiling and starves. Use **detached threads** (`Thread.detachNewThread`) bounded by a `DispatchSemaphore`, or a real event loop.

4. **Telemetry must be O(1) on the hot path.**
   Per-request SQLite inserts and per-request `DispatchQueue.main.async` calls back up unboundedly and thrash the process. `TelemetryStore.record(_:)` / session begin-end are lock + append; the only per-iteration call is `updateSession` (two locked adds when bytes moved); a single 10 Hz flusher batches SQLite inserts (prepared statements + transaction) and publishes the UI. Live feed rows come from `beginSession` at connection establish + 10 Hz snapshots — never per-chunk `main.async`.

5. **The relay must handle half-close, backpressure, and poll errors correctly.**
   Defer FIN propagation until buffers drain (else responses get truncated); handle `POLLERR`/`POLLNVAL` (else 100% CPU busy-spin); bound buffers (`256 KB`) and use a short grace timeout after half-close.

6. **`HTTPParser` must never crash on malformed input.**
   `Dictionary(uniqueKeysWithValues:)` traps on duplicate-case headers; `lastIndex(of: ":")` breaks IPv6 literals. (Both fixed; keep it that way — add a regression test.)

7. **SwiftUI `ForEach` needs unique `Identifiable` ids.** `RequestEvent` uses a `UUID`; never default every event to the same id.

8. **The privileged helper must authorize its clients.** The XPC listener checks the caller's code-signing Team ID before exporting root `networksetup`; the XPC client must have a timeout so a missing daemon can't deadlock.

9. **Always test with a real target + concurrency.** `example.com:443` (real DNS + real remote) and a 200-way concurrent load test caught bugs the unit-level paths missed.

10. **Don't regress `revert.sh`.** It's the user's lifeline when a bug ships.

11. **Suppress SIGPIPE on every socket.** macOS has no `MSG_NOSIGNAL`; a `send()` to a reset peer raises `SIGPIPE` and kills the process. Call `Socket.setNoSIGPIPE(fd)` on every fd you create or accept (the listener, accepted clients, `Socket.connect` results). Per-socket `SO_NOSIGPIPE` is the primary defense; the app and helper also call `signal(SIGPIPE, SIG_IGN)` at startup (`Sources/App.swift`, `Sources/Helper/main.swift`) as belt-and-suspenders. `Tests/ProxyE2E` (RST burst) and `Tests/CrashProbes/sigpipe_send` are the regressions.

12. **Only clear the snapshot / disarm the watchdog after a restore that actually succeeded.** A `try? restore(...)` followed by `clearSnapshot()` + `disarm()` is how a transient `networksetup` failure becomes permanent dead internet. On failure, keep the snapshot on disk, keep the watchdog armed, and keep the listener running; log and surface the error. Never treat an empty restore command list as success (`HelperService.restoreProxy`).

13. **Every config/snapshot struct must decode tolerantly.** Synthesized `Codable` throws `keyNotFound` for a missing key even when the property has a default, so adding a field wipes the user's whole config (or their crash-recovery snapshot). Use a custom `init(from:)` with `decodeIfPresent(...) ?? default`. `Tests/RegressionHarness` asserts legacy and future configs decode.

14. **`networksetup -getautoproxyurl` prints `URL: (null)`** when no PAC is set. Treat `(null)`/`(nil)`/`null` as "no PAC" — storing it literally makes `ServiceProxyState.isValid` fail and drops the whole service from restore. Real service names also contain `/` (e.g. `USB 10/100/1000 LAN`); do not reject them.

15. **The proxy has no authentication.** A non-loopback bind must stay a deliberate choice, and non-loopback clients are blocked from loopback/link-local/RFC1918 destinations (SSRF guard in `ProxyServer`). Do not remove that guard without replacing it.


## Conventions

- **Swift 5 language mode** (`-swift-version 5`), target `arm64-apple-macosx14.0` (and `x86_64` for universal). Do NOT switch to Swift 6 strict concurrency — the proxy core deliberately uses raw sockets + detached threads.
- **No comments unless they explain *why*** (non-obvious invariants). The codebase uses brief doc comments on types/functions.
- **Errors are logged, not swallowed silently** — use `Log.*` (unified log) for lifecycle + errors.
- **Prefer system frameworks** (`Network`, `Security`, `ServiceManagement`, `Charts`, `SQLite3`). The only third-party dependency is the vendored **Sparkle 2** auto-updater (`Vendor/Sparkle/`, see `docs/updates.md`); no SPM/package-manager deps.
- **Synchronous admin work goes on a background queue**, never the main thread, and must have a bounded timeout (`runAdmin`, XPC `sync`).
- **When you change behavior, add/extend the regression harness** in `docs/testing.md` and re-run it.
- **Settings use a sidebar** (`SettingsView.swift`) with a `SettingsSection` enum; order is General / Appearance / Tunnel / Proxy / Targets / Apps / System / Monitoring / About. New options get a **`HelpPopover`** (inline `?` → popover) so they're self-documenting, never bare labels.
- **Onboarding** (`Sources/UI/OnboardingView.swift`) is the first-run walk-through; it's re-openable via Settings → General. It writes config through the same `AppModel` paths as Settings. Presets live in `Sources/Config/Presets.swift` (`TargetPreset`).
- **Managed SSH tunnel** (`Sources/Tunnel/SSHTunnelRunner.swift`): run `ssh -N -D` as a **foreground** `Process` (never `-f`), drain stderr via `readabilityHandler`, restart with exponential backoff, and classify auth/host-key/key-file errors as fatal. The password is read from the Keychain (`SSHKeychain`) and fed via `SSH_ASKPASS` + `SSH_ASKPASS_REQUIRE=force` — **never argv or env**.

## docs/ index (read the relevant one before touching that area)

| Area | Doc |
|---|---|
| Overview & data flow | `docs/architecture.md` |
| Proxy core, relay, concurrency | `docs/proxy-core.md` |
| Sockets + SOCKS5 | `docs/networking.md` |
| HTTP request parsing | `docs/http-parser.md` |
| Allow-list routing | `docs/routing.md` |
| Per-app routing (identity, rules, telemetry, UI) | `docs/per-app-rules.md` |
| Telemetry / SQLite | `docs/telemetry.md` |
| System proxy + shell env | `docs/system-integration.md` |
| Privileged helper + XPC | `docs/privileged-helper.md` |
| App state machine / lifecycle / crash recovery | `docs/app-model-lifecycle.md` |
| Config persistence | `docs/config.md` |
| Tunnel health supervisor | `docs/tunnel-supervisor.md` |
| SwiftUI / UI | `docs/ui.md` |
| Build, signing, distribution | `docs/build-and-distribution.md` |
| Auto-updates (Sparkle) | `docs/updates.md` |
| Testing / verification | `docs/testing.md` |
| Logging & debugging | `docs/debugging-logging.md` |
| Performance & resource footprint | `docs/performance.md` |
| What's left (roadmap) | `docs/roadmap.md` |

## Definition of done for a change

- [ ] Builds with `./build.sh` (and helper compiles).
- [ ] Relevant regression harness passes (see `docs/testing.md`).
- [ ] No new `critical`/`high` bugs introduced (re-check `docs/*` invariants).
- [ ] Logs added for lifecycle/errors; no silent swallows.
- [ ] `PLAN.md` and `docs/` updated if behavior/architecture changed.
- [ ] `revert.sh` still reverts everything (if touching system-proxy logic).
