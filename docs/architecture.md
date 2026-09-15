# Architecture

## Purpose

ProxyManager reroutes **only allow-listed hostnames** (user-defined, empty by default) through an existing SOCKS5 proxy, leaving everything else direct. It is a **policy router, not a MITM** — TLS is passed through byte-for-byte; the app never sees plaintext.

## Data flow

```
Browser / system app ──▶ system proxy (127.0.0.1:8888) ─┐
CLI tool (HTTP_PROXY env) ──────────────────────────────┤
                                                        ▼
                                              HTTP CONNECT/forward proxy
                                              (ProxyServer, in-process)
                                                        │  RoutingEngine.decide(host)
                                          allow-listed?  │
                                ┌─────────────────────────┴───────────────┐
                                 ▼ YES                                       ▼ NO (or tunnel down, fail-open)
                           SOCKS5 client (127.0.0.1:1080)               raw TCP connect (direct)
                                │                                          │
                                ▼                                          ▼
                        SOCKS5 tunnel → target                          Internet
```

## Component inventory

| Component | File(s) | Role |
|---|---|---|
| App shell | `Sources/App.swift`, `Sources/UI/StatusMenuController.swift` | `@main` SwiftUI app (`Settings` scene + `AppCommands`), `AppDelegate` (termination/reopen), native `NSStatusItem`+`NSMenu` menu bar |
| UI | `Sources/UI/` | Dashboard, Settings, Targets, Onboarding, HelpPopover (observe `AppModel`; only the Dashboard observes `TelemetryStore`) |
| State machine | `Sources/AppModel.swift` | `ObservableObject`; `off/starting/on/degraded/stopping`; enable/disable lifecycle |
| Crash watchdog | `Sources/Support/Watchdog.swift` | `--watchdog` user LaunchAgent; restores the system proxy within ms of a crash (`kqueue NOTE_EXIT`) |
| Proxy core | `Sources/Proxy/ProxyServer.swift` | Listener + connection handler + poll relay (runs in-process, detached threads) |
| Routing | `Sources/Routing/RoutingEngine.swift` | Allow-list → `TUNNEL`/`DIRECT` |
| SOCKS5 client | `Sources/Socks/SOCKS5.swift` | RFC 1928 handshake, ATYP=domain (DNS on tunnel side) |
| Sockets | `Sources/Socks/Socket.swift` | Raw BSD `getaddrinfo`/`connect`/`recv`/`send` (bypass system proxy) |
| HTTP parser | `Sources/Proxy/HTTPParser.swift` | CONNECT + absolute-form parsing, origin-form rewrite |
| Telemetry | `Sources/Telemetry/TelemetryStore.swift` | Batched SQLite + in-memory live feed + stats |
| System integration | `Sources/System/SystemProxyManager.swift`, `ShellEnvInjector.swift` | `networksetup` (helper → direct-as-user → osascript), shell env injection, snapshot |
| Privileged helper | `Sources/Helper/`, `Sources/System/HelperXPCClient.swift`, `HelperProtocol.swift` | Root daemon over NSXPC |
| Tunnel supervisor | `Sources/Tunnel/TunnelSupervisor.swift` | 10 s SOCKS5 health probe |
| SSH tunnel runner | `Sources/Tunnel/SSHTunnelRunner.swift`, `SSHKeychain.swift` | "Run the tunnel for me" — spawns/supervises `ssh -N -D`, Keychain password |
| Config | `Sources/Config/` | JSON config + system-proxy snapshot + presets |
| Logging | `Sources/Support/Log.swift` | Unified log (`os.Logger`) categories |
| Updater | `Sources/UI/UpdaterController.swift`, `Vendor/Sparkle/` | Sparkle 2 auto-updates (GitHub-releases appcast, EdDSA), `--watchdog` never loads it |

## Threading model

- The **proxy core** is thread-per-connection: `Thread.detachNewThread` bounded by a `DispatchSemaphore` (default 256). Not GCD's global queue (which caps blocking tasks at ~64 threads).
- **Telemetry** is off the hot path: `record()` is lock+append; a single 10 Hz flusher does SQLite + UI.
- **Admin work** (system proxy, XPC) runs on a background `workQueue` with bounded timeouts, never main.

## Key invariants

1. Upstream (outbound) connections use **raw BSD sockets only** — `Network.framework` honors the system proxy and would loop back into the proxy.
2. The system proxy is set to `127.0.0.1:8888` **only while the app is running and routing is on**; the original state is snapshotted to disk first.
3. The proxy never buffers whole bodies — it relays in 16 KB chunks with backpressure.
