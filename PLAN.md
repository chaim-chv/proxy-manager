# Proxy Manager — macOS Menu Bar App
## Master Plan / Project Specification

> **Document purpose:** This file is the single source of truth and the plan document for the *Proxy Manager* macOS application. Use it as the input/spec for every build prompt. Keep it updated as decisions are made. Every section marked **DECISION** is a confirmed requirement; every section marked **OPEN** still needs confirmation.

> **Implementation reference:** `AGENTS.md` (agent instructions + critical lessons learned) and `docs/` (area-specific deep dives) are the detailed, current reference for the implemented code — read the relevant `docs/` file before touching that area.

---

## 1. Executive Summary

Proxy Manager is a native macOS menu bar application (SwiftUI) that reroutes **only the traffic to a user-defined list of target domains** (default: **empty** — the app is generic; presets seed common allow-lists) through an existing SOCKS5 proxy, while leaving all other traffic untouched (direct). It provides:

- A **single on/off switch** (menu bar toggle) that enables/disables routing system-wide.
- A **local domain-aware proxy** (`127.0.0.1:8888`) that tunnels allow-listed hosts through the SOCKS5 proxy and passes everything else through directly.
- **System integration**: sets the macOS system proxy (via a privileged helper) and exports shell/CLI environment variables, so browsers, `curl`, `node`/`bun`, and system apps all honor the routing — nothing else on the machine is rerouted.
- **Full monitoring**: a live, clear UI listing every request with route decision (tunneled vs direct), host, method, bytes, latency, status; time-series graphs; per-host breakdowns; on-device history (SQLite).
- **Configurable target list** (add/edit/remove domains, wildcard subdomains) with presets.
- **Settings**: proxy port, tunnel address/port, fail-open/fail-closed policy, launch at login, optional app-lock (passcode), monitoring retention, privacy options.
- **Stability**: runs as a supervised menu bar app, recovers from tunnel loss, has a clear state machine, and never MITMs TLS.

The tunnel is an existing SOCKS5 proxy (e.g. `ssh -D`). The app detects, uses, and can optionally supervise it (via a configurable launchd job label). The app itself is **generic** — any SOCKS5 proxy and any allow-list works.

---

## 2. Background & Problem

### 2.1 Why the current setup is incomplete

- **PAC files are only honored by apps using the OS/browser network stack** (Chrome, Safari, Electron apps like Slack/Obsidian).
- **CLI tools do not read PAC.** OpenCode's proxy logic (`packages/opencode/src/util/proxy-env.ts`) reads only `HTTP_PROXY`/`HTTPS_PROXY`/`ALL_PROXY` env vars — which are unset, so DeepSeek traffic from OpenCode/`curl`/`node`/`bun` goes **direct**.
- **CLI HTTP clients cannot speak SOCKS5**: `bun fetch` fails with `UnsupportedProxyProtocol`; Node/undici silently ignores `socks5://` proxy URLs. They *can* speak HTTP CONNECT proxies.
- Therefore the correct bridge is a **local HTTP CONNECT proxy that itself uses the SOCKS5 tunnel**, wired into (a) the macOS system proxy for apps and (b) shell env vars for CLI tools — **domain-scoped** so only allow-listed hosts go through the tunnel.

### 2.2 Design decision (confirmed)

**DECISION:** Implement the **smart local proxy + system switch** model:
- Local proxy on `127.0.0.1:8888` (configurable).
- Allow-listed hosts → tunneled via the configured SOCKS5 proxy.
- All other hosts → passed through directly (the proxy is a transparent *policy router*, not a MITM).
- Switch ON/OFF controls: local proxy process, macOS system proxy (HTTP+HTTPS, all active interfaces), shell env vars, and launch-at-login state.
- Allow-list only; nothing else is rerouted.

---

## 3. Goals & Non-Goals

### 3.1 Goals
1. Route all traffic to configurable target domains through the existing SOCKS5 proxy, from **every app** on the machine (browser, CLI, system apps).
2. One obvious, reliable on/off switch in the menu bar.
3. Editable list of proxied targets with wildcard support and presets.
4. Beautiful, clear live monitoring: per-request feed + graphs + per-host stats.
5. Launch at login; stable long-running menu bar app.
6. Full settings surface; everything configurable and self-documenting in the UI.
7. No TLS interception; no certificate installation; privacy-preserving (data stays on device).

