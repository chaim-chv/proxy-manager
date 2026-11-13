# Monitoring & telemetry review — what the Dashboard actually shows

**Scope.** The Dashboard (`Sources/UI/DashboardView.swift`, `FeedTable.swift`,
`RequestDetailView.swift`), the data model behind it (`Sources/Telemetry/TelemetryStore.swift`,
`Sources/Proxy/ProxyServer.swift`), and the real 7-day telemetry database on this machine
(`~/Library/Application Support/ProxyManager/telemetry.sqlite`, 172,521 rows, 2026-11-06 11:24 →
2026-11-13 11:06). No code was changed. Numbers marked *measured* came from read-only SQL against
that DB; everything else is cited to source.

**One-line verdict.** The Dashboard is built from a data model that is *sound for performance*
(one event per connection, start-time attribution, batched writes, 10 Hz UI) but *almost never
means what its labels say*. Route, host, app and the live indicator are genuinely useful and
correct. The five stat boxes, `Status`, `Duration`, `Bytes`, `Errors`, `Top apps` and the feed's
filters are either a different quantity than advertised, lifetime-scoped, or unable to answer the
question they invite. The single most valuable number a routing tool could show — *"did anything
that matches a target go the wrong way?"* — is not on screen at all.

---

## 1. The shape of the real data (context for every verdict)

| Fact | Value | Why it matters |
|---|---|---|
| Connection rows / window | 172,521 / 7 days | one row = one accepted TCP connection, not one request |
| DIRECT / TUNNEL / BLOCK | 167,691 (97.2 %) / 4,830 (2.8 %) / **0** | the tool routes a *tiny* exception set; 97 % of the screen is non-events |
| CONNECT / GET / POST | 168,572 (97.7 %) / 1,531 / 2,418 | 97.7 % of "requests" are TLS tunnels carrying an unknown number of requests |
| `status` values | 200 = 140,135; 502 = 29,242 (16.9 %); 0 = 3,144 | not HTTP statuses — see §3.1 |
| `duration_ms` | mean 36 s, p50 286 ms, p90 120 s, max 4 h 12 m | connection lifetime, not latency |
| Bytes | 22.8 GiB down + 2.76 GiB up = 25.6 GiB/wk | 59 % of it is Apple update traffic |
| Hosts | 952 distinct; top host = **42.5 %** of the whole DB | `api.internal.netfree.link` alone is 73,334 rows (a polling tab) |
| Tunnel composition | WhatsApp 2,930 (61 %), **Apple 827 (17 %)**, DeepSeek 532, other 541 | Apple rows arrive via `trustd`/`appstoreagent` app rules, not targets |
| App attribution | 14,267 rows NULL (8.3 %), holding 53.4 % of bytes | missing identity ⟹ no app rule ⟹ DIRECT |
| `path` | empty in **172,521 / 172,521** | this config has `recordPaths:false`; and no UI renders it anyway |

This is the central design tension: **a routing tool's dashboard is necessarily a monitor of
things the user does not care about.** The target list exists precisely to subtract that noise.
Most of the Dashboard does the opposite.

---

## 2. Element-by-element verdict

`Correct` = the number means what its label implies and helps the user. `Wrong meaning` = accurate
data, misleading label. `Useless` = cannot answer any question this app's user has. `Missing` =
would help and is cheap with data already collected.

### 2.1 Top strip (five boxes)

| Element | What it actually is | Verdict |
|---|---|---|
| **Tunneled** | *Connections* finalized since app launch (in-memory; never read from SQLite; reset on relaunch and Clear; incremented only at close, so open tunnels are absent) | **Wrong meaning** — reads as a 24 h/traffic number next to a 24 h chart |
| **Direct** | same, for DIRECT; **includes fail-open fallbacks** (a would-be tunneled connection during a tunnel outage is rewritten to `.direct`) | **Wrong meaning + actively misleading** — rises exactly when routing is broken |
| **Blocked** | same counter; always 0 here (0 BLOCK rows in 7 days, fail-closed off by default) | **Useless** — a red alarm that never fires teaches users to ignore red |
| **Bytes** | since launch, `download + upload` summed, all routes, completed only | **Wrong meaning** — three ambiguities at once (period, direction, scope) |
| **Active** | accepted sockets open now | **Duplicate** — the same number is printed 30 px below as "N live" |

