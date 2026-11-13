# Monitoring v2 — five changes, designed and shipped

Follow-up to [`MONITORING-REVIEW.md`](MONITORING-REVIEW.md). Five changes, each covering a
cluster of defects from that review. All are implemented, tested, and captured from the real
app in demo mode.

**Screenshots** (regenerate with
`/private/var/folders/g6/0rklv0v56xv9390wq3vf28hh0000gn/T/opencode/capture-review.sh /tmp/pm-shots-v2`):

| Shot | Shows |
|---|---|
| `dashboard.png` / `dashboard-light.png` | status strip, range-scoped stats, honest chart, new feed columns |
| `targets.png` / `targets-light.png` | per-target health + the coverage warning |
| `failures.png` | failure triage ("38 failed · top: …") |
| `bytes.png` | tunnel-only byte chart |
| `detail.png` | inspector: Connect latency, Open for, Path |
| `apps.png` | tunnel-only app ranking |

---

## 1. The header no longer lies about what it is measuring

**Problem.** Five boxes mixed four process-lifetime counters (`Tunneled`, `Direct`, `Blocked`,
`Bytes`) with one instantaneous value (`Active`), next to a range-selected chart. `Blocked` was 0
in 7 days; `Bytes` was both directions, all routes, since launch; `Active` duplicated
"N live". Nothing said which window any number used, and `Direct` *rose* during a tunnel outage
because fail-open rewrites the route.

**Design.**
- One status line states the three things a routing tool must answer before any number:
  **Routing on/off/degraded · Tunnel up/down · Recording/unavailable**, plus a red pill only
  when something was blocked, and `lastError` inline.
- Four boxes, all **range-scoped and labelled**: `Through tunnel` (with "% of N"),
  `Direct`, `Via tunnel` (bytes that actually crossed the tunnel), `Active` (explicitly "open now").
- The window is stated once, on the right: "Last 24 hours · completed connections".
- Every box has a tooltip defining its unit and window.

**Implementation.**
- `TelemetryStore.rangeStats(rangeSeconds:)` — one `GROUP BY route` query returning counts,
  tunnel bytes, total bytes and failures for the same cutoff the chart uses.
- The 5 m range is computed from the in-memory feed (so it is live); 1 h/24 h/7 d from SQLite on
  the existing cadence (`5 s / 15 s / 60 s`).
- `TopMetric` is unchanged for hosts/apps; `Blocked` moved into the status line.
- `StatBox` gained `detail` + `help`; `StatusPill` is new.

**Why this is the right shape.** The number that proves the app works is not "how many went
through the tunnel" — it is the share, plus the counter-evidence in change 2. A user can now read
one line ("80.5 % of 844 · last 24 h") without forming a wrong mental model about relaunches.

---

## 2. Targets panel: make the target list verifiable, and surface the hole

**Problem.** The only feedback on a target was the one-line preview in Settings. Nothing showed
whether a target carried traffic, and a target-matched host that went **direct** (exact pattern
vs. subdomain) was invisible. In the real DB, target `opencode.ai` was enabled while
`models.opencode.ai` went direct 117 times.

**Design.**
- A third tab in the breakdown card: **Targets · last 24 h** (fixed 24 h, labelled — a 5-minute
  window would report almost every target as idle).
- One row per configured target: green/gray dot, pattern, connections, last seen. `no traffic`
  is rendered as a first-class value, not a blank.
- Footer: `N of M carried traffic` + `App rules: N connections` (tunnels not caused by a target).
- **Coverage warning**: hosts that end with an *exact* target's name but are not matched
  (`models.opencode.ai` under `opencode.ai`) are counted and shown in orange:
  `14 direct under models.opencode.ai — add *.`
- The Apps tab now filters to `route = 'TUNNEL'` too, so both tabs answer the same question.
  Both tabs are labelled "Top tunneled …".