### 3.2 Non-goals (v1)
- Not a transparent packet-level (pf/DNS) interceptor. (Documented as possible v2 option.)
- Not a general VPN or full-tunnel proxy (all-traffic mode) — v1 is allow-list only. (Setting for "route everything" is out of scope initially; see Open Questions.)
- No remote server-side component; the app only manages the *client* side.
- No multi-user/sandbox support; single-user desktop app.
- No automatic fallback that hides route failures from the user (degraded state is always surfaced).

---

## 4. Product Requirements (Features & User Stories)

### 4.1 Menu bar
- **PR-1** Persistent `NSStatusItem` with a status icon and text (e.g., `● Proxy Manager: ON (tunnel)` / `OFF` / `DEGRADED`).
- **PR-2** One-click toggle to enable/disable routing (with the helper/sudo prompt only when needed).
- **PR-3** Drop-down menu shows: status, quick stats (requests tunneled today, bytes, current RPS), recent requests, toggle, "Open Dashboard", "Settings", "Quit".
- **PR-4** Toggle reflects instantly; state machine prevents conflicting actions.

### 4.2 Dashboard (main window)
- **PR-5** Live request feed (table): time, host, method/path, route (TUNNEL/DIRECT), status, bytes in/out, latency, duration, error.
- **PR-6** Filter bar: by host, route (tunneled/direct), success/error, text search; pause/resume live scroll.
- **PR-7** Graphs: requests/sec, bytes/sec (in/out), concurrent connections, per-host top-N bar chart, success/error ratio. Time ranges (last 5m/1h/24h/7d).
- **PR-8** Request detail panel on selection (full headers optional, body never captured).
- **PR-9** Connection table: current live tunneled connections (src, dst host, established, idle).
- **PR-10** Clear/purge history button (with confirm).

### 4.3 Targets editor (allowlist)
- **PR-11** CRUD list of target rules: add, edit, delete, enable/disable individually, reorder.
- **PR-12** Wildcard subdomain support (`*.example.com`), exact-match, and full-host rules.
- **PR-13** Presets: DeepSeek, OpenAI, Anthropic/Claude, Google Gemini, GitHub, NVIDIA (and empty); user-savable presets (roadmap).
- **PR-14** Matching preview: type a hostname, see which rule matches and whether it would tunnel.
- **PR-15** Import/export rules (JSON).
- **PR-16** Changes apply live (the proxy re-reads the allowlist without restart).

### 4.4 Settings
- **PR-17** Proxy listen port (default `8888`), bind address (default `127.0.0.1`).
- **PR-18** Tunnel (SOCKS) host/port (default `127.0.0.1:1080`), plus "tunnel supervised by app" toggle and a configurable launchd job label.
- **PR-19** Routing policy when tunnel is down: **fail-open** (fall back to direct, show DEGRADED badge) vs **fail-closed** (block allow-listed hosts) — **DECISION: default fail-open, configurable**.
- **PR-20** Idle/keep-alive timeouts, max concurrent connections, buffer sizes.
- **PR-21** Launch at login (SMAppService).
- **PR-22** Optional app-lock passcode (Keychain-stored). Independent of launch-at-login; off by default.
- **PR-23** Monitoring: history retention (days / max rows), auto-purge, log destination.
- **PR-24** System integration: enable/disable shell env injection; list of shell rc files managed.
- **PR-25** Advanced: "restore original proxy settings on quit" toggle; PAC coexistence options.

### 4.5 System integration behaviors
- **PR-26** ON: start local proxy → set system proxy (HTTP+HTTPS `127.0.0.1:8888`) on all active network services → inject shell env → mark launch-at-login → status ON.
- **PR-27** OFF: clear system proxy (restore snapshot if needed) → remove env injection → stop local proxy → status OFF.
- **PR-28** On first ever enable, snapshot current system proxy settings; restore on disable unless user changed them in between (compare hashes).
- **PR-29** `degraded`: tunnel down but routing ON → still set system proxy; allow-listed hosts fall back per policy; clear UI warning.

### 4.6 Tunnel supervision (optional)
- **PR-30** Detect tunnel health (TCP connect + SOCKS5 handshake probe every N sec).
- **PR-31** If "supervise" enabled and tunnel is down, start it via `launchctl` (the configured launchd job label) and wait for it to come up.
- **PR-32** Never kill an externally-managed tunnel without user confirmation.

---

## 5. Architecture Overview