No box has a tooltip or a window label (`StatBox`, `DashboardView.swift:848`), while every other
explanatory surface in the app uses `HelpPopover`. `Format.bytes(0)` renders **"Zero KB"**
(measured), which is the first thing a fresh user sees.

### 2.2 Chart

| Element | Problem | Verdict |
|---|---|---|
| Requests 5 m / 1 h | The one genuinely glanceable view; 30 s / 1 min buckets; route split works | **Keep** (fix units) |
| Requests 24 h / 7 d | Correct data, but at 2.8 % tunnel share the TUNNEL series is a hairline under a DIRECT mountain | **Keep but change** |
| Bytes (all ranges) | Unlabelled bucket width, area mark not stacked (DIRECT paints over TUNNEL), no tunnel/direct split in what matters | **Cut 5 m/1 h/7 d; keep 24 h tunnel-only** |
| Errors | `status >= 400 OR error IS NOT NULL` mixes connect failures, fail-open `tunnel_down`, and policy blocks; 17 % baseline makes "normal" look broken; no failing host | **Keep but redefine** |

Cross-cutting chart defects: the y axis has no unit and the bucket width silently changes
(30 s → 1 min → 15 min → 2 h), so **no two ranges are comparable**; there is no hover readout or
annotation, so the chart is the only element with no exact number behind it; the x domain is the
*data extent*, not the selected range, so a quiet period silently cuts the axis; the newest,
still-filling bucket always looks like a collapse; the legend always lists BLOCK (0 rows).

### 2.3 Top hosts / Top apps

| Element | Problem | Verdict |
|---|---|---|
| **Top tunneled hosts** | Correctly filters `route='TUNNEL'`. But it lists *hosts*, not *targets* — 17 % of the tunnel is Apple infrastructure tunneled by `trustd`/`appstoreagent`, which reads to the user as "my tunnel is leaking Apple traffic". No share %, bars normalised to the leader only. | **Keep, change framing** |
| **Top apps** | **No route filter** (unlike its sibling), counts *connections* not bytes, so it is a ranking of TOTAL traffic: Chrome 112,457 (65 %) then `dataaccessd`, `cloudd`, `nsurlsessiond`. | **Wrong meaning** |
| **"5m" tab** | In-memory path uses `now − 1 hour` plus a 3,000-row scan cap, so the "5m" tab actually covers ~1 h (5.0 h in this sample) while the chart beside it covers 300 s. | **Broken** |

### 2.4 Feed

| Column | What it is | Verdict |
|---|---|---|
| Route chip | TUNNEL / DIRECT / BLOCK | **Best element on the screen** — the app's thesis in one column |
| Host (+port) | CONNECT target / Host header | **Correct** — highest-information column |
| App (icon + name) | libproc identity, ~8 % missing, OS daemons mis-attributed | **Correct when present; blank reads as "unknown app" not "recording off"** |
| Live dot + ticking row | open connection | **Correct and well executed** |
| Time | connection *start* (`HH:mm:ss`, no date) | Correct, but see Duration |
| Method | 97.7 % "CONNECT" | **Low value** |
| Status | 200 = "I, the proxy, opened the tunnel" (before any payload); blank = forwarded HTTP (origin status never parsed); 502 = could not connect | **Wrong meaning** — does not say whether the page loaded |
| Bytes | per connection, both directions summed | **Ambiguous** (no direction, no period, no sort) |
| Duration | accept → close | **Wrong meaning** — "slow request" is unanswerable; a healthy WhatsApp/SSE row reads "12.3m"; the 4.2 h max renders as "252.1m" (no hours case) |
| Error | raw Swift text; 28,498 rows hold one identical unreadable string | **Broken** — the diagnosis was destroyed before storage |

Behavioural defects around the feed:

- **Filters search only the newest 250 completed rows** (`baseFeedRows()` → `suffix(250)`), then
  truncate to 250 again. In this sample that is ~17–46 minutes and **20–22 TUNNEL rows, while
  1,086 tunneled connections happened in the last 24 h**. "Not found" really means "not in the last
  half hour", and nothing says so.
