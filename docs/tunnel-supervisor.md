# Tunnel health supervisor & SSH runner

`Sources/Tunnel/TunnelSupervisor.swift`, `Sources/Tunnel/SSHTunnelRunner.swift`, `Sources/Tunnel/SSHKeychain.swift`

## Responsibilities

- Probe the SOCKS5 tunnel every **10 s** (`SOCKS5Client.probe` — TCP connect + no-auth greeting).
- Publish `tunnelUp` (`@Published` for UI, and an `NSLock`-guarded `isTunnelUp` for the proxy core to read from relay threads).
- Optionally restart the tunnel: `launchctl kickstart` (manual mode) or restart the SSH child (managed mode).

## Details

- `probe()` runs on a background queue, updates `upState` under `stateLock`, then hops to main to set `@Published tunnelUp`. It probes `tunnel.effectiveHost/effectivePort` (managed SOCKS bind in managed mode).
- `restartTunnel()` (manual mode) runs `launchctl kickstart -k gui/<uid>/<tunnel.launchdLabel>`, then re-probes after 2 s. It only acts when `tunnel.supervised` is on **and** `tunnel.launchdLabel` is non-empty.
- `AppModel.recomputeStateAfterTunnelChange` transitions `on ↔ degraded` on probe changes.

## Managed SSH tunnel (`SSHTunnelRunner`)

Runs the tunnel itself ("Run the tunnel for me"): spawns a **foreground** `ssh -N -D <host:port> -p <port> -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -q [auth] user@host` (never `-f`), drains stderr via `readabilityHandler` (no deadlock), and supervises it:

- **Restart with exponential backoff** (1→60 s, resets after 60 s uptime) on non-fatal exits (network flap / connection reset).
- **Fatal** (no retry): `Permission denied`, `Authentication failed`, `Host key verification failed`, `Could not resolve hostname`, bad/missing key file.
- **Auth**: key file (`-i <path> -o IdentitiesOnly=yes -o BatchMode=yes`; passphrase-less or ssh-agent) or **password** read from the Keychain and fed via a one-shot `SSH_ASKPASS` helper + `SSH_ASKPASS_REQUIRE=force` (OpenSSH ≥ 8.4). The password is **never** in argv or env.
- **Stop**: `process.terminate()` (SIGTERM) is sufficient — `ssh -D` (foreground) spawns no children. `stopNow()` (queue.sync) is used on quit.

## Sharp edges (see `docs/roadmap.md`)

- No IDN/`0.0.0.0` validation for `socksHost`; `StrictHostKeyChecking=accept-new` trusts an unknown host key on first connect.

## Audit changes (2026-09-15)

- **Fatal detection actually works now**: `-q` was removed (it suppressed all stderr, so `isFatal()` never matched and failures retried forever). Uses `-o LogLevel=ERROR`; added fatal markers for `Too many authentication failures` and bind failures (`Address already in use`, `cannot listen to port`).
- **Orphan reaping**: the child pid is written to `ssh.pid`; on spawn the previous `ssh` (verified via `ps -o comm=`) is killed, so a crash/force-quit cannot permanently lock the SOCKS port.
- **Stop is authoritative**: `stopLocked()` clears `currentSettings` and the backoff restart re-checks generation/settings **on the serial queue**, so an in-flight backoff cannot revive a stopped tunnel. `stop()` escalates SIGTERM → SIGKILL (2 s).
- **Password hygiene**: the askpass secret is `cat`-then-`rm` (self-deleting) and `NumberOfPasswordPrompts=1`; password auth uses `PubkeyAuthentication=no` + `PreferredAuthentications=password,keyboard-interactive` so agent keys don't exhaust auth attempts.
- **Self-contained child**: `ControlMaster=no`, `ControlPath=none` so a user's ssh config cannot background/hijack the forward.
- **No main-thread freeze**: `restartTunnel()` runs on a background queue with `FileHandle.nullDevice` (was blocking main on an undrained `launchctl` pipe).
- `probing` is now guarded by `stateLock`, and the probe cannot stick because `Socket.connect` bounds DNS/connect.


## Policy interaction

The proxy core reads `isTunnelUp` per connection: tunnel-down + fail-open → direct (tagged `tunnel_down`); tunnel-down + fail-closed → `502`.