```
                        ┌────────────────────────────────────────────┐
                        │            Proxy Manager App (GUI)         │
                        │  SwiftUI MenuBar + Dashboard + Settings    │
                        │  ┌──────────────┐   ┌────────────────────┐  │
                        │  │ State Machine│   │ Telemetry / SQLite │  │
                        │  │ Routing Eng. │   │  Live Feed + Stats │  │
                        │  └──────┬───────┘   └─────────▲──────────┘  │
                        └─────────┼─────────────────────┼─────────────┘
                                  │ spawn/stop + logs   │ metrics
   ┌──────────────┐  ┌────────────▼──────────┐         │
   │  Browsers /  │─▶│  Local Domain-Aware   │─────────┼──▶ telemetry events
   │  System apps │  │  HTTP CONNECT Proxy   │         │
   │  (system     │  │  127.0.0.1:8888       │         │
   │   proxy)     │  └─────────┬─────────────┘         │
   │  CLI (env)   │            │                       │
   └──────────────┘            │ route decision         │
                               │  host ∈ allowlist?     │
                        ┌──────▼──────────┐             │
                        │   ROUTING CORE  │             │
                        └──────┬────┬─────┘             │
                     tunneled  │    │ direct            │
                        ┌──────▼─┐ ┌▼──────┐            │
                        │ SOCKS5 │ │ TCP   │            │
                        │ client │ │ direct│            │
                        └────┬───┘ └───┬───┘            │
                             │         │                │
               ┌──────────────▼──┐   ┌───▼────────────┐  │
               │ SOCKS5 proxy    │   │ Internet       │  │
               │ 127.0.0.1:1080  │   └────────────────┘  │
               │  (ssh -D/other) │                       │
               └─────────────────┘                       │
   ┌────────────┐        ┌──────────────────────────────▼───┐
   │ Privileged │        │            launchd               │
   │ Helper     │◀───────│ SMAppService + NSXPC             │
   │ (networksetup, env │                                  │
   │  injection)        │                                  │
   └────────────┘        └──────────────────────────────────┘
```

**Component inventory**
1. **Menu bar / GUI** — native AppKit `NSStatusItem` + `NSMenu` (see `StatusMenuController.swift`), Dashboard window, Settings window.
2. **Proxy Core** — in-process (no separate module or IPC). Owns the local HTTP CONNECT proxy, routing engine, SOCKS5 client, telemetry emission.
3. **Routing Engine** — allowlist matching + decision (TUNNEL/DIRECT).
4. **SOCKS5 Client** — RFC 1928 handshake + tunneling.
5. **System Integration** — privileged helper (networksetup), env injection, launch-at-login.
6. **Telemetry Store** — SQLite (request log + aggregates), in-memory live feed.
7. **Tunnel Supervisor** — health probes + optional launchctl control.

---

## 6. Component Design

### 6.1 Menu bar app (native AppKit status menu + SwiftUI windows)

- The menu-bar item is an **AppKit `NSStatusItem` + `NSMenu`**, not a SwiftUI `MenuBarExtra`: a `.menu`-style extra can't tint custom status rows, keep a row open for live toggling, or show native key equivalents. Icon (SF Symbol) reflects state: green `circle.fill` = ON, orange `exclamationmark.triangle.fill` = degraded, `hourglass` = starting/stopping, gray `circle` = OFF.
- Menu layout: inert status rows with colored dots (**Routing** state, **Tunnel** up/down, red **error** line) → **Routing** toggle and **Launch at Login** as plain `NSMenuItem`s with native `state` checkmarks (disabled/grayed during starting/stopping) → **Restart Tunnel** (supervised only) → Dashboard ⌘D / Settings ⌘, / About / Quit ⌘Q. Plain items give native hover highlighting and native checkmarks; the menu closes on selection (standard macOS). Menu items are updated in place from Combine sinks (never rebuilt).
- The status-item icon is colorizable by state (`system.colorizeMenuIcon`, default on; recolored via an SF Symbol `paletteColors` configuration — template `contentTintColor` does not tint status items): green = on, amber = starting/stopping, orange = degraded, red = error, gray = off; off keeps the monochrome template icon.
- Opening Settings from the AppKit menu fires the real SwiftUI-generated “Settings…” command item (SwiftUI’s Settings scene command is a private `menuAction:` item; `sendAction(showSettingsWindow:)` is a no-op).
- `ObservableObject` `AppModel` (app-wide single source of truth), published: `state`, `statsSnapshot`, `recentRequests`, `settings`.
- Windows: Dashboard (`NSWindow` + `NSWindowDelegate` to keep single instance), Settings (`SwiftUI Settings` scene or dedicated window).
- Lifecycle: `@main struct ProxyManagerApp: App`; on launch, restore previous state (start proxy if it was ON), start monitoring; `applicationShouldTerminateAfterLastWindowClosed = false`.
- Menu bar quick actions call `AppModel.toggle()`.

