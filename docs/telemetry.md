# Telemetry & SQLite

`Sources/Telemetry/TelemetryStore.swift`

Records one `RequestEvent` (scheme/method/host/port/path/route/status/bytes/latency/error, plus the originating **app** when per-app telemetry is on) per connection, persists to SQLite, and drives a live SwiftUI feed + aggregate stats.

## Live sessions (connections appear in the feed while open)

The proxy cannot see inside CONNECT tunnels (TLS passes through), so a connection's end time is unknowable until it closes — often minutes later (keep-alive, SSE). Events are therefore attributed to the connection **start** and shown **live**:

- `beginSession(_:)` (relay thread, once per connection, O(1)) — registers the connection and publishes a live feed row (`@Published liveRequests`) the moment it is established.
- `updateSession(_:bytesIn:bytesOut:)` (relay thread, once per `poll` iteration where bytes moved) — two lock-protected adds; no main-thread work.
- `endSession(_:_:)` (relay thread, once) — removes the live row and finalizes it as a normal completed event (same `UUID`, `ts` = start time, `durationMs` = wall time).
- The 10 Hz flusher snapshots live sessions and republishes rows whose bytes changed or whose duration ticked (≥1 s).
- If a connection begins *and* ends within one flush tick it never appears live (no ghost rows).

## Performance model (off the hot path)

- `record(_:)` / session begin/end are **O(1)**: `NSLock` + append + a `StatsSnapshot` delta. No SQLite, no dispatch, no UI work per request.
- `updateSession` is the only per-iteration telemetry call; it is two locked `Int64` adds per `poll` iteration that moved data (see `docs/performance.md`).
- A single `DispatchSourceTimer` flusher at **10 Hz**:
  - drains completions → publishes `recentRequests` + `stats` on main (one batched update), and
  - republishes `liveRequests` rows that changed.
  - accumulates into `dbAccumulator`; every **1000** rows it flushes to SQLite as **one transaction** using a **prepared statement**.
- `applyToUI` rebuilds each `@Published` collection locally and assigns it **at most once per tick, and only when it actually changed**; a tick with an all-zero delta and an unchanged active count skips the stats block entirely. Combine `@Published` fires `objectWillChange` on every set with no equality check, so the old per-operation writes re-rendered every observer several times per tick.
- `maybePurge` reuses the `nowMs` `flush` already computed instead of calling `Date()` on every 10 Hz tick.
- `setActiveConnections(_:)` is an atomic counter (no main-thread dispatch per connection).

## Observation (who re-renders)

`TelemetryStore` is an `ObservableObject` but is **not** bridged into `AppModel.objectWillChange`. `AppModel` is the environment object for every window — including the retained, offscreen `Settings` scene window — so forwarding the 10 Hz tick there invalidated the whole view tree (views that never show telemetry included) and kept an invisible Settings window re-running `NSHostingView.minSize()`/`sizeThatFits` forever (a steady 10–20% CPU). The Dashboard observes `TelemetryStore` directly (`@EnvironmentObject var telemetry: TelemetryStore`, injected in `DashboardWindowController`); no other view observes it (Settings only calls `telemetry.purge()`).

## Storage

- DB at `~/Library/Application Support/ProxyManager/telemetry.sqlite` (WAL, `synchronous=NORMAL`, `cache_size=-8000`).
- `requests` table (per-request rows, indexed on `ts`/`host`/`route`). Charts aggregate directly from it (`minute_stats` was removed — it was write-only). Columns: `… src_port, app, app_bundle`.
- **Per-app columns + migration**: `app` (display name) and `app_bundle` (bundle id, nullable) were added for per-app telemetry. `CREATE TABLE IF NOT EXISTS` never alters an existing table, so `migrateSchema()` runs `PRAGMA table_info(requests)` and `ALTER TABLE … ADD COLUMN` for any missing column before the prepared `INSERT` is created. Without it, every write on an upgraded install would fail. Regression: `Tests/TelemetryHarness` (fresh DB + a pre-per-app DB with a legacy row).
- The app is recorded only when per-app routing is enabled and `apps.recordInTelemetry` is on (`ProxyRuntimeSettings.recordAppInTelemetry`); otherwise the columns stay NULL and no identity scan runs.
- `topApps(rangeSeconds:limit:completion:)` groups non-empty `app` values for the dashboard's Hosts/Apps breakdown (mirrors `topHosts`).
- Retention: `maybePurge()` runs every 5 min — deletes rows older than `monitor.retentionDays`, then enforces `monitor.maxRows` (delete-oldest via `ORDER BY ts DESC ... OFFSET maxRows`).

## Threading

- `record`/`setActiveConnections` (relay threads) and `flush` (flusher) coordinate via `lock`.
- `@Published recentRequests`/`stats` are only mutated on main (in `applyToUI`), at most once each per tick and only on change.
- SQLite runs on a serial `dbQueue`; query completions hop back to main.

## Memory bounds

- `pending` drained every 100 ms; `dbAccumulator` flushed once it reaches the 1000-row batch size; `recentRequests` capped at 5000; `liveRequests` bounded by the proxy's connection cap (256).

## Sharp edges (see `docs/roadmap.md`)

- `recentRequests.removeFirst(...)` is O(n) on main (bounded but worth a ring buffer).
- `topHosts` interpolates `rangeSeconds`/`limit` into SQL (Ints, no real injection, but prefer binds); `chartSeries` binds its parameters.
- `purge()` also drops in-flight sessions (their rows are discarded entirely).

## Audit changes (2026-09-15)

- **Use-after-free fixed**: `bindText`/`upsertMinuteStats` bound strings with `SQLITE_STATIC` on a temporary `NSString` whose lifetime ended before `sqlite3_step`. They now pass `SQLITE_TRANSIENT` (SQLite copies immediately).
- `sqlite3_step`/`COMMIT` failures are now logged (no more silent data loss).
- Retention purges `requests` with the cutoff; a stale `minute_stats` table is dropped on schema open.
- `flushNow()` drains buffered events synchronously; `AppModel.shutdownForQuit()` calls it so the last sub-second of telemetry survives a quit.

