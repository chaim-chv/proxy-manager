# Internet connectivity monitor

`Sources/System/ConnectivityMonitor.swift`, `Sources/System/ConnectivityState.swift`

The app answers "is the internet actually reachable?" separately from "is the
network link up?". That distinction matters: with a flaky router or ISP the
Wi-Fi stays connected (and `NWPathMonitor` reports `.satisfied`) while every
request fails. The monitor surfaces this live in **Settings → General** and in
the **menu-bar menu**.

## Why an active probe

`NWPathMonitor` is used only as a change hint (re-check when the route list
changes). It cannot detect a dead uplink, because the local link is genuinely
fine. Actual reachability comes from a tiny HTTPS request:

| Order | Endpoint | Success condition | Notes |
|---|---|---|---|
| 1 | `https://captive.apple.com/hotspot-detect.html` | HTTP 200 containing `Success` | Apple's purpose-built captive-portal probe |
| 2 | `https://detectportal.firefox.com/success.txt` | HTTP 200 containing `success` | Mozilla's purpose-built captive-portal probe |

The primary endpoint is enough when online (one request per cycle). The
independent fallback runs only after the primary fails, so one blocked endpoint
does not fake an outage. The body checks reject a captive portal's login page,
which often answers `200`.

Apple and Mozilla run these endpoints specifically for captive-portal detection:
the responses are tiny (8–69 bytes), stable, and carry no identifiers. This is
deliberately more private than probing Google/Cloudflare on every cycle; those
were the original endpoints and are technically fine, but they expose the user's
IP to an ad/analytics company for no benefit. A single operator (Apple) sees the
normal-case probes; the Mozilla fallback only sees traffic during an Apple
failure. Advanced users can turn the whole feature off.

The probe uses `URLSessionConfiguration.ephemeral` with
`connectionProxyDictionary = [:]`. This is required: the app points macOS at
`127.0.0.1:8888` while routing is on, and probing through its own proxy would
make the monitor depend on the thing it is monitoring (and could loop back).

## Cadence and energy

| State | Next probe |
|---|---|
| Online, menu/Settings visible | 5 s |
| Online, background | 20 s |
| Offline | 5 s after the failed cycle |

"Visible" is tracked per surface (status menu open / General pane showing) via
`setVisible(_:surface:)`, so the two cannot clobber each other. Opening the menu
or General also calls `checkNow()`, so the displayed value is fresh immediately
even after App Nap deferred a background probe. Background polling is deliberately
slower: the status is only visible when a surface is open, and `NWPathMonitor`
still triggers an immediate re-check on route changes.

All endpoints time out after 3 s, so an offline cycle (primary + fallback) takes
about 6 s and a recovery is noticed within roughly 10 s.

- No request overlaps another; the next one is scheduled after a cycle
  completes.
- Request timeout 3 s; a hard cycle watchdog (12 s) completes the cycle as a
  failure if URLSession ever fails to call back. Late callbacks from a timed-out
  cycle are ignored (`cycle` identity check), so monitoring can never wedge.
- The monitor publishes only on the main thread and only when a snapshot walks
  forward. It is **not** bridged into `AppModel.objectWillChange`; the status
  menu and the General pane observe `ConnectivityMonitor.shared` directly.

The check traffic is one small HTTPS request every 5–20 s. It is not recorded in
telemetry; probes bypass the proxy entirely.

## Toggle and config

`config.connectivity.enabled` (default **true**, decoded tolerantly) is exposed
as **Settings → General → Internet → Monitor internet status**. Turning it off:

- stops the timer, cancels any in-flight probe, and releases `NWPathMonitor`;
- hides the **Internet** row from the status menu;
- replaces the live status in General with "Off — no checks are sent…".

`AppModel.commitConfig()` calls `ConnectivityMonitor.setEnabled(_:)`, and the
app starts the monitor from `AppModel.init` only when the setting is on. Off is
a real "no traffic" state, not a hidden UI-only preference.

## State model (`ConnectivityState.swift`)

`ConnectivitySnapshot` is pure (no network, no Combine) and regression-tested by
`Tests/ConnectivityHarness`:

- `ConnectivityStatus`: `checking` → `online` / `offline`.
- On failure: `offlineSince` is set on the first failure; repeated failures do
  not count as new drops.
- On recovery within 10 minutes the health is **unstable** (orange), which makes
  the "works for a few minutes, then dies" pattern visible instead of looking
  healthy between drops.
- Drop start times are kept for one hour, so the UI can say "3 drops in the last
  hour".
- `checks` is a bounded ring of the last 60 probe outcomes (the history strip).

## UI surfaces

- **Settings → General → Internet**: a **Monitor internet status** toggle (on by
  default), then a colored dot + status title, one-line detail (latency, outage
  duration, recent drop count), a **Check Now** button, and the recent-checks
  strip (each bar is one probe; newest on the right). With the toggle off, only
  the toggle and an "Off — no checks are sent…" caption are shown.
- **Menu bar menu**: an inert **Internet** status row after **Tunnel**
  (`Online · 38 ms`, `Online · unstable`, `Offline · 2 min`, `Checking…`), with
  the detail text as its tooltip. The row is updated in place while the menu is
  open, and is hidden entirely when the setting is off.

The menu-bar icon itself still reflects routing state, deliberately unchanged:
colorizing/badging it for connectivity would make "it is on" and "the internet
is down" collide.

## Lifecycle

`AppModel.init` starts it alongside the tunnel supervisor (never in demo mode)
only when `config.connectivity.enabled` is true; `commitConfig()` applies toggle
changes live, and `shutdownForQuit()` stops it. Demo/screenshot builds get a
seeded healthy history (`ConnectivityMonitor.seedDemo()`) so no network is
touched.
