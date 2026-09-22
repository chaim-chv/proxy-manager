# Config persistence

`Sources/Config/ConfigStore.swift`, `Sources/Config/ConfigModels.swift`

## Storage

- Config: `~/Library/Application Support/ProxyManager/config.json` (JSON, atomic write, `0600`).
- Telemetry: `telemetry.sqlite` (same dir).
- System-proxy snapshot: `system-proxy-snapshot.json` (same dir, `0600`).
- Shell env: `~/.config/proxy-manager/env.sh`.
- Both directories are created `0700` (owner-only).

## Models (`AppConfig`)

```jsonc
{
  "version": 1,
  "proxy":   { "bindHost": "127.0.0.1", "port": 8888 },
  "tunnel":  { "mode": "MANUAL",                       // or "MANAGED"
               "host": "127.0.0.1", "port": 1080, "supervised": false, "launchdLabel": "",
               "managed": { "sshHost": "", "sshPort": 22, "username": "", "auth": "KEY",
                            "keyPath": "", "socksHost": "127.0.0.1", "socksPort": 1080 } },
  "policy":  { "failClosedWhenTunnelDown": false },   // false = fail-open
  "system":  { "injectShellEnv": true, "injectGuiEnv": true, "launchAtLogin": false,
               "restoreOnQuit": true, "colorizeMenuIcon": true,
               "appearanceMode": "SYSTEM", "iconMode": "MENU_BAR_AND_DOCK",
               "managedShellRcs": ["~/.zshrc"], "crashWatchdog": true },
  "targets": [ { "id": "…", "pattern": "example.com", "enabled": true } ],
  "monitor": { "retentionDays": 7, "maxRows": 500000, "recordPaths": true },
  "lock":    { "enabled": false },
  "apps":    { "enabled": false,                          // opt-in per-app routing
               "defaultMode": "TARGETS",                  // TUNNEL | TARGETS | DIRECT
               "recordInTelemetry": true,
               "rules": [ { "id": "…", "key": "com.google.Chrome",
                            "keyKind": "BUNDLE",          // BUNDLE | EXECUTABLE | EXECUTABLE_NAME
                            "mode": "TUNNEL",             // TUNNEL | TARGETS | DIRECT
                            "enabled": true } ] }
}
```

Notes:
- `targets` is **empty by default** — the app is generic. Seed it via onboarding or presets (`TargetPreset` in `Sources/Config/Presets.swift`).
- `apps` is **off by default** (zero overhead): per-app routing runs a per-connection identity scan only when `apps.enabled` is true *and* at least one rule exists. `defaultMode` applies to apps with no matching rule. See `docs/per-app-rules.md` and `docs/routing.md`.
- `AppRule`/`AppSettings` decode tolerantly, and an unknown `keyKind`/`mode`/`defaultMode` value falls back to a default rather than failing the whole config decode.
- `tunnel.mode` selects who provides the tunnel: `MANUAL` (user's own SOCKS5) or `MANAGED` (the app runs `ssh -N -D`). `effectiveHost`/`effectivePort` resolve to `managed.socksHost/socksPort` in managed mode, else `host`/`port`.
- `managed.auth` is `KEY` or `PASSWORD`; the password is **not** stored here — it lives in the Keychain (`SSHKeychain`, service `com.proxymanager.ssh`).
- `tunnel.launchdLabel` (manual mode) is the optional launchd job label for "Supervised by app"; restart only acts when `supervised` is true **and** the label is non-empty.
- `lock` is **reserved** (app-lock is not implemented): it is persisted/decoded but nothing reads `enabled` yet.
- `TunnelSettings`, `SystemSettings`, and **every other config struct** (`AppConfig`, `ProxySettings`, `PolicySettings`, `MonitorSettings`, `LockSettings`, `ManagedTunnelSettings`, `TargetRule`) use custom Codable with `decodeIfPresent(...) ?? default`. This is required: synthesized `Codable` throws `keyNotFound` for a missing key even when the property has a default, so adding a field would fail whole-file decode and wipe the user's config. `Tests/RegressionHarness` asserts a legacy config (missing `policy`/`monitor`/`lock`) and a future config (unknown keys) both decode and preserve targets.

## `ConfigStore`

- Singleton; `config` persists via `didSet { save }`.
- **Corrupt config** → backed up to `config.json.corrupt`, starts with defaults.
- `saveSnapshot`/`loadSnapshot`/`clearSnapshot` for the system-proxy snapshot (see `docs/app-model-lifecycle.md`).

## Thread-safety & sharp edges (see `docs/roadmap.md`)

- `config` is read/written on main by convention (no lock) — don't add a background writer.
- `save` swallows encode/write errors.
- A second corruption overwrites the first `.corrupt` backup.
- `AppModel` debounces the disk save (0.5 s) so per-keystroke UI edits don't write on every character.