### 6.2 Domain-aware HTTP CONNECT proxy (core)

Implementation: **in-process Swift**, not a child process (avoids IPC, crash-safety via app supervision). **DECISION: raw BSD sockets + detached threads bounded by a semaphore.** `Network.framework` (`NWConnection`/`NWListener`) is forbidden — it honors the macOS system proxy and would loop back into the proxy (see `AGENTS.md` lesson #1 and `docs/networking.md`).

Responsibilities:
- Accept TCP on `127.0.0.1:8888`.
- Parse client request:
  - **CONNECT `host:port`** (HTTPS) → tunnel. The destination host is taken from the CONNECT line. No TLS parsing, no MITM, TLS passes through untouched.
  - **Absolute-form HTTP** (`GET http://host/...`, proxy-style requests) → parse `Host` + absolute URI for the destination; forward with origin-form after stripping proxy headers.
- Route decision per request: `RoutingEngine.decide(host)`.
  - **TUNNEL**: open connection to the SOCKS5 proxy, perform handshake with `host:port` (remote DNS resolution), then bidirectional byte pipe with backpressure and half-close handling.
  - **DIRECT**: open TCP to `host:port` directly, same pipe.
  - **BLOCK** (only if fail-closed & tunnel down): reply `502 Bad Gateway` / reset.
- Emit one telemetry event per connection (started, headers, bytes, finished/error).
- Support **HTTP/1.1 CONNECT** and **HTTP/1.1 absolute-form**; also accept `PRI * HTTP/2.0` preface only as an error path (h2c via proxy is not required).
- Keep-alive: allow multiple absolute-form requests per connection; CONNECT connections are 1:1 and stay open until either side closes.
- Concurrency limits: `maxConcurrentConnections` (default 256), idle timeout (default 120 s), connect timeout (default 10 s).

**Streaming requirement (critical for LLM APIs):** responses must stream with backpressure; never buffer a whole body. Relay with bounded (256 KB) buffers, deferring FIN until buffers drain. This preserves SSE streaming from LLM APIs.

### 6.3 SOCKS5 client (RFC 1928)

- State machine: greeting `[0x05, methods]` (offer NO-AUTH `0x00` only), expect `[0x05,0x00]`; then connect request `[0x05,0x01,0x00, ATYP, DST.ADDR, DST.PORT]` using **ATYP=0x03 (domain)** so DNS resolves on the tunnel side (`--socks5-hostname` equivalent). Accept replies; check `REP==0x00` (SUCCEEDED); parse bound address (can be ignored).
- Timeouts: connect to SOCKS server 5 s; handshake 5 s.
- One SOCKS connection per tunneled request (no connection reuse for CONNECT semantics; reuse only if implementing an internal keep-alive pool later — out of scope v1).
- Health probe: connect + handshake to a harmless target or just greeting; used by `TunnelSupervisor`.

### 6.4 Routing engine & allowlist

- Rule model: `TargetRule { id, pattern, enabled }`.
- Pattern matching (case-insensitive, IDNA-normalized, trim trailing dot):
  - Exact: `example.com` matches only that host.
  - Wildcard subdomain: `*.example.com` matches any host ending with `.example.com` (and the apex `example.com` too — **DECISION**: include apex).
  - Bare `.example.com` (leading dot) treated same as `*.example.com` for convenience.
- Matching algorithm: normalize host → check each enabled rule; return first match (priority = order in list). No match → DIRECT.
- Preview API for the Targets editor (`decide(host)` is pure & unit-testable).
- Allowlist is an `@Published` array persisted to config; the proxy reads it through a `RoutingEngine` reference that's updated on change (no restart).

### 6.5 System integration

**A. macOS system proxy (requires admin):**
- Set on **all active network services** (iterate `networksetup -listallnetworkservices`, skip disabled, apply only to those with a route, or simpler: always all enabled services).
- Commands (run via privileged helper):
  - `networksetup -setwebproxy <service> 127.0.0.1 8888`
  - `networksetup -setsecurewebproxy <service> 127.0.0.1 8888`
  - `networksetup -setproxybypassdomains <service> "*.local" "169.254/16" "localhost" "127.0.0.1" "::1"`
- Also **clear PAC** if present (`-setautoproxystate <service> off`) so browsers use the manual proxy uniformly (single control point).
- Snapshot: before first enable, store each service's current proxy settings (web, secure, PAC, bypass) as JSON in `~/Library/Application Support/ProxyManager/system-proxy-snapshot.json`; on disable restore if unchanged.
- **DECISION:** Primary mechanism = manual system proxy on all enabled services + PAC disabled. PAC *hosting* is an optional alternate mode (see 6.7 / Open Questions).

**B. Shell / CLI env injection:**
- App writes `~/.config/proxy-manager/env.sh`:
  ```
  export HTTP_PROXY="http://127.0.0.1:8888"
  export HTTPS_PROXY="http://127.0.0.1:8888"
  export NO_PROXY="127.0.0.1,localhost,::1"
  export PROXY_MANAGER_ACTIVE="1"
  ```
  (optionally lower-case variants; not `ALL_PROXY`).
- App appends a guarded `source` line to `~/.zshrc`, `~/.zprofile`, `~/.bash_profile` (only files that exist; mark with `# >>> proxy-manager <<<` / `# <<< proxy-manager >>>` delimiters for clean removal).
- ON writes + sources; OFF removes delimiters + deletes file. Existing shells won't re-read; document that new terminals are affected (accepted behavior).

**C. Launch at login:** `SMAppService.mainApp.register()` (macOS 13+), unregister on off-if-desired (setting).

### 6.6 Privileged helper

- **Goal:** perform admin-only operations (`networksetup`) without `sudo` password prompts, with a clean native auth dialog.
- Design: separate executable `ProxyManagerHelper` installed as a LaunchDaemon via **`SMAppService.daemon(plistName:)`** (macOS 13+), communicating over **NSXPCConnection**.
- Exposed XPC interface: `enableSystemProxy(services: [String])`, `disableSystemProxy()`, `readSystemProxyState()`, `applyPAC(...)` (for PAC mode). Validate all args (service names whitelisted via regex, ports as ints, IP as 127.0.0.1 only).
- Authorization: the XPC listener checks the caller's code-signing **Team ID** before exporting root `networksetup` (see `AGENTS.md` lesson #8). The XPC client uses a bounded timeout so a missing daemon cannot deadlock.
- Code signing: both app and helper signed with the same Team ID + `SMPrivilegedExecutables` entitlement matching the helper's designated requirement.
- **Privilege order when the daemon is not registered:** run `networksetup` **directly as the user** (per-user proxy settings need no root), and only fall back to `osascript … with administrator privileges` if the direct path fails. See `docs/system-integration.md`.

### 6.7 Telemetry & storage

- **SQLite** via the system `SQLite3` module (no third-party deps). DB at `~/Library/Application Support/ProxyManager/telemetry.sqlite`.
- Schema (v1):
  ```sql
  CREATE TABLE requests (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts INTEGER NOT NULL,             -- unix ms
    scheme TEXT,                     -- http|https
    method TEXT,
    host TEXT NOT NULL,
    port INTEGER,
    path TEXT,
    route TEXT NOT NULL,             -- TUNNEL|DIRECT|BLOCK
    status INTEGER,                  -- 0 if connection-level (e.g., 502, reset)
    bytes_in INTEGER DEFAULT 0,
    bytes_out INTEGER DEFAULT 0,
    duration_ms INTEGER,
    error TEXT,
    src_port INTEGER
  );
  CREATE INDEX idx_requests_ts ON requests(ts);
  CREATE INDEX idx_requests_host ON requests(host);
  CREATE INDEX idx_requests_route ON requests(route);

  CREATE TABLE minute_stats (
    bucket INTEGER NOT NULL,         -- ts rounded to minute
    route TEXT NOT NULL,
    requests INTEGER NOT NULL,
    bytes_in INTEGER NOT NULL,
    bytes_out INTEGER NOT NULL,
    PRIMARY KEY (bucket, route)
  );
  ```
- Writer: serial `DispatchQueue`; batches inserts; WAL mode; retention purge job (per retention setting).
- Live feed: in-memory ring buffer (e.g., last 5,000 events) published via `@Published`; dashboard subscribes; aggregate recompute from SQLite on range change.
- Privacy: no request bodies/headers stored (only metadata); toggle "record paths" off to strip `path`.

### 6.8 Settings & persistence

- Config file: `~/Library/Application Support/ProxyManager/config.json` (JSON, atomic write) — human-editable and back-uppable. (Or `UserDefaults` for ephemeral UI prefs + JSON for important settings; **DECISION: single JSON config file** for portability/editing.)
- Schema sketch:
  ```json
  {
    "version": 1,
    "proxy": { "bindHost": "127.0.0.1", "port": 8888 },
    "tunnel": { "host": "127.0.0.1", "port": 1080, "supervised": false, "launchdLabel": "" },
    "policy": { "failClosedWhenTunnelDown": false },
    "system": { "injectShellEnv": true, "launchAtLogin": true, "restoreOnQuit": true, "managedShellRcs": ["~/.zshrc"] },
    "targets": [ { "id": "...", "pattern": "example.com", "enabled": true } ],
    "monitor": { "retentionDays": 7, "maxRows": 500000, "recordPaths": true },
    "lock": { "enabled": false }
  }
  ```

### 6.9 Tunnel supervisor

- Health probe loop (every 10 s): open TCP to `tunnel.host:tunnel.port`, send SOCKS5 greeting, expect `[0x05,0x00]`, close.
- State: `tunnelUp: Bool`. Feed into app state machine.
- If `supervised` and down: `launchctl kickstart -k gui/$(id -u)/<configured launchd label>`; wait up to 15 s.
- Never kill the tunnel unless user explicitly asks in UI (button "Restart tunnel").

---

## 7. Networking Protocol Details

### 7.1 CONNECT tunneling sequence
1. Client → proxy: `CONNECT api.example.com:443 HTTP/1.1\r\nHost: api.example.com:443\r\n[Proxy-Authorization ignored]\r\n\r\n`
2. Proxy decides route.
3. TUNNEL: SOCKS5 handshake to the configured proxy for `api.example.com:443`. DIRECT: plain `connect()`.
4. On success → proxy → client: `HTTP/1.1 200 Connection Established\r\n\r\n`.
5. Bidirectional raw pipe until close. On failure → `HTTP/1.1 502 Bad Gateway` (or 504 for timeout) + close.
6. Half-close: propagate `fin`/`cancel` from one side to the other; terminate on first `EOF`/error and drain gracefully.

### 7.2 Plain HTTP (absolute-form) forwarding
- Parse request line + headers; require absolute URI or `Host`. Rewrite to origin-form, drop `Proxy-Connection`/`Proxy-Authorization`, forward, stream response headers+body, keep-alive per client.

### 7.3 Timeouts & limits (defaults)
- connect to destination / SOCKS: 10 s; SOCKS handshake: 5 s; idle: 120 s; max concurrent: 256; max pending: 1024; read chunk: 16 KiB.

### 7.4 Error mapping (surface to UI)
| Condition | Result |
|---|---|
| Tunnel down + fail-open | DIRECT fallback, event route=DIRECT, note "tunnel_down" |
| Tunnel down + fail-closed | BLOCK, status 502 |
| SOCKS auth/REP error | 502 |
| DNS/connect fail | 502 / 504 |
| Timeout | 504 |
| Client aborts | log truncated event |

---

## 8. GUI / UX Design

### 8.1 Onboarding / first-run
- **Launch at login:** toggled in Settings + asked at onboarding ("Start Proxy Manager when you log in?").
- **First-run wizard** (one-time, re-openable from Settings → General): 1) Welcome + plain-language explanation (HTTP proxy / SOCKS5 tunnel / routing); 2) Tunnel address (host/port) with a live "Test connection" probe; 3) Choose targets (preset or start empty); 4) Done (enable now, launch at login, shell env).
- **App lock (optional):** if enabled, show a passcode sheet on launch (passcode in Keychain via `SecItem`). A separate optional privacy feature, not required for launch-at-login.