**Implementation.**
- `TelemetryStore.hostActivity(rangeSeconds:)` → `[HostActivity]` (host, total, tunneled,
  latest, bytes). Distinct hosts are hundreds, not rows, so 7 d is still cheap.
- Aggregation in Swift against `config.targets` (`RoutingEngine.matches`), i.e. "would this host
  match today" — the same honesty rule as the inspector's Reason card.
- Loaded on demand (only while the tab is open, 15 s cadence); in-memory fallback so a DB hiccup
  never blanks the panel.
- `RoutingEngine.normalizePattern` made internal (was private) for the suffix check.

**Honest limitation.** The warning is a heuristic for the exact-vs-wildcard mistake; it cannot
know that the user *intended* a subdomain rule. That is why it is phrased as a suggestion, not an
error, and why it is only shown for suffix matches of an existing exact target.

---

## 3. Every per-row signal now means what it says

**Problem.** `Status` was the proxy's own 200 (written before a byte flowed); `Duration` was
connection lifetime (p90 120 s, max 4.2 h) presented as if it were latency; `Error` was
`connect_failed: The operation couldn't be completed. (ProxyManager.SocketError error 0.)` on
28,498 rows because the associated message was dropped.

**Design.**
- **Result** column: `✓` (tunnel established / relayed), `✗` (could not connect), `—` (plain
  HTTP, origin status not visible), `…` (live), each with a tooltip. No fake HTTP code.
- **Connect** column: real latency, accept → upstream established. `—` means "not measured"
  (legacy rows), never "instant".
- **Open** column: connection lifetime, with an hours case (`4.2h`, not `252.1m`).
- Errors are stored as a **stable code** (`connect_failed: dns|timeout|refused|unreachable|
  reset|closed|socks_auth|socks_rejected|socks_timeout`) and rendered as a short sentence in the
  feed and the inspector. Legacy Foundation-boilerplate rows read "Connection failed", never the
  raw text.
- Failure triage under the chart when `Failures` is selected:
  `38 failed connections · top: metrics.vendor.example (27), api.deepseek.com (4)`.
- Failures now carry a real duration (the connect attempt), not 0.
- The inspector shows `Status`, `Connect`, `Downloaded`, `Uploaded`, `Total`, `Open for`, and
  `Path` when recorded. `Source port` (debug trivia) was removed.

**Implementation.**
- `Sources/Support/ErrorText.swift` — classification + one-line descriptions, shared by the
  proxy and the UI. `SocketError`/`SOCKS5Error` conform to `LocalizedError` so the message
  survives anywhere `localizedDescription` is used.
- `RequestEvent.connectMs` + `connect_ms INTEGER` column + idempotent `ALTER TABLE` migration +
  INSERT bind. `ProxyServer` stamps it after `connectUpstream` and on the failure path.
- `TelemetryStore.topFailingHosts(rangeSeconds:)` feeds the triage line.

**Note on the numbers.** `Connect` is a real network round trip (DNS + TCP + SOCKS handshake), so
it is comparable across rows in a way `duration_ms` never was. It is one clock read per
connection — no hot-path cost.

---

## 4. The chart now shows the range it claims to show

**Problem.** Bucket width silently changed 30 s → 2 h with no label; the y axis had no unit;
the x domain was the data's extent, so a quiet period shortened the axis; there was no way to read
a value; the byte area was unstacked so DIRECT (98 %) painted over TUNNEL; the legend always
listed BLOCK; the newest partial bucket looked like a collapse.

**Design.**
- Title + subtitle: `Connections` / `Last 24 hours · 15 min buckets · connections`, and
  `Failures` / `… · connect failures + 4xx/5xx`.
- **X domain pinned** to the selected range, aligned to the bucket grid.
- **Zero-filled** buckets for the routes present, so silence is a visible gap to zero and stacked
  areas return to the baseline correctly.
- **Hover readout**: bucket time + per-route value (counts or bytes).
- **Stacked** areas for bytes; **tunnel-only** bytes (the number the user pays for), with the
  subtitle saying so.
