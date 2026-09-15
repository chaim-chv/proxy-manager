---
name: system-proxy-safety-testing
description: Safely develop, test, or debug the ProxyManager system-proxy, crash-watchdog, shell-env, and privileged-helper code paths without leaving the user's Mac with no internet. Use this whenever you touch Sources/System/, Sources/Support/Watchdog.swift, Sources/Helper/, Sources/AppModel.swift enable/disable/shutdown, revert.sh, or any code that calls networksetup or applies/restores the system proxy. Also use when investigating "internet died after using ProxyManager", a dangling 127.0.0.1 proxy, a watchdog that did not restore, or a snapshot/rollback failure.
---

# System-proxy safety testing (ProxyManager)

The single worst failure mode in this project is **leaving the macOS system proxy
pointed at `127.0.0.1:<port>` after the listener is gone**. That breaks the whole
machine's internet. Every change to the proxy-apply/restore path must be tested
without actually risking that. This skill is the safe procedure and the checklist
of paths that must all be covered.

## Golden rules

1. **Never mutate the real system proxy in a unit harness.** The only harness
   that touches `networksetup` is `Tests/WatchdogHarness`, and it uses *fake
   hooks* plus isolated directories.
2. **Isolate every filesystem path.** Set `PROXYMANAGER_SUPPORT_DIR` (snapshot +
   `watchdog.json`) and `PROXYMANAGER_LAUNCHAGENTS_DIR` (plist) to temp dirs.
   Never let a test read/write `~/Library/Application Support/ProxyManager` or
   `~/Library/LaunchAgents`.
3. **Snapshot is the recovery contract.** The original proxy state must be
   persisted to disk *before* applying, and must only be deleted after a restore
   that actually succeeded. A failed restore must leave the snapshot and the
   watchdog armed.
4. **`revert.sh` is the lifeline.** Any change to system-proxy logic must keep
   `./revert.sh` able to restore internet (see `docs/app-model-lifecycle.md`).
5. **`applicationWillTerminate` runs on the main thread.** It must not block on
   an unbounded `networksetup`/`osascript` call (the admin fallback waits up to
   180 s). Admin work belongs on a background queue with a bounded timeout.

## Run the watchdog harness

```bash
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx14.0 \
  -framework AppKit -framework ServiceManagement \
  Sources/Config/ConfigModels.swift Sources/Config/ConfigStore.swift \
  Sources/Support/Log.swift Sources/Support/Watchdog.swift \
  Sources/System/HelperProtocol.swift Sources/System/HelperXPCClient.swift \
  Sources/System/SystemProxyManager.swift Sources/System/ShellEnvInjector.swift \
  Sources/Socks/Socket.swift \
  Tests/WatchdogHarness/main.swift -o /tmp/watchdog-harness && /tmp/watchdog-harness

# Opt-in real launchd install/uninstall, isolated to a temp LaunchAgents dir:
WD_TEST_AGENT=1 /tmp/watchdog-harness
```

## The dangling-proxy path checklist

Before shipping a change to enable/disable/quit/rebind, walk **every** row and
decide what your change does. If you add a new path, add a row.

| Path | Must end with |
|---|---|
| Normal toggle OFF | proxy restored, snapshot cleared, watchdog disarmed, server stopped |
| Normal quit | proxy restored from **persisted** snapshot, env removed, server stopped |
| Quit with `restoreOnQuit == false` | **snapshot + watchdog retained** (do NOT stop the listener while the proxy still points at it) |
| Quit mid-`enable()` | serialized with the workQueue; never re-capture a dangling proxy as "original" |
| `enable()` partial failure | rollback; if rollback fails, keep snapshot + watchdog armed |
| Restore failure (helper/MDM/osascript) | keep snapshot + watchdog armed; surface the error |
| SIGKILL / force-quit | watchdog restores; requires the watchdog to have been armed **before** `applyProxy` |
| Port change while active | rebind must roll back to the old port on failure |
| Sleep / wake / network change | re-verify or re-apply (`NSWorkspace.didWakeNotification` + `NWPathMonitor`) |
| Service appears/disappears (VPN, USB Ethernet) | snapshot/restore must handle services not present at restore time (still a known gap) |
| Two app instances | single-instance enforcement (still a known gap) |
| Helper path restore | an empty restore command list is treated as **failure**, not success |

## Snapshot fidelity requirements

- Capture **bypass domains** (`networksetup -getproxybypassdomains`) and restore
  them — the app overwrites them with its own list.
- Capture Auto Proxy Discovery (WPAD) and PAC state.
- Treat `networksetup -getautoproxyurl`'s `URL: (null)` as **no PAC**, not as a
  literal URL.
- Validate **per field**, never drop an entire service because one field is
  unusual. Service names may contain `/` (e.g. `USB 10/100/1000 LAN`).

## Manual verification (last resort)

If you must test against the real system (accepting risk), first capture the
current state yourself:

```bash
for s in $(networksetup -listallnetworkservices | tail -n +2); do
  echo "== $s =="; networksetup -getwebproxy "$s"; networksetup -getsecurewebproxy "$s"
  networksetup -getautoproxyurl "$s"; networksetup -getproxybypassdomains "$s"
done
```

Then run your scenario, and immediately verify with the same command and with
`./revert.sh`. Keep a terminal ready to run `./revert.sh` if the machine loses
internet.

See `references/dangling-proxy-audit.md` for the full failure inventory that
motivated this skill.
