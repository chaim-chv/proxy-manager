# Privileged helper daemon + XPC

`Sources/Helper/main.swift`, `Sources/Helper/HelperService.swift`, `Sources/System/HelperProtocol.swift`, `Sources/System/HelperXPCClient.swift`

> **Helper packaging (canonical `SMAppService.daemon` layout):** the daemon binary lives at `Contents/Library/HelperTools/com.proxymanager.helper` and the plist carries `BundleProgram` pointing at it; both app and helper are signed with the same Developer ID (`--options runtime` is used for Developer ID builds; ad-hoc builds stay non-hardened so they can load the vendored Sparkle framework). Ad-hoc builds still cannot register (no Team ID), so the app falls back to direct `networksetup` and defers instead of prompting. See [`tasks/authd-unlock-deadlock/`](tasks/authd-unlock-deadlock/README.md).

Runs `networksetup` as **root** so the app can set/clear the system proxy without prompting for admin on every toggle. Installed via `SMAppService.daemon` (macOS 13+), talking over NSXPC.

## Architecture

- **Daemon** (`ProxyManagerHelper`, embedded at `Contents/Library/HelperTools/com.proxymanager.helper`; the plist in `Contents/Library/LaunchDaemons` sets `BundleProgram` to that path) registers `NSXPCListener(machServiceName: "com.proxymanager.helper")`, exports `HelperService`, and runs the run loop.
- **Shared protocol** `@objc ProxyManagerHelperProtocol` (`applyProxy`, `clearProxy`, `restoreProxy`, `ping`) with plist-compatible types (`[String]`, `Int`, `[String: [String: String]]` for the snapshot, and a `(Bool, String?)` reply).
- **App client** `HelperXPCClient` reports a `HelperState` (`ready` / `notInstalled` / `requiresApproval` / `unavailable(reason)`). `ready` requires `daemon.status == .enabled` **and** a live `ping` (2 s), so a registered-but-rejecting daemon is not sent mutations. Mutations use the synchronous bridge with a **15 s timeout**; the client maps transport failures to `.unavailable`/`.timedOut` and command rejections to `.remote`.
- **Registration is foreground-only.** `registerFromUser()` is called from the Settings → System → Administrator access button never from `SystemProxyManager`, `runMutations`, a background queue, or the watchdog. It throws unless `SessionState.isInteractive` is true, so a locked/asleep session cannot raise the approval UI. The status panel shows the current state (`ready` / `notInstalled` / `requiresApproval` / `unavailable(reason)`) and offers Install / Open Login Items; `AppModel.refreshHelperState()` re-probes off the main thread when Settings opens and after an install.

## Authorization (do not weaken)

`HelperServiceDelegate.listener(_:shouldAcceptNewConnection:)` rejects any caller whose code-signing **Team ID** doesn't match the helper's own (via `SecCodeCopyGuestWithAttributes` on the process identifier → `SecCodeCopySigningInformation`). This prevents arbitrary local processes from driving root `networksetup` (a MITM vector).

## Security model

- **argv only** — `HelperService` runs `networksetup` via `Process.arguments`, never a shell.
- **Input validation** — service names (`isValidService` charset) and ports (1…65535 in `applyProxy`). On restore, structurally-invalid service state (`ServiceProxyState.isValid`) is dropped by the app and re-checked by the helper, and `NetworksetupCommands.restore` sanitizes per field (skips empty/invalid-port proxy fields and non-`http`/`https` PAC URLs); all values reach `networksetup` as argv, never a shell.
- **Bounded execution** — each `networksetup` invocation is time-boxed (20 s `waitForExit`), so a hung command can't block the daemon forever.

## Registration requirements

`SMAppService.daemon` requires a **Developer-ID-signed** app installed in `/Applications` **and** a daemon signed with the same Team ID. The build emits `BundleProgram`, embeds the helper under `Contents/Library/HelperTools`, and signs both with the same identity (hardened runtime for Developer ID builds). For ad-hoc/unsigned builds the helper reports `.notInstalled`/`.unavailable`, so the app runs `networksetup` directly as the current user (prompt-free) and defers an admin fallback instead of prompting (see `docs/system-integration.md`). Build with:

```bash
IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build.sh 1.0.0
```