- Legend derived from the data (no permanent BLOCK entry).
- 7 d axis shows month + day (no more "31 1 2" ambiguity).

**Implementation.** `chartWindow`, zero-filled `seriesPoints`, `chartXScale(domain:)`,
`AreaMark(stacking: .standard)`, `.chartOverlay` + `onContinuousHover`, dynamic
`chartForegroundStyleScale(domain:range:)`. The chart loads immediately on appear instead of
waiting for the first 2 s tick.

---

## 5. The feed can answer a question, and destructive actions are gated

**Problem.** Filters ran **after** truncation to the newest 250 rows (≈20 tunnel rows while 1,086
tunnelled in 24 h), there was no sorting at all, `Method` was 97.7 % "CONNECT", `Clear` deleted
the entire database with one click, and "Pause" froze only the feed while its app-filter options
came from live rows.

**Design.**
- Filters and sorting run over the **whole 5,000-row buffer**, then the first 250 matches are
  shown. The header says exactly that: `showing 250 of 1,600 buffered`.
- **Sortable columns** (Time, Route, Host, App, Connect, Bytes, Open, Result, Error) via native
  sort descriptors; sorting happens before the 250-row cut.
- Column budget rebalanced to fit the default window: `Method` (low value) replaced by `Connect`;
  Result/Target/Path vocabulary unified; v3 autosave name so stale layouts cannot hide columns.
- `Delete history…` opens a confirmation that states the scope and that it cannot be undone.
- `Pause` → `Freeze feed` with a tooltip; app-filter options are derived from the frozen snapshot.
- Empty states distinguish "no traffic", "no match in N buffered", and "history unavailable".

**Implementation.** `baseFeedRows` scans the full buffer; `sortedFeedRows` + `@State sortKey/
sortAscending`; `FeedTable` gained `sortDescriptorPrototype`, `sortDescriptorsDidChange`,
`onSort`, and new cells; `confirmationDialog` on the destructive button.

---

## Engine correctness folded in

- **Time-based SQLite flush.** `flush()` now also enqueues when `dbAccumulator` is non-empty and
  1 s has passed since the last write, not only at 1,000 rows. A light user gets 1 h/24 h/7 d
  history (and a crash loses ~1 s, not ~1,000 events). Regression: TelemetryHarness.
- **Failures carry duration/connect time** — a 10 s timeout no longer reads `0ms`.
- **`topApps` is tunnel-only** and gains a deterministic order (was `ORDER BY c DESC` with no
  tiebreak).
- `docs/telemetry.md` and `docs/ui.md` updated for all of the above.

## Tests

`./Tests/run-all.sh` plus the new checks:
- TelemetryHarness: `connect_ms` created/migrated/persisted; `rangeStats` counts/routes/bytes/
  failures; `hostActivity`; `topFailingHosts`; one event reaches SQLite within 2 s without
  `flushNow`; `topApps` excludes direct apps.
- UIHarness: `Format.bytes(0)=="0"`, grouped counts, hours-format duration, `latency(0)=="—"`,
  error vocabulary (codes, legacy boilerplate, fail-open), raw-message classification.
- ProxyE2E: unchanged and passing (the error string change is on the failure path only).

## Deliberately not done

- **Cross-window latency comparison** (tunnel vs direct median). `connect_ms` now makes it
  possible, but a per-host percentile view is a separate feature, not a fix.
- **A "what changed" diary.** The events exist in `AppModel`; it needs its own ring buffer and
  copy, and would have crowded this batch.
- **SQL-backed feed search over 7 days.** The buffer now covers the last 5,000 connections with a
  truthful label; paging the whole database needs its own query path and pagination UI.
- **`recordPaths` default.** Still on by default, now visible in the inspector; query strings are
  still stored verbatim when enabled (documented in `docs/telemetry.md`).
