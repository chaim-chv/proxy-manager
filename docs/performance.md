# Performance & resource footprint

Goal: enabling the tunnel must be **imperceptible** — the user feels no change when it's working.

## Measured baselines (local mock upstream)

- ~**13,700 requests/sec** (12,800 short CONNECT cycles, 128 workers).
- ~**3,400 MB/s** streaming (128 MB, 8 conns × 16 MB).
- 256 concurrent connections complete in <1 s.

## Hot-path rules (do not regress)

1. **Relay streams in 16 KB chunks with backpressure** — never buffer a whole body. Buffers bounded at 256 KB/direction.
2. **Telemetry is O(1) on the hot path** — session begin/end and `record()` are lock+append; the only per-iteration call is `updateSession` (two locked `Int64` adds per poll iteration that moved data). SQLite + UI happen on a 10 Hz flusher (prepared statements, batched transactions). Never add per-request SQLite or `DispatchQueue.main.async`.
3. **Detached threads, not GCD global queue** — GCD caps blocking tasks at ~64 threads; the proxy uses `Thread.detachNewThread` bounded by a 256-permit semaphore.
4. **No per-row allocations on main** — cached formatters; avoid materializing the whole feed every render (`suffix(200).reversed()`).
5. **Only the Dashboard observes telemetry, and publishes are coalesced.** Never bridge `TelemetryStore.objectWillChange` into `AppModel` — `AppModel` is the environment object for every window (including the retained offscreen `Settings` window), so that invalidated the whole view tree at 10 Hz and cost 10–20% CPU while idle. `applyToUI` assigns each `@Published` at most once per tick and only on change.

## Resource footprint

- Threads: ≤ ~256 connection threads (each idle connection held up to `idle` 120 s; half-closed connections reap in ~3 s grace).
- Memory: relay buffers 256 KB/direction; telemetry feed 5000 events; SQLite WAL bounded by retention (`retentionDays`/`maxRows`).

## What to watch when changing the proxy

- Any new per-iteration allocation in `relay`.
- `removeFirst` on large buffers (O(n)).
- Unbounded queues (telemetry `pending`/`dbAccumulator` must stay drained).
- Blocking syscalls on the main thread.

## Verification

Re-run the throughput + streaming + concurrency harness (see `docs/testing.md`) before/after a hot-path change and compare numbers.
