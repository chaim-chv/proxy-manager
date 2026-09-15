# App state machine & lifecycle

`Sources/AppModel.swift` (+ `Sources/App.swift` AppDelegate)

## States

```
OFF ──enable──▶ STARTING ──proxy up + system applied──▶ ON (tunnel up)
                                                          │ tunnel lost
                                                          ▼
                                                      DEGRADED (fail-open/closed)
                                                          │ tunnel recovered
                                                          ▼
                                                          ON
OFF ◀──disable/stop── STOPPING ◀──────────────────────────┘
```

`isActive` = `on | degraded`. Toggle during `starting`/`stopping` is ignored.

## Enable

Runs on a background `workQueue`:

1. Start the proxy server.
2. Load the persisted snapshot (crash recovery) **or** capture + persist the user's original proxy state.
3. `applyProxy` (helper → direct `networksetup` as user → osascript).
4. Write + install shell env (if `injectShellEnv`).
5. `wasOnKey = true`; state → `on` (or `degraded` if the tunnel probe is down).

**On failure, it rolls back.** If the rollback restore succeeds, the snapshot is cleared, the watchdog disarmed, the server stopped, state → `off`. If the rollback **fails**, the snapshot stays on disk, the watchdog stays armed, the listener keeps running (so the machine still has connectivity), and state → `degraded` — the watchdog repairs the dangling proxy when the process exits. The snapshot is never deleted and the watchdog is never disarmed unless a restore actually succeeded.

## Disable

Restore the snapshot (or clear the proxy), remove env, clear snapshot, `wasOnKey = false`, stop the server, state → `off`. If the restore **fails**, the snapshot and watchdog are retained, the server keeps running, and state → `degraded` (so the user can retry) rather than falsely reporting `off`.

## Crash recovery & quit

- **Snapshot is persisted to disk** before any change, so a crash can't lose the user's original state.
- **Auto-re-enable on launch**: if `wasOnKey` was true, `enable()` runs ~0.5 s after launch, *loading* the persisted snapshot (never re-capturing the dangling proxy).
- **`shutdownForQuit()`** (from `applicationWillTerminate`): runs its whole body on `workQueue.sync`, so it cannot race an in-flight `enable()`/`disable()` (which could otherwise apply the proxy *after* the restore). It restores from the **persisted** snapshot and only clears the snapshot / disarms the watchdog / clears `wasOnKey` when the restore succeeded. If `restoreOnQuit` is off, or the restore fails, the snapshot and the armed watchdog are **left in place** so the watchdog restores within ms of process exit. It also flushes telemetry (`telemetry.flushNow()`).

## Crash watchdog (SIGKILL / force-quit safety net)

`Sources/Support/Watchdog.swift`. The app binary has a second role: `ProxyManager --watchdog` (dispatched in `App.swift` before SwiftUI starts). It runs as a **user LaunchAgent** (`com.proxymanager.watchdog`, `KeepAlive`) installed on first enable — no admin, no signing required.

- **Arm/disarm**: `enable()` arms (`WatchdogController.arm(port:)`) *before* `applyProxy`, so any crash past that point is covered. `disable()`/`shutdownForQuit()` disarm *after* restoring. State is the atomic `watchdog.json` (`{armed,pid,port,updatedAt}`).
- **Detection is event-driven, not polling**: the loop blocks in `kevent` on `EVFILT_PROC`/`NOTE_EXIT` (app death) and `EVFILT_VNODE` on the support dir (arm/disarm), with an adaptive safety tick (15 s armed / 120 s disarmed). Idle CPU is ~0 (verified in the harness).
- **Restore is idempotent and non-destructive**: it acts only when a snapshot exists *and* some service's HTTP(S) proxy points at `127.0.0.1` on the armed port. So it never clobbers a proxy the user set themselves, and a crash mid-disable is a no-op.
- **Privilege**: `SystemProxyManager.restoreWithoutPrompt(snapshot:)` — helper XPC if already registered, else `networksetup` directly as the user. It never runs `osascript` (a background process has no UI). On repeated failure it logs after 5 attempts and keeps retrying on the next safety tick (it never disarms while the proxy is still broken); `./revert.sh` remains the manual escape.
- **Reaping**: because it's a launchd job (not a child of the app), it survives `kill -9` of the app and is restarted by launchd if it dies. `revert.sh` boots it out first.
- Toggle: Settings → System → Quit behavior → "Crash watchdog" (`config.system.crashWatchdog`, default on).

## Live config changes

- `commitConfig()` → `syncProxySettings()` (in-memory proxy/routing update) + **debounced** disk save (0.5 s) — not per-keystroke.
- If routing is active and the **bind host/port changed**, a workQueue task rebinds the listener and re-applies the system proxy (`reapplyIfPortChanged`), tracked by `appliedPort`/`appliedBindHost` (workQueue-only). If the rebind or apply fails, it **rolls back** to the last-good listener and system-proxy port.

## Sleep/wake, network change & App Nap

- **Wake / network change**: `NSWorkspace.didWakeNotification` and an `NWPathMonitor` trigger a re-apply on `workQueue` — the listener is restarted if it died, and the system proxy is re-applied to the **current** service list (a service that appeared while asleep otherwise bypasses the proxy).
- **App Nap**: while routing is active the app holds a `ProcessInfo.beginActivity(.userInitiatedAllowingIdleSystemSleep, .suddenTerminationDisabled, .automaticTerminationDisabled)` token (released on disable), so macOS cannot nap the menu-bar process and stall the relay/timers.

## Thread-safety notes

- `state`/`config`/`tunnelUp`/`lastError` are `@Published`, mutated on main via `setState`/`setLastError`.
- `snapshot`, `appliedPort`, `appliedBindHost` are workQueue-only.
- `proxyServer.isTunnelUp` reads `tunnelSupervisor.isTunnelUp` (NSLock-guarded), never the `@Published tunnelUp`.

## Don't break these

- Never leave the system proxy set when the proxy isn't running.
- Never re-capture a snapshot while the proxy is dangling (always load persisted).
- Never do admin work on the main thread without a bounded timeout.
