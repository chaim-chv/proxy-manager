# Request detail — routing "what / why / change" UI plan

> **Status: IMPLEMENTED.** Covers the Dashboard request inspector
> (`Sources/UI/RequestDetailView.swift`): showing the app, **what** route the
> request took, **why** it took it, and quick ways to **change** it — alongside
> the existing target add/remove/reveal controls.
>
> **Decisions taken:** (1) the "why" is **recomputed from the current rules**
> (`RoutingEngine.explain`) and clearly framed as current config — when the
> current rules would now route the request differently it says so instead of
> claiming the historical cause; tunnel-down/blocked reasons come from the
> recorded error. No telemetry schema change. (2) **Minimal layout**: the route
> badge plus small icon actions, with the plain-language reason on hover.

## 1. Fixed regardless (small, unambiguous)

- **App icon + bundle id in the detail.** The "App" row shows the app icon
  (via the shared `AppIcon` cache; `app.dashed` placeholder for bundle-less
  processes), the name, and the bundle id (secondary text, also as tooltip).
- **Instant "open in Settings" for the app** — a small gear/`arrow.up.forward`
  icon next to the app that opens Settings → Apps (revealing the rule if one
  exists, otherwise opening the Apps page).

## 2. The "why" — where does it come from?

Today `RequestEvent` stores only the final `route`. To explain *why*, the proxy
must record the deciding factor at decision time.

### Option A — record the real reason per request (recommended)
- `RoutingEngine` returns a `RouteDecision { route, reason, matched }`:
  - `reason`: `appTunnel`, `appDirect`, `appDefaultTunnel`, `appDefaultDirect`,
    `targetExact`, `targetWildcard`, `noMatch`, `tunnelDown`, `blockedPrivate`.
  - `matched`: the target pattern (`*.example.com`) or app key
    (`com.google.Chrome`) that decided it.
- Thread `reason` + `matched` into `RequestEvent` and two new SQLite columns
  (`decision_reason`, `decision_matched`) via the existing guarded migration.
- Pros: accurate for history; the inspector renders the reason text directly.
- Cons: touches `RoutingEngine`, `ProxyServer`, `RequestEvent`, the DB, and the
  regression/telemetry harnesses (moderate).

### Option B — recompute from current config on inspect
- On selecting a request, run `routingEngine.explain(host:app:)` against the
  current rules and render that.
- Pros: no schema/model change.
- Cons: shows why it would route *now*, which can differ from what actually
  happened (config edits, tunnel-down fallback can't be reconstructed).

### Option C — hybrid
- Record a compact reason code (cheap) and enrich app context from current
  config at render time (e.g. "Chrome → uses target rules").

## 3. The "what / why / change" card — layout options

The Routing card already has: a route chip and a target button (add / remove /
reveal wildcard). The redesign folds the app into it.

### Option 1 — one compact line + inline actions (recommended)
```
Decision   [ TUNNELED ]   Chrome · Tunnel all            [Change ▾] [⚙]
```
- `Because` is a short chip + text: "Chrome · Tunnel all", "Targets · wildcard
  *.example.com", "Targets · exact api.example.com", "No rule → direct",
  "Tunnel down → direct", "Blocked · private destination".
- `[Change ▾]` is a small menu with context-aware actions (see §4).
- `[⚙]` opens Settings → Apps for the app.

### Option 2 — three labeled mini-rows
```
Decision   [ TUNNELED ]
Because    Chrome → Tunnel all                              [⚙]
Change     [App mode ▾]   [Add target]  [Open Targets]
```
More explicit and discoverable, slightly taller.

### Option 3 — minimal
- Keep the badge; put the reason and actions in a hover tooltip/popover only.
- Least intrusive, least discoverable.

## 4. Quick-change actions (context-aware)

| Situation | Inline actions |
|---|---|
| App rule decided (Tunnel all / Direct all) | **App mode** menu (Tunnel all / Use target rules / Direct all) · Open app settings |
| App rule = Use target rules, matched a target | Existing target remove/reveal · Open app settings |
| Matched an exact target | **Remove target** · Open app settings |
| Matched a wildcard target | **Reveal in Targets** · Open app settings |
| No rule (direct by default) | **Add host to targets** · **Route this app** (menu) |
| Tunnel down (fail-open) | Show a warning chip; the same actions |
| Blocked (private / fail-closed) | Show the reason; no change action |

All actions are small icon buttons with hover tooltips (the existing
`hoverTooltip` / `HelpPopover` patterns), reusing `AppModel.addTarget`,
`removeTarget`, `revealTargetInSettings`, `upsertAppRule`, `revealAppInSettings`.

## 5. Running-apps picker fixes

- **Click the whole "System & Background" header to expand/collapse** (not just
  the disclosure triangle) — replace `DisclosureGroup` with a button header.
- **Toggle add/remove**: clicking a configured row removes its rule again
  (checkmark → click to undo), so you can decide *not* to add an app.
- **Discoverability**: always show every section header with a count (even when
  empty, greyed), plus a `?` help popover explaining the categories and why
  "With Windows" is first. Optionally add category filter chips.
- **Explanation**: one plain sentence per category (in the help popover and as
  the header tooltip).

## 6. Files

- `Sources/UI/RequestDetailView.swift` — the redesigned Routing card + App row.
- `Sources/Routing/RoutingEngine.swift` — `RouteDecision`/reason (Option A).
- `Sources/Proxy/ProxyServer.swift`, `Sources/Telemetry/TelemetryStore.swift` —
  record reason/matched (Option A) + migration.
- `Sources/UI/RunningAppsPicker.swift` — picker fixes.
- Tests: `RegressionHarness` (reason precedence), `TelemetryHarness`
  (columns/migration), `ProxyE2E` (recorded reason).
