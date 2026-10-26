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
3. `applyProxy` with `allowAdminPrompt: userInitiated` (helper → direct `networksetup` as user → osascript only for a user-initiated action in an interactive session; otherwise the mutation **defers**). **Rollback never prompts**: failure paths call `restore`/`clearProxy` with `allowAdminPrompt: false`.
4. Write + install shell env (if `injectShellEnv`) and publish GUI env via `launchctl` (if `injectGuiEnv`).
5. `wasOnKey = true`; state → `on` (or `degraded` if the tunnel probe is down).

**On failure, it rolls back.** If the rollback restore succeeds, the snapshot is cleared, the watchdog disarmed, the server stopped, state → `off`. If the rollback **fails**, the snapshot stays on disk, the watchdog stays armed, the listener keeps running (so the machine still has connectivity), and state → `degraded` — the watchdog repairs the dangling proxy when the process exits. The snapshot is never deleted and the watchdog is never disarmed unless a restore actually succeeded.

## Disable

Restore the snapshot (or clear the proxy) with `allowAdminPrompt: userInitiated`, remove env, clear snapshot, `wasOnKey = false`, stop the server, state → `off`. If the restore **fails**, the snapshot and watchdog are retained, the server keeps running, and state → `degraded` (so the user can retry) rather than falsely reporting `off`. A background disable defers instead of prompting.

## Crash recovery & quit

- **Snapshot is persisted to disk** before any change, so a crash can't lose the user's original state.
- **Auto-re-enable on launch**: if `wasOnKey` was true, `scheduleAutoEnableWhenInteractive()` enables with `userInitiated: false` — immediately when `SessionState.isInteractive`, otherwise it sets `pendingAutoEnable` and waits for unlock/wake instead of prompting at login — *loading* the persisted snapshot (never re-capturing the dangling proxy).
- **Intent vs. state**: `routingWasOn` is the user's *intent* ("keep routing on"), not a record of a successful apply. It is written when an enable is attempted and cleared **only** by an explicit turn-off (`setRoutingEnabled(false)` / `disable(userInitiated: true)`) or `revert.sh`. A failed background enable, a rollback, or a failed user-initiated attempt no longer clears it, so a transient failure can't silently flip the user's preference. If the system proxy still points at our port while the intent reads off (lost defaults key, interrupted quit), launch auto-enables again so the machine never talks to a dead listener.
- **Retry**: a failed *background* enable schedules a bounded exponential retry (5 s → 5 min) while the intent is on and the state is off; wake, network change, and unlock also re-run the prompt-free enable path when the intent is on but routing is off. A *user-initiated* failure is surfaced in Settings/menu with **Try Again** instead of retrying behind the user's back.
- **`shutdownForQuit()`** (from `applicationWillTerminate`): runs its whole body on `workQueue.sync`, so it cannot race an in-flight `enable()`/`disable()` (which could otherwise apply the proxy *after* the restore). It restores from the **persisted** snapshot via `restoreWithoutPrompt` / `clearWithoutPrompt` (never `osascript`), and only clears the snapshot / disarms the watchdog when the restore succeeded. It deliberately leaves `wasOnKey` untouched so the next launch re-enables routing if it was on when we quit (only an explicit `disable()` clears `wasOnKey`). If `restoreOnQuit` is off (and the crash watchdog is enabled), or the restore fails, the snapshot and the armed watchdog are **left in place** so the watchdog restores within ms of process exit. If the watchdog is disabled, the quit path always restores regardless of `restoreOnQuit` — otherwise the machine would be left pointing at a dead `127.0.0.1`. It also flushes telemetry (`telemetry.flushNow()`).

### Only deliberate quits terminate

Because this is a menu-bar app whose whole job is to keep the tunnel up, an incidental quit request must **not** kill it. `AppDelegate.applicationShouldTerminate` returns `.terminateNow` only when `AppModel.isTerminationAllowed` is set or the quit came from the system; otherwise it logs, calls `closeFrontWindow()`, and returns `.terminateCancel`.

- **Deliberate (set `isTerminationAllowed`, then terminate)** — the menu-bar status menu's *Quit Proxy Manager*, a **mouse click** on the app-menu *Quit Proxy Manager*, the Settings → General **Quit** button, **Restart** (`restartApp()`), and Sparkle's `willInstallUpdate` (which fires before the installer asks the app to quit).
- **Incidental (cancel, close front window)** — the Dock icon's right-click *Quit*, a stray Apple event, and the **⌘Q** key equivalent. `CommandGroup(replacing: .appTermination)` owns the app-menu Quit item so `AppDelegate.handleQuitCommand()` can tell a click (quit) from ⌘Q (close window) via `NSApp.currentEvent`.
- **System quit (always allowed)** — logout / restart / shutdown, detected from `NSWorkspace.willPowerOffNotification` and the `kAEQuitReason` attribute of the quit Apple Event, so the app never blocks a shutdown.

## Crash watchdog (SIGKILL / force-quit safety net)

`Sources/Support/Watchdog.swift`. The app binary has a second role: `ProxyManager --watchdog` (dispatched in `App.swift` before SwiftUI starts). It runs as a **user LaunchAgent** (`com.proxymanager.watchdog`, `KeepAlive: { SuccessfulExit: false }`, `ProcessType: Background`) installed on first enable — no admin, no signing required.