### 8.2 Menu bar
Icon + text label; click → menu:
- Status row (state + tunnel health, colored dot).
- Quick stats: `tunneled: 12,304 · 1.2 GB · 4 req/s`.
- Toggle: `Enable Routing` / `Disable Routing` (with shortcut).
- `Restart tunnel` (if supervised).
- `Open Dashboard…` (`⌘D`), `Settings…` (`⌘,`).
- Recent 5 requests (mini feed) → click opens dashboard focused.
- `Quit Proxy Manager`.

### 8.3 Dashboard
- `NavigationSplitView` or single window with `Toolbar`:
  - Toolbar: live toggle, route filter (All/Tunneled/Direct), host search, pause live, time range, purge.
  - Left: request feed table (SwiftUI `Table`). Row color/icon per route.
  - Right/bottom: detail pane (selected request metadata).
  - Top: graph strip (`Charts` framework): RPS line, bytes/s area, per-host top bar, error ratio; range buttons 5m/1h/24h/7d.
  - Live connections panel (collapsible).
- Auto-updating via `@Published` feed (throttled to ~10 Hz UI refresh).

### 8.4 Targets editor
- Panel: list of rules (pattern, enabled toggle). Bulk textarea for adding (split on line breaks/commas/semicolons) with inline edit (double-click or pencil; Return saves, Esc cancels). Preview matcher field. Presets menu (DeepSeek, OpenAI, Anthropic/Claude, Gemini, GitHub, NVIDIA, WhatsApp, empty). Export/Import JSON.

