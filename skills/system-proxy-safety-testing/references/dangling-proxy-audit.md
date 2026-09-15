# Dangling-proxy failure inventory

Verified against the source. Every entry is a way the machine could be left with
a dead `127.0.0.1` proxy. Use this as the regression checklist.

> **Status:** the Critical and High entries below were fixed. They remain here as
> the invariant checklist: if a change reintroduces any of these, it is a
> regression. Entries marked **[remaining]** are still open.

## Critical (FIXED)

- **PAC `(null)` made helper restore a silent no-op.** `captureSnapshot` stored
  the literal `"(null)"`; `isValid` rejected it; `HelperService.restoreProxy`
  dropped the service; `run([])` returned **success**. Now normalized to "no
  PAC", validated per field, and an empty restore is a failure.
- **`enable()` rollback swallowed failure then destroyed recovery state.** Now
  only clears snapshot/disarms/stops after a successful restore; otherwise keeps
  the snapshot, the armed watchdog, and the listener (state `.degraded`).
- **`shutdownForQuit()` swallowed failure then destroyed recovery state.** Same
  fix: clear only on success.
- **`restoreOnQuit == false` guaranteed a dangling proxy.** Now leaves the
  snapshot and armed watchdog so the watchdog restores after exit.
- **Quit-mid-`enable()` race.** `shutdownForQuit()` now runs on `workQueue.sync`.
- **Helper apply timeout lands after rollback.** (Still possible in principle;
  the app no longer destroys recovery state on a failed restore, so the watchdog
  covers it.) **[remaining: no request cancellation]**

## High (FIXED)

- **`reapplyIfPortChanged` has no rollback.** Now reverts to the last-good
  listener + system-proxy port.
- **Bypass domains overwritten, never restored.** Now captured/restored.
- **`isValidService` rejects `/`.** Now allowed.
- **Watchdog install failure latched; watchdog gave up after 5 attempts.** Now
  latches only on success and never disarms on failure.
- **Watchdog clobbered a user's localhost proxy on any port.** Now matches the
  configured port (0 = any, legacy).
- **No sleep/wake or network-change handling.** Now re-applies on wake/network
  change.
- **`revert.sh` left the snapshot and clobbered PAC.** Now removes the snapshot
  and leaves PAC alone.
- **`runAdmin` temp-file TOCTOU.** Now passes the escaped command inline.

## Remaining

- **Snapshot covers only services present at enable time.** A service that
  disappears before disable keeps `127.0.0.1` and reappears with it. Needs
  persisted per-service cleanup on launch. **[remaining]**
- **Helper authorization is PID-based**, not audit-token-based. **[remaining]**
- **Quit does synchronous admin work on the main thread** (bounded). **[remaining]**
- **No single-instance enforcement.** **[remaining]**
- `runDirect`/helper `runOne` now have bounded waits; the osascript fallback is
  still bounded at 180 s.

## Quick manual recovery

```bash
./revert.sh          # boots out the watchdog, clears proxy, removes env + snapshot, clears flag
```

If `revert.sh` is unavailable, manually:
`networksetup -setwebproxystate "Wi-Fi" off` and
`networksetup -setsecurewebproxystate "Wi-Fi" off` for each service.

