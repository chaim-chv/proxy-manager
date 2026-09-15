# Roadmap — what's left

Prioritized. Only genuinely-open items are listed; verified against the source.
Durable lessons for the already-fixed bugs live in [`AGENTS.md`](../AGENTS.md)
§"Critical lessons" and [`FINDINGS.md`](../FINDINGS.md).

## 1. Remaining correctness/robustness (medium/low from review)

- **Proxy**: `removeFirst` O(n) buffers → index/ring buffer; `maxConcurrent` is hardcoded (semaphore 256); `inet_addr` fails for hostname `bindHost`; unguarded `Int32(timeout * 1000)` in the relay.
- **Socket**: `sendAll` treats `EAGAIN` as fatal (hazard on non-blocking fd); stale `errno` after `poll`/`SO_ERROR`; `setNonBlocking`/`getsockopt` return codes ignored.
- **SOCKS5**: handshake `SO_RCVTIMEO`/`SO_SNDTIMEO` persist into the plain-HTTP first write (reset after handshake).
- **HTTPParser**: add a header count cap; handle non-UTF8 → deterministic 400; `Host` presence validation.
- **Telemetry**: `recentRequests.removeFirst` O(n); `minute_stats` upsert inside the transaction; check `BEGIN` rc; parameterize query SQL; guard `sqlite3_column_text` NULL.
- **System proxy**: `helperUsable` re-probe after failure; apply `isValidService` on the osascript path.
- **Shell env**: escape/sanitize `bindHost` before writing `env.sh`.
- **Routing**: reject port-bearing patterns; lowercase host in `matches` (which requires a pre-normalized host).
- **Config**: synchronize `config`; timestamped corrupt backups; handle `ensureDirectories` errors.
- **UI**: `suffix(N).reversed()` feed; validate `portBinding` instead of silent clamp.
- **Quit**: `shutdownForQuit()` runs synchronous admin work on the main thread (bounded to 15 s XPC / 180 s osascript); `disable()` is already async.

## 2. Known gaps (from the system-proxy audit)

- **Snapshot only covers services present at enable time.** A service that disappears before disable keeps `127.0.0.1` and reappears with it. A full fix needs persisted per-service cleanup on launch.
- **Helper authorization is PID-based**, not audit-token-based (`Sources/Helper/main.swift`). It is a root-`networksetup` boundary; audit-token validation is the robust form.
- **Single-instance enforcement is absent**; two instances share snapshot/watchdog state.

## 3. Feature gaps

- **Dashboard**: request detail panel, time-range buttons (5m/1h/24h/7d), more charts (RPS, bytes/s, per-host, error ratio).
- **Targets**: import/export JSON, savable presets, drag-to-reorder, pattern validation.
- **Settings**: timeouts/concurrency/buffer controls, PAC mode, open-config-in-Finder, full config import/export.
- **App lock** (Keychain passcode).
- **App icon** + **localization**.

## 4. Tests & CI

- Promote the harnesses (see `docs/testing.md`) to an XCTest target.
- CI: add a test job + SwiftLint.

## 5. Hardening

- ✅ **Crash watchdog** — `Sources/Support/Watchdog.swift`: a `KeepAlive` user LaunchAgent (`ProxyManager --watchdog`) restores the system proxy within ms of the app dying (event-driven `kqueue NOTE_EXIT`, ~0 idle CPU), idempotently and only when the proxy is ours. Covered by `Tests/WatchdogHarness`. Remaining: a signed-build `SMAppService.agent` variant (the classic plist already needs no signing).

## 6. Release

- Developer ID signing (wired via `IDENTITY=`), notarization, Homebrew cask / DMG.
