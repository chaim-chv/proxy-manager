# System integration — system proxy & env

`Sources/System/SystemProxyManager.swift`, `Sources/System/ShellEnvInjector.swift`, `Sources/System/GuiEnvInjector.swift`

> **Background prompts are forbidden (2026-10-25).** An `osascript … with administrator privileges` request can trigger a macOS `authd` deadlock when it runs while the screen is locked, the session is inactive, or the Mac is asleep. Every mutation API takes `allowAdminPrompt` (**default `false`**); only an explicit user action may pass `true`, and `runAdmin` additionally requires `SessionState.canPrompt`. Background callers (auto-enable at login, wake/network re-apply, port change, rollback) never prompt — they use the helper or direct `networksetup` and otherwise **defer** a retry; quit and the watchdog use the prompt-free restore paths. See [`tasks/authd-unlock-deadlock/`](tasks/authd-unlock-deadlock/README.md).

Sets/clears the macOS system proxy (so browsers/system apps route through `127.0.0.1:8888`), injects `HTTP_PROXY`/`HTTPS_PROXY` into shell rc files (so CLI tools route through it), and publishes the proxy env to the GUI session via `launchctl` (so Finder/Dock apps route through it).

## System proxy

`SystemProxyManager`:

- **Read (no admin)**: `listServices()` (`networksetup -listallnetworkservices`, skipping disabled `*` services), `captureSnapshot(services:)` (`-getwebproxy`/`-getsecurewebproxy`/`-getautoproxyurl`/`-getproxybypassdomains`).
- **Mutations (admin)**: `applyProxy` (set web+secure proxy to `127.0.0.1:<port>`, disable PAC, set bypass domains), `clearProxy` (web+secure off), `restore(snapshot:)` (re-apply the user's original state).

Command building is centralized in `NetworksetupCommands` (in `HelperProtocol.swift`) as **argv arrays** — never a shell string on the helper path.

### Least-privilege mutation path (helper → direct → user-initiated admin)

`runMutations` executes every mutation with the least privilege that works:

1. **Helper daemon** (`HelperXPCClient`, root) — used when `helperIsReady()` (registered **and** answering a `ping`). Registration is a one-time foreground user action, so toggles never re-prompt. A **transport** failure (`.unavailable`, `.timedOut`) falls back to direct and caches the helper as unusable for the session; a **`.remote`** rejection is a real command error and propagates instead of being masked.
2. **`networksetup` run directly as the current user** (`runDirect`, argv-only). HTTP(S)/PAC proxy settings for the logged-in user's network services are stored **per-user** and need **no root** — this is also why `./revert.sh` never asks for a password. Prompt-free for ad-hoc/dev builds.
3. **`osascript "do shell script … with administrator privileges"`** — only when direct access genuinely fails **and** the caller is an explicit user action (`allowAdminPrompt: true`) **and** `SessionState.canPrompt` is true. Otherwise the call throws `ProxyAuthorizationError.deferred` (a deferral, not a failure) and `AppModel` retries prompt-free when the session becomes interactive. The admin wait is bounded at **30 s**.

`SessionState` (`Sources/System/SessionState.swift`) observes `NSWorkspace` sleep/wake/session notifications and the `com.apple.screenIsUnlocked` distributed notification, and reads `CGSessionCopyCurrentDictionary()` for the authoritative console/locked flags. While an auto-enable or deferral is pending, `AppModel` re-checks every 2 s (prompt-free) so a missed unlock notification cannot strand it. `isInteractive` = on console + unlocked + awake + session active. `canPrompt` additionally requires the app to be active or an explicit UI action within 60 s (`noteUserAction()`; menu-bar menus do not always make the app frontmost). `runAdmin` re-checks `canPrompt` as defense in depth.

`AppModel` forwards this as `userInitiated`: `toggle()` and onboarding pass `true`; launch auto-enable, wake/network re-apply, port/host rebind, every rollback, and quit pass `false`. A deferral is recorded (`deferredIntent`, `authorizationDeferred`) and retried prompt-free on session activation; the status menu's **Retry** (`retryDeferredApply()`) is the only deferred path that may prompt, because the user just clicked it.

`helperIsReady()` caches the helper verdict for the session; `invalidateHelperCache()` (called after a foreground Install Helper) re-probes it.

- The direct path (`runDirect`) launches `/usr/sbin/networksetup` via `Process.arguments` per service and stops at the first failure, throwing stderr so callers can escalate. It runs argv-only — no shell, so service names can't inject commands. Both `runDirect` and `runRead` use a **bounded wait** (20 s) so a hung `networksetup` cannot block the app or quit.
- The osascript path passes the escaped command **inline** (`runAdmin`) — it no longer writes a user-writable temp script (that was a TOCTOU root-escalation vector) — and bounds the wait at **30 s** (`runner.run("/usr/bin/osascript", …, 30, true)`), killing the whole process tree on timeout so no `networksetup` child keeps mutating after the app reports failure.
- Service names are single-quoted (`quote()` handles embedded `'`) on the shell/osascript path.
- **Every decision is logged** under `subsystem == "com.proxymanager.app"` as `auth path=…`: `helper` (ready/unavailable, ok), `direct` (ok), `deferred` (with `reason=background|session-not-interactive|canPrompt-false`), and `admin` (attempt/ok). A deferral is also surfaced to the UI (`authorizationDeferred`), so the next incident is diagnosable without a debugger.

## Shell env injection

`ShellEnvInjector`:

- Writes `~/.config/proxy-manager/env.sh` (`HTTP_PROXY`/`HTTPS_PROXY` = `http://<host>:<port>`, where a wildcard `bindHost` (`0.0.0.0`/empty) is normalized to `127.0.0.1`; host values are charset-validated so they can't break out of the quoted `export`; `NO_PROXY` = `127.0.0.1,localhost,::1` plus the tunnel host, so CLI tools never loop back through the tunnel; `PROXY_MANAGER_ACTIVE`).
- Inserts a guarded source line into the configured rc files (default `~/.zshrc`) between `# >>> proxy-manager >>>` / `# <<< proxy-manager <<<` markers; removes it cleanly on disable.

## GUI-session env injection

`GuiEnvInjector` (setting `system.injectGuiEnv`, default on):

- Publishes `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, `WSS_PROXY`, `NO_PROXY` (and `PROXY_MANAGER_ACTIVE`) to the **GUI session** with `launchctl setenv`, so apps launched from Finder/Dock — which never read shell rc files — route through the proxy. `WSS_PROXY` covers WebSocket clients (e.g. Codex) that ignore the macOS system proxy and only honor env vars.
- **Safety**: before setting anything, the user's existing values are captured and persisted to `gui-env-snapshot.json`; only a `remove()` that finds a snapshot touches the environment. So a cleanup can never clobber a proxy the app did not set, and a crash leaves the vars set (harmless — the proxy is still running). On disable/quit/rollback/watchdog-restore the originals are restored (or the vars unset).
- Values are built with the same host sanitization as `ShellEnvInjector`; an invalid bind host aborts without writing anything.
- `launchctl setenv` only affects apps launched *after* it runs, and does not persist across logout/reboot.

## Snapshot lifecycle (critical)

1. On first enable, the user's **original** proxy state is captured and **persisted to disk** (`system-proxy-snapshot.json`) *before* anything is changed. The GUI env originals are snapshotted the same way (`gui-env-snapshot.json`).
2. On disable/quit, it's restored and the file removed.
3. On relaunch auto-enable, the persisted snapshot is *loaded* (never re-captured — the current state is the app's own dangling proxy after a crash).

See `docs/app-model-lifecycle.md` for the full lifecycle and crash-recovery story.

## Crash watchdog restore

`SystemProxyManager.restoreWithoutPrompt(snapshot:)` / `clearWithoutPrompt(services:)` are the watchdog's paths: helper XPC **only if already registered and answering** (never `register()` — that would pop an admin prompt from a background process), and on **any** helper error (transport or `.remote`) fall back to `networksetup` directly as the user. They never fall back to `osascript`. `currentProxyPointsAtLocalhost(port:)` (read-only) lets the watchdog confirm the dangling proxy is ours before touching it — it matches the **configured port** (0 = any, for legacy armed state), so a user's own local proxy on another port is not clobbered. See `docs/app-model-lifecycle.md`.

## Audit changes (2026-09-15)

- **PAC `(null)`**: `networksetup -getautoproxyurl` prints `URL: (null)` when no PAC is set. It is normalized to "no PAC" at capture and on decode, so it never invalidates a service. `ServiceProxyState.isValid` no longer considers the PAC URL.
- **Per-field restore**: `NetworksetupCommands.restore` validates ports/servers/PAC per field and skips only the bad field, never the whole service.
- **Empty restore is a failure**: `HelperService.restoreProxy` returns `false` when a non-empty snapshot yields no commands, so the app never clears its recovery state on a no-op restore.
- **Service names with `/`** (e.g. `USB 10/100/1000 LAN`) are accepted.
- **Bypass domains are captured and restored** (`-getproxybypassdomains` / `-setproxybypassdomains`); previously the app overwrote them permanently.
- **Tolerant snapshot decode**: `ServiceProxyState` uses `decodeIfPresent`, so snapshots written before `bypassDomains` existed still load (a failed decode would defeat crash recovery).

