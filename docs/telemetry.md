# Telemetry & SQLite

`Sources/Telemetry/TelemetryStore.swift`

Records one `RequestEvent` (scheme/method/host/port/path/route/status/bytes/latency/error) per connection, persists to SQLite, and drives a live SwiftUI feed + aggregate stats.

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
- `setActiveConnections(_:)` is an atomic counter (no main-thread dispatch per connection).

## Storage

- DB at `~/Library/Application Support/ProxyManager/telemetry.sqlite` (WAL, `synchronous=NORMAL`, `cache_size=-8000`).
- `requests` table (per-request rows, indexed on `ts`/`host`/`route`) + `minute_stats` (per-minute per-route aggregates, upserted from an in-memory aggregate).
- Retention: `maybePurge()` runs every 5 min — deletes rows older than `monitor.retentionDays`, then enforces `monitor.maxRows` (delete-oldest via `ORDER BY ts DESC ... OFFSET maxRows`).

## Threading

- `record`/`setActiveConnections` (relay threads) and `flush` (flusher) coordinate via `lock`.
- `@Published recentRequests`/`stats` are only mutated on main (in `applyToUI`).
- SQLite runs on a serial `dbQueue`; query completions hop back to main.

## Memory bounds

- `pending` drained every 100 ms; `dbAccumulator` capped ~2× batch size; `recentRequests` capped at 5000; `liveRequests` bounded by `maxConcurrent` (~256).

## Sharp edges (see `docs/roadmap.md`)

- `recentRequests.removeFirst(...)` is O(n) on main (bounded but worth a ring buffer).
- `minute_stats` upsert runs *after* `COMMIT` (not atomic with `requests`).
- Query SQL uses string interpolation (`rangeSeconds`/`limit` — Ints, no real injection, but prefer binds).
- `purge()` also drops in-flight sessions (their rows are discarded entirely).

## Audit changes (2026-09-15)

- **Use-after-free fixed**: `bindText`/`upsertMinuteStats` bound strings with `SQLITE_STATIC` on a temporary `NSString` whose lifetime ended before `sqlite3_step`. They now pass `SQLITE_TRANSIENT` (SQLite copies immediately).
- `sqlite3_step`/`COMMIT` failures are now logged (no more silent data loss).
- `minute_stats` is now purged alongside `requests` with the retention cutoff.
- `flushNow()` drains buffered events synchronously; `AppModel.shutdownForQuit()` calls it so the last sub-second of telemetry survives a quit.