- **No sorting at all** — no `sortDescriptor` on any column, so "slowest/largest" cannot be asked.
- **Pause freezes only the feed** (chart, stats, Top keep moving) and its app-filter options are
  still derived from live rows, so it can render an empty frozen feed.
- **Clear** calls `telemetry.purge()` → `DELETE FROM requests` + `VACUUM`, **with no confirmation**,
  from a header button labelled "Clear".
- Completed rows are selected by *completion* order but sorted by *start* time, so a long
  connection that finishes now lands 30 rows down — or falls out of the 250 entirely.

### 2.5 Inspector

| Element | Verdict |
|---|---|
| **Reason** card (`RoutingEngine.explain`, recomputed from current rules, and it *admits* when the rules changed since the request) | **The best idea in the dashboard** — exactly what a routing tool needs |
| **Options** (change app mode / add-remove target / open Settings) | **Keep** — turns the log into a control surface; three unlabeled glyphs are undiscoverable, and path-keyed rules can't be resolved |
| Copy host | **Keep** |
| Method / Scheme / Host / Port / App / **Source port** | Source port is developer trivia; `path` — recorded by default, and the only field a normal user would want — is **not shown anywhere in the app** |
| Data card | Status "—" when 0 (the table shows blank for the same row — inconsistent), Bytes in/out direction ambiguous ("in" reads as upload, it means download), Duration = lifetime |

The Dashboard also **never shows routing/tunnel state**. Every other surface does (menu bar,
Settings → General). A monitoring window whose owner cannot see "tunnel down / degraded" is missing
the one thing the app exists to protect.

---

## 3. What is shown correctly (keep, and build on it)

1. **Route decision per connection.** The chip, the route filter, the colour split in the chart.
   This is the product. It is accurate, cheap, and instantly explains any row.
2. **Host + port.** Clean data (952 normalised hosts, no case/port/trailing-dot problems), with
   immediate truncation tooltips. The host filter is the right tool for "why isn't X routed?".
3. **App attribution** (when it resolves). It is the only way to explain a tunnel the user did not
   ask for — e.g. `trustd` → `ocsp2.apple.com`. The per-app filter menu is well built (options
   derived from the visible feed, icons, counts).
4. **Live connections.** Rows appear at establish, tick bytes/duration at 10 Hz, and move to the
   completed list without identity churn. The orange dot answers "is my stream alive?" at a glance.
5. **The inspector's Reason + Options.** Honest, actionable, and the only place where the app
   says *why*.
6. **The 1 h Requests chart.** The best "did my last change take effect?" view.
7. **Top tunneled hosts' scope.** It is honestly tunnel-only (the *only* panel that is), which is
   why it escapes the noise problem. It needs a better *unit* (targets, not hosts), not a
   different filter.
8. **Error translation where it exists.** `RequestDetailView` already turns `tunnel_down` and
   `blocked_private_destination` into plain language. The same idea simply hasn't been applied to
   the feed or to `connect_failed`.

---

## 4. What is wrong (grouped by cause)

### 4.1 Semantics — the number is real, the label lies

- **"Requests" are connections.** One event per accepted socket; a keep-alive/h2 tunnel carrying
  hundreds of exchanges is one row. "Tunneled 4,830" / "Request rate" / "N completed" are all
  connection counts. `api.whatsapp.net` alone is 2,318 of the 4,830 tunneled rows.
- **`Status` is the proxy's verdict, not the server's.** CONNECT writes `200` before a byte flows;
  forwarded HTTP writes `0` (rendered blank); no origin 4xx/5xx can ever appear. The most common
  value on screen (81 % of rows) says nothing about the outcome.
- **`Duration` is connection lifetime.** p50 286 ms → p90 120 s → max 4.2 h; 23.5 % of rows exceed
  30 s; all 29,354 failures are exactly `0ms` (a 10 s connect timeout displays as "0ms"). README
  advertises "latency" — nothing records latency.