- **Arm/disarm**: `enable()` arms (`WatchdogController.arm(port:)`) *before* `applyProxy`, so any crash past that point is covered. `disable()`/`shutdownForQuit()` disarm *after* restoring. State is the atomic `watchdog.json` (`{armed,pid,port,updatedAt}`).
- **Detection is event-driven, not polling**: the loop blocks in `kevent` on `EVFILT_PROC`/`NOTE_EXIT` (app death) and `EVFILT_VNODE` on the support dir (arm/disarm), with an adaptive safety tick (15 s armed / 120 s disarmed). Idle CPU is ~0 (verified in the harness).
- **Restore is idempotent and non-destructive**: it acts only when a snapshot exists *and* some service's HTTP(S) proxy points at `127.0.0.1` on the armed port. So it never clobbers a proxy the user set themselves, and a crash mid-disable is a no-op.
- **Privilege**: `SystemProxyManager.restoreWithoutPrompt(snapshot:)` / `clearWithoutPrompt(services:)` — helper XPC only if already registered **and** answering a `ping`, and on any helper error it falls back to `networksetup` directly as the user. It never runs `osascript` (a background process has no UI). On repeated failure it logs after 5 attempts and keeps retrying on the next safety tick (it never disarms while the proxy is still broken); `./revert.sh` remains the manual escape.
- **Reaping**: because it's a launchd job (not a child of the app), it survives `kill -9` of the app and is restarted by launchd if it dies. `revert.sh` boots it out first.
- Toggle: Settings → System → Quit behavior → "Crash watchdog" (`config.system.crashWatchdog`, default on).

## Live config changes

- `commitConfig()` → `syncProxySettings()` (in-memory proxy/routing update) + **debounced** disk save (0.5 s) — not per-keystroke.
- If routing is active and the **bind host/port changed**, a workQueue task rebinds the listener and re-applies the system proxy (`reapplyIfPortChanged`), tracked by `appliedPort`/`appliedBindHost` (workQueue-only). The apply and the rollback both pass `allowAdminPrompt: false`, so a port change while the screen is locked defers rather than prompting. If the rebind or apply fails, it **rolls back** to the last-good listener and system-proxy port.

## Sleep/wake, network change & App Nap

> **App Nap model (2026-10-25):** there is **no session-lifetime activity token**. The app naps while idle and takes a short `.userInitiatedAllowingIdleSystemSleep` token only around a system-proxy mutation (`ActivityController`). Wake/network re-apply is always prompt-free and defers when the session cannot show an authorization dialog. See [`tasks/authd-unlock-deadlock/04-app-nap.md`](tasks/authd-unlock-deadlock/04-app-nap.md).

- **Wake / network change**: `NSWorkspace.didWakeNotification` (after a ~3 s settle delay) and an `NWPathMonitor` path update trigger a prompt-free re-apply on `workQueue` — the listener is restarted if it died, and the system proxy is re-applied to the **current** service list (a service that appeared while asleep otherwise bypasses the proxy). If the state is `off` but `routingWasOn` is set (a failed background enable, a launch that ran while the session was locked), the same event runs the prompt-free enable instead of doing nothing.
- **Session gating**: `SessionState` (`Sources/System/SessionState.swift`) tracks sleep/wake and the console/locked flags. `AppModel` never prompts from a background context:
  - launch auto-enable (`routingWasOn`) waits for `SessionState.isInteractive` (or unlocks) and then enables with `userInitiated: false`;
  - wake (`didWake` + ~3 s settle) / network (`NWPathMonitor`) / port-change re-apply passes `allowAdminPrompt: false`;
  - rollbacks and quit restore are always prompt-free;
  - a deferred mutation (`deferredIntent` + `authorizationDeferred`) is retried prompt-free when the session becomes interactive; the status menu also offers an explicit **Retry** (`retryDeferredApply()`, the only deferred path allowed to prompt);
  - `SessionState` listens for sleep/wake, session activation, and `com.apple.screenIsUnlocked`; while an auto-enable or deferral is pending, `AppModel` also runs a bounded 2 s re-check (never prompting) so a missed unlock notification cannot strand it.
- **App Nap**: there is no session-lifetime token. `ActivityController` (`Sources/Support/ActivityController.swift`) takes one short-lived `.userInitiatedAllowingIdleSystemSleep` token around each system-proxy mutation (`withApplyActivity`) and releases it immediately; `.suddenTerminationDisabled`/`.automaticTerminationDisabled` are not used. A **connection-scoped** token was deliberately **not** added — the dossier requires measuring whether App Nap actually hurts relay latency before paying that cost.
- **Idle cadence**: `TelemetryStore.setFlusherIdle(_:)` drops the flusher from 10 Hz (25 ms leeway) to a 5 s cadence (2 s leeway) when routing is off **and** no window is open; `AppModel.updateTelemetryFlusherMode()` drives it from `state.isActive || AppWindowTracker.shared.hasOpenWindow`. The dashboard's 2 s series timer is a `CoalescedTicker` (25% tolerance) started only while its window is visible.

## Thread-safety notes

- `state`/`config`/`tunnelUp`/`lastError` are `@Published`, mutated on main via `setState`/`setLastError`.
- `snapshot`, `appliedPort`, `appliedBindHost` are workQueue-only.
- `proxyServer.isTunnelUp` reads `tunnelSupervisor.isTunnelUp` (NSLock-guarded), never the `@Published tunnelUp`.

## Don't break these

- Never leave the system proxy set when the proxy isn't running.
- Never re-capture a snapshot while the proxy is dangling (always load persisted).
- Never do admin work on the main thread without a bounded timeout.
- Never let a background path (`allowAdminPrompt: false`) reach `runAdmin`; it must use the helper/direct `networksetup` or defer. See `docs/tasks/authd-unlock-deadlock/AGENTS.md`.
