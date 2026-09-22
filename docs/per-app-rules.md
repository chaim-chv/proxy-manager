# Per-App Proxy Rules — Design & Implementation Plan

> **Status: IMPLEMENTED (Phases 1–5).** This document is the end-to-end plan
> for routing traffic **per originating app** in addition to (or instead of) the
> existing hostname allow-list ("Targets").
>
> **Phase 1 (identity layer)** — `Sources/Routing/AppIdentity.swift` +
> `Sources/Routing/AppResolver.swift`, tested by `Tests/AppIdentityHarness`.
>
> **Phase 2 (routing)** — `AppRule`/`AppSettings` in the config,
> `RoutingEngine.decide(host:app:)`, and `ProxyServer` integration (gated on
> `RoutingEngine.needsAppIdentity`, so the default hot path is untouched).
> Covered by `Tests/RegressionHarness` (precedence table) and `Tests/ProxyE2E`
> (live per-app direct/tunnel).
>
> **Phase 3 (telemetry)** — `RequestEvent.app`/`appBundle`, guarded SQLite
> migration, the dashboard **App** column + app filter + a Hosts/Apps breakdown,
> and the detail-pane App row. Covered by `Tests/TelemetryHarness` and
> `Tests/ProxyE2E`.
>
> **Phase 4 (Settings → Apps)** — `Sources/UI/AppsSettingsView.swift` (list +
> detail, master switch, default-mode control, running-apps / app / executable
> pickers).
>
> **Phase 5 (menu-bar control)** — `StatusMenuController`'s `App: &lt;name&gt; ▸`
> submenu (front-app mode, remove, More…).
>
> The feature remains **off by default**.

---

## 1. Goal

Today ProxyManager routes by **host**: a request to an allow-listed hostname goes
through the SOCKS5 tunnel, everything else goes direct. We want to add a second
axis — **the app that opened the connection** — so a user can say:

- "Everything Chrome does goes through the tunnel (regardless of host)."
- "The Dropbox helper always goes direct, even for allow-listed hosts."
- "Only these three apps use the tunnel; everything else is direct."