### 8.5 Settings
Tabs: General / Proxy / Tunnel / Targets / Monitoring / System / Advanced.
- General: launch at login, app lock. Appearance: color mode (System/Light/Dark), menu-bar icon style (Classic/Colorized), icon placement (Menu bar only / Menu bar + Dock / Dock only).
- Proxy: bind host, port, fail-open/closed, timeouts, concurrency.
- Tunnel: host/port, supervised, "Restart tunnel" button, health status.
- System: shell env injection + list of rc files, "restore on quit", PAC mode (advanced).
- Monitoring: retention, record paths, log file location (open in Finder).
- Advanced: config file path (open), import/export full config, reset all.

---

## 9. Security & Privacy

- **No MITM.** TLS is pass-through; app never sees plaintext payloads. Metadata only (host, size, timing, status).
- Local-only bind (`127.0.0.1`); no remote exposure.
- Target-list and config are user-local JSON (chmod 600 for snapshot file which contains proxy state; no secrets stored — tunnel creds stay in ssh/autossh).
- Privileged helper: designated-requirement signed; XPC arg validation; no shell interpolation (pass argv arrays).
- Passcode (if enabled) stored in Keychain with `kSecAttrAccessibleWhenUnlocked`.
- Telemetry DB optional encryption: v1 relies on file permissions + `NSFileProtection` where possible; note as enhancement.
- Handle `HTTP_PROXY` credential leaks: never log Proxy-Authorization; strip in plain-HTTP forwarding.
- Loop prevention: `NO_PROXY` includes localhost/127.0.0.1 and the proxy's own port is never a target; reject CONNECT to the proxy's own bind address.

