# Logging & debugging

## Logging

`Sources/Support/Log.swift` provides `os.Logger` instances (unified log):

```swift
Log.app.info("enable(): starting on \(bindHost):\(port)")
Log.app.error("enable() failed, rolling back: \(error.localizedDescription)")
Log.proxy.info("listening on \(host):\(port)")
Log.telemetry.*  Log.system.*  Log.tunnel.*
```

Categories map to subsystems in `docs/`. The helper daemon logs via `NSLog` (it's a separate binary).

### Log levels (persistence)

- **`.notice` / `.error`** — persisted; visible in `log show` (post-mortem). Use these for lifecycle + errors.
- **`.info` / `.debug`** — memory-only; visible in `log stream --level debug` (live). Use for high-frequency debug, not for things you need after a crash.

### Watch live

```bash
log stream --predicate 'subsystem == "com.proxymanager.app"' --level debug
```

### Post-mortem

```bash
log show --last 30m --predicate 'subsystem == "com.proxymanager.app"'
# helper daemon
log show --last 30m --predicate 'process == "com.proxymanager.helper"'
```

## What must be logged

- Lifecycle: `enable`/`disable` start + success/failure, `shutdownForQuit`.
- Proxy start/stop, and connection-level errors.
- Helper authorization rejections.
- Admin-path errors (`runAdmin` failure, XPC timeout).

Never swallow an error silently — log it (and, where appropriate, surface via `lastError`).

## Emergency revert

If the app crashes and the internet dies (system proxy left at `127.0.0.1:8888`):

```bash
./revert.sh
```

Equivalent: boot out the crash watchdog, stop the app, clear the manual HTTP/HTTPS proxy on every service (leaving PAC alone), delete the proxy snapshot, remove the shell-env injection + rc source blocks, and clear the auto-re-enable flag. See the script itself for the exact `networksetup` commands.

## Crash reports

`~/Library/Logs/DiagnosticReports/ProxyManager-*.ips` (and `com.proxymanager.helper-*.ips`). A `critical`/`high` crash should be reproduced in a harness and fixed with a regression test (see `docs/testing.md`).