and configure it with as little friction as a per-app toggle, plus a way to
configure the **currently frontmost app** right from the menu bar (the pattern
used by [InputSourcePro](https://github.com/runjuu/InputSourcePro) and
[LinearMouse](https://github.com/linearmouse/linearmouse)).

Hard constraints (from `AGENTS.md`): imperceptible overhead, no crashes, never
break the user's internet, everything logged and debuggable.

---

## 2. "What defines an app?" — the identity model

A connection arriving at `127.0.0.1:8888` is a TCP socket from some local
process. We need to turn "some process" into a stable, user-recognisable key.

### 2.1 Candidate keys

| Key | Stable across updates? | Covers helpers? | Notes |
|---|---|---|---|
| **Bundle identifier** (`com.google.Chrome`) | ✅ | via responsible-process resolution | The natural macOS identity; what users see in LaunchServices. |
| **Executable path** (`/usr/local/bin/node`) | ⚠️ moves on reinstall | n/a | The only key for bundle-less CLI tools. |
| **Executable name** (`node`) | ✅ | n/a | Convenient, ambiguous (two `node`s). LinearMouse offers it. |
| **Code-signing id / Team ID** | ✅ | ✅ | Robust, but needs a `SecCode` call per process; deferred to v2. |
| **PID** | ❌ | ❌ | Transient; never a rule key (used only internally). |

**Decision (proposed):** key on **bundle id** primarily, with **executable
path** and **executable name** as fallbacks for CLI tools — exactly LinearMouse's
`AppTarget` (`bundle` / `executable` / `executableName`). A rule stores an
explicit key type so there is no guessing.

### 2.2 Getting the PID for an accepted TCP connection — **the hard part**

**Probe result (run on macOS 15.8, this machine):**

- `getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID)` → `ENOPROTOOPT` (42) for TCP. It
  **only works for `AF_UNIX` sockets**. (Verified: works on a UNIX-domain socket,
  fails on a loopback TCP socket, on both the accepted and connecting side.)
- `getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED)` on TCP returns `rc=0` with
  `len=0` (empty `xucred`) — useless.
- There is **no public socket option** that yields the peer PID for TCP.

**The viable mechanism** is a `libproc` scan (the technique `lsof`/`nettop`
use), which Swift's `Darwin` module already exposes (no C shim needed):
`proc_listpids(PROC_ALL_PIDS)` → `proc_pidinfo(pid, PROC_PIDLISTFDS)` →
`proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO)` and match the client socket by
`(localPort == peer's ephemeral port, foreignPort == proxy port)`.

**Measured cost** (release build, this machine, ~670 processes / ~8 100 fds /
~890 sockets):

| Scenario | Result |
|---|---|
| Single lookup, match found early | **~0.03–0.3 ms** |
| Single lookup, full scan to the end | **~2.8 ms** (unoptimised; ~1–1.5 ms with `-O`) |
| 200 concurrent lookups (`concurrentPerform`) | **~18 ms wall** (~11 k lookups/s throughput) |

So a per-connection scan is affordable; it is **zero-cost when per-app rules are
disabled** (we simply skip it).

**Permission caveat:** `proc_pidinfo` on another user's process returns nothing
(~206/670 pids on this machine). Same-user apps (the normal case) are fully
resolvable; root/other-user daemons become "System / Unknown".

### 2.3 Turning the PID into a user-facing app

`NSRunningApplication(pid).bundleIdentifier` returns the **process's own** bundle
id — for a helper that is `com.google.Chrome.helper`, not `com.google.Chrome`.
Path-walking to the enclosing `.app` fixes Chrome/Slack helpers but **fails** for
WebKit's shared networking process and for Chrome launched from a code-sign
clone (both observed live).

**Probe result:** the private symbol
`responsibility_get_pid_responsible_for_pid` (from
`/usr/lib/system/libsystem_coreservices.dylib`, loaded via `dlsym`) returns the
**TCC-style "responsible" process**, which resolves exactly the way users think:

| Process | Own bundle id | Enclosing `.app` | **Responsible app** |
|---|---|---|---|
| `Google Chrome Helper (Renderer)` | `<nil>` / `.helper` | `com.google.Chrome` | ✅ `com.google.Chrome` |
| `Slack Helper` | `com.tinyspeck.slackmacgap.helper` | `com.tinyspeck.slackmacgap` | ✅ `com.tinyspeck.slackmacgap` |
| `com.apple.WebKit.Networking` (Raycast) | `com.apple.WebKit.Networking` | `<none>` | ✅ `com.raycast.macos` |
| `com.apple.WebKit.Networking` (Fork) | `com.apple.WebKit.Networking` | `<none>` | ✅ `com.DanPristupov.Fork` |
| `chrome_crashpad_handler` | `<nil>` | `com.google.Chrome` | ✅ `com.google.Chrome` |
| `/usr/bin/curl` launched by a non-GUI process | `<nil>` | `<none>` | itself (`curl`) |

**Proposed resolution algorithm** (one pass, per connection, cached by PID):

1. `path = proc_pidpath(pid)`.
2. `enclosing = enclosingAppBundle(path)` — the outermost `.app` on the path.
   - If found → **app identity = enclosing** (handles apps *and* their helpers).
3. Else if the process's own bundle id exists and the path is **not** a helper
   location (`.../Contents/Frameworks|XPCServices|Library/...` or `.xpc/`) →
   use the own bundle id (handles Chrome from a code-sign clone).
4. Else if `responsiblePid != pid` and the responsible process has a bundle id →
   use it (handles WebKit.Networking → host app, and app-launched scripts).
5. Else → **executable identity**: path + last path component (handles
   `node`/`curl`/`python`). Deliberately *prefer the process's own executable over
   a terminal*, so CLI tools are attributed to the tool, not to Terminal.

`responsible_get_pid_responsible_for_pid` is a **private API**. It is resolved
dynamically and is best-effort: if the symbol is missing the resolver degrades to
steps 1–3/5, which already covers Chrome/Slack/Electron. (Private API is allowed
for a Developer-ID/notarised app; it would block Mac App Store distribution,
which this project does not target.)

### 2.4 Result

```swift
struct AppIdentity {
    let pid: Int32
    let bundleId: String?         // best available app bundle id
    let executablePath: String
    let executableName: String    // last path component
    let displayName: String       // e.g. "Google Chrome", "node"
}
```

Rules match against `bundleId`, then `executablePath`, then `executableName`.

---

## 3. Rule model & precedence

**Confirmed by the user:** one **uniform three-way mode** is used both per-app
and as the default for apps that have no rule:

| Mode | Meaning |
|---|---|
| **Tunnel all** (`.tunnel`) | Every request from this app goes through the SOCKS5 tunnel, regardless of host. |
| **Use target rules** (`.targets`) | This app follows the hostname allow-list ("Targets") — today's behaviour. |
| **Direct all** (`.direct`) | Every request from this app goes direct, even for allow-listed hosts. |

### 3.1 Rule

```swift
enum AppRuleKeyKind: String, Codable { case bundle, executable, executableName }

enum AppRoutingMode: String, Codable {
    case tunnel    // "Tunnel all"
    case targets   // "Use target rules"  (fall through to the host allow-list)
    case direct    // "Direct all"
}

struct AppRule: Identifiable, Codable, Equatable {
    var id: UUID
    var key: String            // "com.google.Chrome" | "/usr/local/bin/node" | "node"
    var keyKind: AppRuleKeyKind
    var mode: AppRoutingMode   // .tunnel | .targets | .direct
    var enabled: Bool
}
```

A rule may be persisted with `.targets` (explicit "follow the allow-list"), which
is behaviourally identical to having no rule but lets the user keep the app in
the list and visible. Deleting the rule is equivalent.

### 3.2 Decision

```
resolve AppIdentity for the connection   // nil when per-app rules are disabled
let mode = matching enabled AppRule?.mode ?? config.apps.defaultMode
switch mode:
    .tunnel  -> TUNNEL
    .direct  -> DIRECT
    .targets -> RoutingEngine.decide(host)     // today's host allow-list
```

The **default mode** (for apps with no matching rule) is the same three-way
choice and defaults to `.targets`, so out of the box the behaviour is unchanged.
Setting the default to `.direct` gives the "per-app VPN" model (only apps with a
`Tunnel all` rule use the tunnel); setting it to `.tunnel` is the inverse.

---

## 4. Proxy integration

In `ProxyServer.handleConnection` (which already runs on a dedicated thread and
already has `cfd`), before the route decision:

```swift
let identity = appResolver.resolve(peerPort: srcPort, proxyPort: s.port)  // nil if disabled
let decision = routingEngine.decide(host: host, app: identity)
```

- `AppResolver` (`Sources/Routing/AppResolver.swift`) owns the libproc scan,
  the responsible-pid `dlsym`, and two caches:
  - `pid → AppIdentity` (TTL ~30 s, invalidated by PID-reuse check via process
    start time from `proc_pidinfo(PROC_PIDTBSDINFO)`), and
  - a tiny `(port, remotePort) → pid` LRU (TTL ~5 s) for retries.
- `RoutingEngine` gains a precompiled app-rule index
  (`bundleRules` / `execPathRules` / `execNameRules` dictionaries → O(1)) built in
  `update(rules:appRules:appEnabled:defaultMode:)`.
- **Gated:** `resolve` is called only when `RoutingEngine.needsAppIdentity` is
  true (per-app routing enabled **and** at least one enabled rule exists); a
  default mode alone needs no identity, so the default hot path is exactly
  today's — zero added syscalls.

### 4.1 Performance budget

- One scan per new connection: ~0.3 ms typical / ~1–3 ms worst. Connection
  setup already does DNS + TCP/SOCKS handshake (tens of ms), so this is noise.
- Cache `pid → AppIdentity` so repeat connections from the same app skip the
  path/bundle/responsible work.
- Bound concurrent scans with a small semaphore (e.g. 32) to avoid a syscall
  storm under a synthetic 200-way burst; waiters block briefly.
- Nothing is added to the per-byte relay path (`relay()` unchanged).

---

## 5. Config schema (tolerant decode, as required by lesson #13)

```jsonc
"apps": {
  "enabled": false,              // opt-in; false = zero overhead
  "defaultMode": "TARGETS",      // TUNNEL | TARGETS | DIRECT  (for apps with no rule)
  "recordInTelemetry": true,     // show the app column / store it in SQLite
  "rules": [
    { "id": "…", "key": "com.google.Chrome", "keyKind": "BUNDLE",
      "mode": "TUNNEL", "enabled": true },
    { "id": "…", "key": "/usr/local/bin/node", "keyKind": "EXECUTABLE",
      "mode": "TARGETS", "enabled": true }
  ]
}
```

`AppConfig` gets `var apps: AppSettings = AppSettings()`; `AppSettings` and
`AppRule` get hand-written `init(from:)` with `decodeIfPresent(...) ?? default`.

---

## 6. Telemetry

- `RequestEvent` gains `app: String?` (display name) and `appBundle: String?`.
- `requests` table gains `app TEXT` / `app_bundle TEXT`. Migration:
  `ALTER TABLE requests ADD COLUMN ...` guarded by a `PRAGMA table_info(requests)`
  check (existing DBs must not fail).
- Dashboard feed gains an **App** column; detail pane shows it; a route/app
  filter and a "top apps" list (analogous to "top tunneled hosts").
- Recording is gated by `apps.recordInTelemetry` so users who only want routing
  can keep telemetry as-is.

---

## 7. UI design

### 7.1 Settings → **Apps** (new sidebar section, between Targets and System)

Layout mirrors InputSourcePro's Rules screen: a **left list** of configured apps
+ an **add** control, and a **right detail** pane.

- **Left list** — one row per app: app icon, display name, key (`com.google.Chrome`
  / `node`), and the current mode as a colored chip. Multi-select supported.
- **Add** — two buttons like InputSourcePro/LinearMouse:
  - **＋ Choose App…** → `NSOpenPanel` restricted to `.application`.
  - **＋ Add Running Apps ▾** → menu of `NSWorkspace.shared.runningApplications`
    (icons + names), filtered to real apps (LinearMouse-style).
  - (Optional) **Add Frontmost App** and **drag an app in**.
  - CLI tools via **Add Executable…** (file picker) — path or name key.
- **Right detail** — for the selection:
  - **Routing**: a 3-way control `Tunnel all · Use target rules · Direct all`
    (segmented / radio). This is the "just a toggle" the user asked for.
  - Key + kind, app path, and **Remove**.
- Header explains the precedence ("Each app picks one of three modes; apps with no
  rule use the default mode below") with a `HelpPopover`.
- A **Default for apps with no rule** control at the top of the page, offering the
  same three modes (default `Use target rules`).

### 7.2 Menu bar — configure the front app (InputSourcePro / LinearMouse pattern)

- Add a **dynamic row** to the native `NSStatusItem` menu, e.g.
  `App: Google Chrome  ▸` with submenu items:
  - `Tunnel all`, `Use target rules`, `Direct all` (native checkmark on the
    current mode), and `More…` (opens Settings → Apps with the app selected).
- The front app is captured when the menu opens
  (`NSWorkspace.shared.frontmostApplication`; opening our status menu does not
  change it) and the row is refreshed from
  `NSWorkspace.didActivateApplicationNotification` while the menu is open, using
  the same `AppResolver` identity logic. If the front app is a helper/WebKit
  process it is shown under its responsible app.
- `StatusMenuController` already updates items **in place**; this row follows the
  same pattern.

### 7.3 Dashboard

- New **App** column in the feed (after Host), the app shown in the detail pane,
  an app filter, and an app breakdown alongside "top tunneled hosts".

### 7.4 Onboarding

- Optional, minimal: a one-line mention in the Targets/Done steps ("You can also
  route specific apps from Settings → Apps"). Not a new required step.

---

## 8. Edge cases & risks

| Risk | Mitigation |
|---|---|
| Private responsible-pid API disappears | `dlsym` + fall back to enclosing `.app` / own bundle / executable |
| Other-user / root processes unattributable | Show "System / Unknown"; host rules still apply |
| PID reuse poisoning the cache | Validate process start time; short TTL |
| Ephemeral-port reuse racing the scan | Match `(localPort, foreignPort)` + `ESTABLISHED` + loopback address |
| Scan cost under a 200-way burst | Semaphore-bounded scans; early-exit; PID cache; feature is opt-in |
| Helpers/XPC misattribution | Responsible-pid resolution (validated live) |
| CLI tools attributed to Terminal | Prefer the process's own executable for bundle-less processes |
| DB migration on existing installs | `PRAGMA table_info` guarded `ALTER TABLE`; tolerant config decode |
| A wrong "Direct" rule silently bypasses the tunnel | Surface the matched app + mode in the feed and detail pane |

---

## 9. Testing plan (repo conventions)

- **`Tests/AppIdentityHarness`** (new): spins up a listener, spawns known
  clients (a plain executable and a fake `.app` bundle), and asserts the resolver
  returns the expected bundle/path; exercises the enclosing-app and
  executable-name paths without the private API.
- **`Tests/RegressionHarness`** (extend): `AppSettings`/`AppRule` legacy +
  future-config decode; `RoutingEngine.decide(host:app:)` precedence table
  (app proxy > app direct > host rules; disabled rule ignored; default mode).
- **`Tests/ProxyE2E`** (extend): a client with an app rule is tunnelled/directed
  accordingly end-to-end through a mock SOCKS5.
- **Manual/`system-proxy-safety-testing`:** confirm enabling/disabling per-app
  rules never changes system-proxy safety, and that the feature is inert when
  `apps.enabled == false`.
- **Perf probe:** keep a bench like the one used here to guard the scan budget.

---

## 10. Phased implementation

1. **Identity layer** — ✅ **done**: `AppIdentity` + `AppResolver` (libproc scan,
   responsible pid via `dlsym`, caches) + `Tests/AppIdentityHarness`. No
   behaviour change.
2. **Routing** — ✅ **done**: `AppRule`/`AppSettings` config + `RoutingEngine.decide(app:)` +
   `ProxyServer` integration, gated off by default (`needsAppIdentity`). Unit +
   live e2e coverage.
3. **Telemetry** — ✅ **done**: `RequestEvent.app`/`appBundle`, guarded SQLite
   migration, feed App column, app filter, Hosts/Apps breakdown.
4. **Settings → Apps UI** — ✅ **done**: `Sources/UI/AppsSettingsView.swift` (list/detail,
   master switch, default mode, running-apps / app / executable pickers).
5. **Menu-bar front-app control** — ✅ **done**: `StatusMenuController`'s
   `App: <name> ▸` submenu.
6. **Docs** — ✅ updated: `AGENTS.md` index, `docs/routing.md`, `docs/config.md`,
   `docs/ui.md`, `docs/telemetry.md`, `docs/testing.md`, `PLAN.md` decisions log.

---

## 11. Resolved decisions (from user)

| # | Question | Decision |
|---|---|---|
| 1 | App rule vs host allow-list | **Uniform three-way mode per app**: `Tunnel all` / `Use target rules` / `Direct all`. |
| 2 | Apps with no rule | Same three-way **default mode**, defaulting to `Use target rules` (today's behaviour); configurable to `Direct all` (per-app-VPN) or `Tunnel all`. |
| 3 | Control style | The same three-way control per app (the "just a toggle" the user asked for). |
| 4 | Private responsible-pid API | **Yes**, best-effort with graceful fallback. |
| 5 | Default on/off | **Off by default** (zero overhead until enabled). |
| 6 | Telemetry | Record the app while the feature is enabled. |
| 7 | Section name | **Apps**. |

Still worth confirming during implementation (non-blocking):

- Exact wording/labels of the three modes (`Tunnel all` / `Use target rules` /
  `Direct all`).
- Whether to also offer an "Add Executable…" (CLI) picker in v1 or ship the
  running-apps + `.app` picker first.

---

## 12. Appendix — probes run (reproducible)

All probes live under the session temp dir and were compiled with
`xcrun swiftc -swift-version 5 -target arm64-apple-macosx14.0`:

- `peerpid/main.swift` — `LOCAL_PEERPID`/`LOCAL_PEERCRED` on TCP vs UNIX.
- `peerpid/scan.swift` — `libproc` socket→PID scan, correctness + timing.
- `peerpid/bench.swift` — 200 serial/concurrent lookups.
- `peerpid/ident.swift` — `NSRunningApplication` vs enclosing-`.app` bundle ids
  across 77 running apps.
- `peerpid/resp.swift` — `responsibility_get_pid_responsible_for_pid` on
  Chrome/Slack/WebKit helpers.
- `peerpid/respcli.swift` — responsible pid for CLI children.