---

## 10. Stability & Reliability

### 10.1 State machine
```
          ┌─────────┐  enable    ┌───────────┐
          │  OFF    │──────────▶ │ STARTING  │
          └────┬────┘            └─────┬─────┘
        disable│                       │ proxy up + system applied
          ┌────▼─────┐            ┌────▼──────────┐
          │ STOPPING │◀───────────│     ON        │
          └──────────┘  disable    │ (tunnel up)   │
                                   └────┬──────────┘
                                        │ tunnel lost
                                   ┌────▼──────────┐
                                   │  DEGRADED     │──▶ (fail-open or fail-closed)
                                   └────┬──────────┘
                                        │ tunnel recovered
                                   ┌────▼──────────┐
                                   │     ON        │
                                   └───────────────┘
```
- Transitions are serialized (single actor). Toggle during STARTING/STOPPING queues or blocks UI (spinner) rather than racing.
- Crash recovery: on launch, read persisted state; if was ON, restart proxy + verify system proxy still points at us; if mismatch, re-apply (with helper) or surface warning.

### 10.2 Resilience
- Proxy core supervises its own accept loop; on fatal error, restarts accept + logs event.
- Backpressure everywhere; no unbounded buffers (bounded queues + connection limits).
- All network calls have timeouts; connections are cancelled on shutdown; graceful shutdown drains active tunneled connections up to 5 s then closes.
- Network change handling: `NWPathMonitor` — on interface change, re-probe tunnel, re-apply system proxy if the active interface list changed.
- Config writes are atomic (write temp + rename); corrupted config → back up `.corrupt` and start with defaults, surface warning.
- DB errors are non-fatal (log; continue in-memory).

### 10.3 Edge cases
- Multiple/all interfaces; Ethernet+Wi-Fi both active → set proxy on all enabled services (dedupe by name).
- IPv6-only SOCKS server (future) — handle via `NWEndpoint`; v1 IPv4/`localhost`.
- Unicode/IDN domains in targets — normalize (IDNA, lowercase).
- Host with trailing dot, port included in host field — normalize before matching.
- Very long-lived LLM streaming connections — ensure idle timeout doesn't kill active streams (reset idle timer on any traffic).
- `SIGTERM`/logout — restore proxy settings if "restore on quit" enabled.

---

## 11. Performance

- Raw BSD sockets with a semaphore-bounded pool of detached threads (never `DispatchQueue.global()`, which caps blocking threads at ~64).
- 16 KiB chunked reads; `send` pipelining with completion backpressure.
- Minimal per-request object churn; reuse request structs.
- Telemetry writes batched (e.g., flush every 1 s or 500 rows).
- Dashboard UI refresh throttled; graphs aggregate from SQLite minute table, not per-row.
- Target: handle 500+ concurrent connections and sustained streaming without CPU/DNS overhead issues; memory bounded.