- **`Bytes` has no direction, period, or scope** in the UI, and the stat box and the chart's Bytes
  metric are guaranteed to disagree (session vs range; both directions summed).
- **`Errors` is three different things** (connect failures, fail-open fallbacks that *succeeded*,
  and policy blocks) under one word, with a 17 % baseline.
- **`Tunneled`/`Direct`/`Blocked` are process-lifetime**, next to a range-selected chart; the TUNNEL
  box can read anywhere from 0 to 4,830 depending only on when the app was last launched.
- **`Direct` is polluted by fail-open.** During a tunnel outage the connection is recorded as
  DIRECT with `error = "tunnel_down"` and `status = 200` — so the strip shows *more direct traffic*
  and a *green status*, i.e. the exact opposite of the failure.

### 4.2 Data that cannot be trusted

- **Error text is destroyed.** `SocketError`/`SOCKS5Error` don't conform to `LocalizedError`, so
  `error.localizedDescription` yields `"connect_failed: The operation couldn't be completed.
  (ProxyManager.SocketError error 0.)"` — **28,498 identical rows (16.5 % of the DB)**. DNS
  failure, timeout, refused, client abort: all indistinguishable. The same 80-character string is
  printed verbatim in the feed and the inspector.
  This also makes the most alarming number in the data undiagnosable: 40–57 % connect-failure rates
  for `ssl.gstatic.com` (40.4 %), `gateway.icloud.com` (40.5 %), `one.one.one.one` (40.9 %),
  `netfree.link` (47.5 %).
- **Per-target routing has a silent hole.** Targets are exact unless written `*.example.com`.
  This machine has target `opencode.ai`, and `models.opencode.ai` went **DIRECT 117 times**
  (93×200, 24×502) because an exact pattern does not match a subdomain (`RoutingEngine.decide`).
  Nothing on the Dashboard surfaces a target-matched host that went direct — the single most
  important counter-evidence a routing tool can show.
- **Light users get empty history.** `flush()` enqueues SQLite batches only when
  `dbAccumulator.count >= 1000` (or a retry is due); there is no time-based flush. A user doing
  ~200 requests/hour sees a working 5 m chart and an **empty 1 h/24 h/7 d chart** until 1,000 events
  accumulate or the app quits. The same mechanism loses the last <1,000 events on a crash.
- **`path` is write-only.** `recordPaths` exists in Settings, the column is written, and no UI
  renders it — not the feed, not the inspector. (This config has it off, so all 172,521 rows are
  `''`.) Turning it on stores query strings (`?token=…`) in plaintext with no consumer and no warning.
- **Purge drops in-flight connections' rows and bytes** (`endSession` skips `appendCompletion`
  once the session is gone), while "Active" is deliberately preserved — you can get "Active 3" with
  an empty feed.
- **App attribution misses exactly the traffic the app could not identify** (8.3 % NULL, 18.5 % of
  failures), and `/usr/libexec` daemons bypass the responsible-process upgrade, so 13,940 rows are
  attributed to `dataaccessd`/`cloudd`/`nsurlsessiond` instead of Mail/Photos/iCloud.

### 4.3 Presentation defects that make correct data unusable

- Feed filters run **after** truncation to the newest 250 (see §2.4).
- No sorting; the Time column has no date; the inspector shows no timestamp.
- Chart: no unit, no bucket-size label, no zero-fill, domain not pinned to the range, no hover
  readout, unstacked area, always-on BLOCK legend.
- "5m" Top card is a 1 h window (and `suffix(2000)` can silently cut a burst from the 5 m chart).
- `Clear` is destructive with no confirmation; `Pause` pauses only part of the screen.
- Empty states are one message for four situations (no traffic / routing off / DB unavailable /
  filter miss). Post-relaunch is the default first impression even with 7 days of history.
- No thousands separators; `Zero KB`; duration stops at minutes ("252.1m").
- Colour semantics are inconsistent (Direct is gray in the box, blue in the chart, gray in the chip;
  green = "good" for tunneled, red = "bad" for blocking, which is the policy working).

---

## 5. What is not needed (cut list)

