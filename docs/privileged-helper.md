# Privileged helper daemon + XPC

`Sources/Helper/main.swift`, `Sources/Helper/HelperService.swift`, `Sources/System/HelperProtocol.swift`, `Sources/System/HelperXPCClient.swift`

Runs `networksetup` as **root** so the app can set/clear the system proxy without prompting for admin on every toggle. Installed via `SMAppService.daemon` (macOS 13+), talking over NSXPC.

## Architecture

- **Daemon** (`ProxyManagerHelper`, embedded at `Contents/Library/LaunchDaemons/com.proxymanager.helper`) registers `NSXPCListener(machServiceName: "com.proxymanager.helper")`, exports `HelperService`, and runs the run loop.
- **Shared protocol** `@objc ProxyManagerHelperProtocol` (`applyProxy`, `clearProxy`, `restoreProxy`) with plist-compatible types (`[String]`, `Int`, `[String: [String: String]]` for the snapshot, and a `(Bool, String?)` reply).
- **App client** `HelperXPCClient` registers the daemon (`SMAppService.daemon(plistName: "com.proxymanager.helper.plist")`) and calls it with a **15 s timeout** on the synchronous bridge.

## Authorization (do not weaken)

`HelperServiceDelegate.shouldAcceptNewConnection` rejects any caller whose code-signing **Team ID** doesn't match the helper's own (via `SecCodeCopyGuestWithAttributes` on the process identifier → `SecCodeCopySigningInformation`). This prevents arbitrary local processes from driving root `networksetup` (a MITM vector).

## Security model

- **argv only** — `HelperService` runs `networksetup` via `Process.arguments`, never a shell.
- **Input validation** — service names (`isValidService` charset), ports (1…65535), and snapshot values (`ServiceProxyState.isValid`: ports int 1–65535, server chars, `http`/`https` PAC URL).
- **Bounded execution** — (see `docs/roadmap.md`: `Process.waitUntilExit` in the daemon is not yet time-boxed).

## Registration requirements

`SMAppService.daemon` requires a **Developer-ID-signed** app installed in `/Applications`. For ad-hoc/unsigned builds `register()` throws and the app runs `networksetup` directly as the current user (prompt-free), escalating to `osascript` only if the direct path fails (see `docs/system-integration.md`). Build with:

```bash
IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build.sh 1.0.0
```