---

## 12. Testing Strategy

Testing uses standalone `main.swift` harnesses (no XCTest/SPM), run via
`./Tests/run-all.sh`. See [`docs/testing.md`](docs/testing.md) for the harness
inventory, the regression checklist, and the crash-watchdog harness.

---

## 13. Build, Signing & Distribution

Built with `swiftc` via `./build.sh <version>` — no Xcode project. See
[`docs/build-and-distribution.md`](docs/build-and-distribution.md) for the build
options (`UNIVERSAL=1`, `IDENTITY=…`), helper embedding, and signing.

---

## 14. Project Layout (actual)

The authoritative layout, commands, and area docs live in **`AGENTS.md`** and
**`docs/`**. Everything builds with `swiftc` via `build.sh` (no Xcode project).


---

## 15. Decisions Log

| # | Decision | Status |
|---|---|---|
| D1 | Smart local proxy + system switch model (allow-list only, default empty + presets) | ✅ Confirmed |
| D2 | Default fail-OPEN when tunnel down (configurable) | ✅ Confirmed |
| D3 | `*.example.com` wildcard also matches apex | ✅ Confirmed |
| D4 | Manual system proxy on all enabled services + PAC disabled (single control point) | ✅ Confirmed |
| D5 | Proxy core runs in-process (raw BSD sockets), not a child process | ✅ Confirmed |
| D6 | SQLite (system `SQLite3`) for telemetry; JSON for config | ✅ Confirmed |
| D7 | CLI env via guarded source blocks in existing rc files | ✅ Confirmed |
| D10 | **Privileged helper implemented**: `ProxyManagerHelper` LaunchDaemon (SMAppService.daemon + NSXPC, `com.proxymanager.helper`) performs `networksetup` as root. When the daemon isn't registered (ad-hoc/unsigned builds) the app runs `networksetup` directly as the current user (prompt-free — per-user proxy settings need no root) and only falls back to `osascript` if the direct path fails. Registering the daemon requires a Developer-ID-signed build installed in `/Applications`. | ✅ Confirmed |
| D9 | **App is a regular (foreground) app with Dock icon + standard app menu, plus a native `NSStatusItem` + `NSMenu` for one-click control (replaced the SwiftUI `.menu` MenuBarExtra — a `.menu` extra can't do custom tinted status rows, stay-open toggles, or native key equivalents). Dashboard is a single-instance NSWindow (reopened via Dock/⌘D/menu bar). The icon placement is user-selectable (`system.iconMode`): Menu bar + Dock (default), Menu bar only (`.accessory`, no Dock icon), or Dock only (status item hidden).** (Revised from "menu bar-only accessory app" after UX feedback: accessory apps never show an app menu or activate normally.) | ✅ Confirmed |
| D11 | **Crash watchdog implemented as a `KeepAlive` user LaunchAgent running the app binary as `ProxyManager --watchdog`** (not a child process, not `SMAppService.daemon`): survives `kill -9`, self-restarts via launchd, needs no signing/admin. Detection is event-driven (`kqueue EVFILT_PROC/NOTE_EXIT` + `EVFILT_VNODE`, adaptive 15 s/120 s safety tick, ~0 idle CPU). It restores only when a snapshot exists *and* the proxy points at `127.0.0.1` (idempotent, never clobbers a user proxy), using a prompt-free helper/direct `networksetup` path. Toggle: `config.system.crashWatchdog` (default on). | ✅ Confirmed |

## 16. Open Questions
1. Should the app also **serve a PAC file** (optional mode) so users who prefer PAC keep that model? (Planned as advanced setting; default manual proxy.)
2. Allow-list only in v1, or expose an optional **"route all traffic"** mode later? (Planned as v2.)
3. Do you want a **local web/metrics endpoint** (e.g., `http://127.0.0.1:18888/metrics` JSON) for scripting/`dash` dashboards? (Planned as enhancement.)

## 17. Risks
1. **macOS updates** changing `networksetup` behavior → pin supported macOS; monitor.
2. **Notarization + helper entitlements** → the helper requires a Developer-ID-signed build in `/Applications`; notarization is still pending.

---

## 18. Appendix

### 18.1 References
- RFC 1928 (SOCKS5), RFC 7230 (HTTP/1.1 message framing), RFC 7231 (CONNECT semantics).
- Apple: `Charts`, `SMAppService` (macOS 13+), `NSXPCConnection`, `Security`, `SQLite3`.

---

*End of plan. Update after each build session; keep this file the authoritative spec.*