| Cut | Why |
|---|---|
| **Blocked** box | 0 rows in 7 days; fail-closed is off by default. Show only when > 0, labelled "(fail-closed)". |
| **Active** box | exact duplicate of "N live" in the feed header. |
| **Bytes chart for 5 m / 1 h / 7 d** | five minutes of bytes is noise; 7 days tracks browsing, not tunnel cost. Keep one "bytes through tunnel, 24 h" figure. |
| **Errors chart for 7 d** | dominated by hosts the user cannot fix (`api.internal.netfree.link` 6,711 failures); trains people to stop looking. |
| **Method column** | 97.7 % CONNECT. Fold into the inspector. |
| **Source port** in the inspector | ephemeral, 16,382 distinct values, no user question. Replace with Path. |
| **BLOCK series/legend** in the chart | always absent in practice; derive the legend from the data. |
| **`recordPaths` toggle as-is** | writes a field nobody can see (and stores query strings). Show `path`, or remove the toggle. |
| **5,000-row in-memory feed with 250 displayed** | 4,750 rows are only used by the 5 m chart's `suffix(2000)`; the O(n) trim runs on main. Consider a ring buffer or a smaller cap. |

---

## 6. What is missing (ranked, all cheap and derived from existing data)

1. **Routing/tunnel status line on the Dashboard.** "Routing ON · tunnel up · recording" with the
   same Degraded/error state the menu bar already has. Today the window looks identical whether
   routing is on, off, degraded, or failing.
2. **Per-target health.** One row per target: connections in 24 h (0 is the interesting value),
   last matched, last failure. Answers "is each thing on my list actually going through the
   tunnel?" — the only view that makes the target list verifiable. Same `GROUP BY host` scan as
   `topHosts`, matched against current rules in Swift.
3. **Counter-evidence: "went direct but matched a target".** Should normally be 0; when it is not,
   it is the bug. Would have caught the `opencode.ai` / `models.opencode.ai` hole (117 direct) on
   day one. Requires stamping the matched rule (or cause) on the event at decision time — one
   string per connection, no hot-path cost — rather than recomputing from current rules.
4. **Failed-connect rate + top failing host, split tunnel/direct.** 16.9 % of all connections are
   502s and one hour spikes to ~30 %; today this is one undifferentiated red bar with no cause.
5. **A ~20-line "what changed" diary.** Rules edited, routing started/stopped, tunnel down/up,
   fail-open fallback. The 134 `tunnel_down` rows currently look like ordinary DIRECT rows.
6. **Real latency, if latency is wanted.** Record time-to-upstream-established (one `Date()`,
   zero per-chunk cost) and show median connect time tunneled vs direct per host. Until then the
   README's "latency" claim cannot be honoured — do not show a substitute.

Explicitly **not** recommended: per-target byte time series (nobody bills per target; a single SSE
stream dominates any window), and a "sparkline latency comparison" built on the current
`duration_ms`.

---

## 7. Prioritised plan

### P0 — correctness (small, mostly label/format/dialog changes)

| # | Change | Effort |
|---|---|---|
| 1 | `LocalizedError` on `SocketError`/`SOCKS5Error` (or carry the message), and map the known strings to plain language in the feed + inspector | S |
| 2 | Feed filters must query SQLite for the filtered window, or the feed must state "showing newest 250 · filters apply to these" | M |
| 3 | Confirm + relabel `Clear` → "Delete history…" with the row count | S |
| 4 | Give the stat boxes a window, or derive them from the selected range; drop `Blocked` unless > 0; drop `Active` (already in the feed header) | S |
| 5 | Make the 5 m Top card honour 300 s (and drop the 3,000-row cap dependence) | S |
| 6 | Rename/clarify: "Requests" → "Connections"; `Status` → "Connect" (✓ / — / ✗); `Duration` → "Lifetime"; Bytes → "Downloaded + uploaded" with a hover | S |
| 7 | Chart: pin x domain to the range, zero-fill buckets, label the bucket size / per-second rate, add a hover readout, stack the byte areas | M |
| 8 | Time-based DB flush (e.g. 1 Hz if the accumulator is non-empty, or a 200-row threshold) so light users get history and crashes lose seconds, not thousands of rows | S |
| 9 | Do not drop in-flight sessions on purge | S |

### P1 — make the dashboard answer the user's actual question

| # | Change | Effort |
|---|---|---|
| 10 | Status line at the top (routing / tunnel / recording), reusing `AppModel` state | S |
| 11 | Per-target health panel (count 24 h, last matched, last failure) | M |
| 12 | Stamp the matched rule/cause on each event; add the "direct but matched a target" signal | M |
| 13 | Failed-connect rate + top failing host, split tunnel/direct, clickable to filter the feed | M |
| 14 | Route-filter `Top apps` (or label both tabs with their scope); count bytes as well as connections | S |
| 15 | Default the feed to "tunneled" (or "matched a target") instead of "All" for a routing tool | S |
| 16 | "Freeze feed" in the feed header (and fix its app-filter source), so it does not read as a global pause | S |

### P2 — depth

| # | Change | Effort |
|---|---|---|
| 17 | "What changed" diary (~20 in-memory lines above the chart) | M |
| 18 | Sortable, SQL-backed, paged feed (sort must be server-side or it inherits the 250-row trap) | L |
| 19 | Sortable/`path`-showing inspector, replacing Source port | S |
| 20 | Responsible-process attribution for `/usr/libexec` daemons | M |
| 21 | Storage: drop `idx_requests_route` and the redundant `idx_requests_ts` (≈5.8 MB, 15 % of the file); retention has never actually run on this DB | S |

---

## 8. Appendix — field semantics (the table the schema doesn't give you)

| Field | Actually means |
|---|---|
| `ts` | connection **start** (wall clock at accept); the row is inserted at close, so 28.7 % of rows arrive out of order |
| `scheme` | `https` for every CONNECT (even `CONNECT host:80`); derived from method — one bit of information with `method` |
| `method` | CONNECT for 97.7 % of rows; tunnelled requests are unknowable |
| `host` / `port` | CONNECT target / absolute-URL host / `Host:` header; 111 empty-host rows from malformed CONNECTs; 24 unbracketed IPv6 literals |
| `path` | empty here (setting off); would be `host:port` for CONNECT and path **+ query string** for plain HTTP; never displayed |
| `route` | TUNNEL / DIRECT / BLOCK; fail-open rewrites a would-be tunnel to **DIRECT** |
| `status` | CONNECT 200 written before any payload; plain HTTP 0; failures 502/400/403; never the origin's status |
| `bytes_in` | upstream→client (**download**), stream bytes, TLS overhead included, request head excluded, counted at `recv` |
| `bytes_out` | client→upstream (**upload**), excludes the request head and coalesced first chunk |
| `duration_ms` | accept → relay exit (monotonic); **0 on every failure**; a relay idle timeout is recorded as a success with no error |
| `error` | 5 literal strings; 2 are type-leak junk that erased the cause |
| `src_port` | client's ephemeral port; app-attribution join key, not an identifier |
| `app` / `app_bundle` | responsible app display name / bundle id; NULL 8.3 % / 21 %; missing identity ⟹ default route |

### Verified vs inferred

Verified by me directly in code/SQL: all counts and distributions above; `decide` exact-vs-wildcard
matching; `flush()`'s 1000-row condition; `purge()`'s DELETE+VACUUM and absence of a confirmation;
the absence of `sortDescriptor`; `topHosts` TUNNEL filter vs `topApps` no filter; `chartSeries`'s
error predicate and non-zero-filled buckets; fail-open rewriting the route; `recordPaths` default
true vs this config's false; the inspector's lack of `path`.

Inferred (marked, not measured): exact pixel overflow of the feed header at the 860 pt minimum;
whether SwiftUI Charts draws a missing bucket as a gap or stretches neighbours; the current
process's uptime (so the "since launch" stat values are illustrative, not exact); the cost of an
`AppResolver` scan; that a light user's 1 h chart is empty (from the flush condition, not observed).

Not determined: why 17 % of connections fail (the error detail was destroyed before storage);
whether blocked rows would persist correctly (none exist); the first real retention purge (this DB
has zero id holes, so retention has never deleted a row — it starts the day after this sample).
