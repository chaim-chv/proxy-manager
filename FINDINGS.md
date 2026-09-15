# Findings

> **Status:** the critical/high findings below were fixed; the durable lessons
> are canonical in [`AGENTS.md`](AGENTS.md) §"Critical lessons learned".
> Regression coverage lives in `Tests/` and [`docs/testing.md`](docs/testing.md).

- [SwiftUI `.popover` is unusable for hover tooltips — use an `NSTrackingArea` + floating `NSWindow`](#swiftui-popover-is-unusable-for-hover-tooltips)
- [Feed-table selection must be one-directional and order-stable to avoid "jumping"](#feed-table-selection-must-be-one-directional-and-order-stable)
- [The dashboard builds with `swiftc` — new `Sources/UI/*.swift` files are picked up automatically by `build.sh`](#new-source-files-are-picked-up-automatically)
- [Dock icon presence is a runtime activation policy, not `Info.plist`](#dock-icon-presence-is-a-runtime-activation-policy-not-infoplist)
- [SIGPIPE kills the whole app on any peer reset — set `SO_NOSIGPIPE` / ignore it](#sigpipe-kills-the-whole-app-on-any-peer-reset)
- [`UInt16(p)` on `url.port` traps on an oversized port (remotely reachable crash)](#uint16p-on-urlport-traps-on-an-oversized-port)
- [`networksetup -getautoproxyurl` prints `URL: (null)` — treat it as "no PAC"](#networksetup-getautoproxyurl-prints-url-null)
- [Synthesized `Codable` on `AppConfig` silently wipes the user's config on schema change](#synthesized-codable-on-appconfig-silently-wipes-the-users-config)
- [Telemetry binds text with `SQLITE_STATIC` on a temporary `NSString` (use-after-free)](#telemetry-binds-text-with-sqlite_static-on-a-temporary-nsstring)
- [`SSHTunnelRunner` passes `-q`, so `isFatal()` never matches and retries forever](#sshtunnelrunner-passes-q-so-isfatal-never-matches)
- [There is no sleep/wake or network-change handling anywhere](#there-is-no-sleepwake-or-network-change-handling)
- [App Nap can suspend the proxy — no `ProcessInfo.beginActivity` assertion is held](#app-nap-can-suspend-the-proxy)
- [Standalone Swift harness gotchas](#standalone-swift-harness-gotchas)

## SwiftUI `.popover` is unusable for hover tooltips

**Summary:** On macOS, driving a SwiftUI `.popover(isPresented:)` from `.onHover` causes flicker and mis-anchoring (arrow edges are inverted from intuition, and the popover steals tracking from the trigger). The reliable pattern is a custom `NSTrackingArea` on a background `NSViewRepresentable` plus a shared borderless, non-activating `NSWindow`.

**Context:** The dashboard inspector's icon buttons needed an *immediate* tooltip (the user rejected both `.help()`'s ~1s delay and the popover's glitches). Two distinct problems surfaced:
1. `.onHover` + `.popover` flickers because presenting the popover perturbs mouse tracking, toggling the hover state repeatedly.
2. `arrowEdge: .top` places the popover *below* the anchor (arrow on the popover's top edge), not above it — the opposite of the `on top` request. The user wanted it anchored to the top edge of the element.

The implemented solution (`Sources/UI/Tooltip.swift`) uses:
- A `.background(TooltipTrackingView(...))` so a tracking-area-backed `NSView` sits *behind* the clickable content (tracking areas are region-based, so they fire enter/exit regardless of a view being on top).
- `NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], ...)`, recreated in `updateTrackingAreas()`.
- A shared `TooltipWindow` (borderless `NSWindow`, `ignoresMouseEvents = true`, `.floating` level, `collectionBehavior = [.transient, .ignoresCycle]`), positioned in screen coordinates via `anchorWindow.convertToScreen(...)`, anchored at `rectInScreen.maxY + gap` (above the element) and clamped to `screen.visibleFrame`.

Use `view.hoverTooltip("text")` (a `View` extension) for any immediate tooltip. Keep the small font (~10pt) and tight padding; the tooltip never becomes key and hides on `mouseExited` / `viewWillMove(toWindow: nil)`.

**Related:** `Sources/UI/Tooltip.swift`, `Sources/UI/RequestDetailView.swift`, `Sources/UI/HelpPopover.swift` (the `HelpPopover` there is a click-to-toggle popover, intentionally different).

## Feed-table selection must be one-directional and order-stable

**Summary:** A live-updating `NSTableView` feed "jumps" when clicked unless (a) the row order is deterministic across refreshes and (b) selection is driven table→binding only, re-selected solely after a real `reloadData()`.

**Context:** The request feed refreshes at ~10 Hz. The original code re-sorted rows on every recompute (Swift's `sort` is not stable, so equal-timestamp rows reshuffled) and re-applied selection from the binding each tick, which fought the user's click and highlighted the wrong row. Fixes, in `DashboardView.swift` and `FeedTable.swift`:
- Stable sort with an index tiebreaker: `rows.enumerated().sorted { ts desc, offset asc }.map(\.element)`.
- Selection is one-way: `tableViewSelectionDidChange` → `onSelect(id)` → binding. The coordinator only re-selects after `reloadData()` (when row *identity* changed, tracked by comparing `[UUID]`), and only deselects when the owner clears the binding (inspector dismissed).
- Partial `reloadData(forRowIndexes:)` is used only when the id order is unchanged (pure byte/duration ticks); any identity/order change does a full `reloadData()` to avoid off-screen desync.
- The inspector resolves its event by `id` from `liveRequests`/`recentRequests`, not by table row, so it stays correct even as rows shift.

**Related:** `Sources/UI/DashboardView.swift` (`computeFeedRows`, `reconcileSelection`), `Sources/UI/FeedTable.swift` (Coordinator).

## New `Sources/UI/*.swift` files are picked up automatically

**Summary:** `build.sh` compiles `find Sources -name '*.swift' -not -path 'Sources/Helper/*'`, so adding a new Swift file (e.g. `Sources/UI/Tooltip.swift`, `Sources/UI/RequestDetailView.swift`) requires no manifest change — it is included on the next build.

**Context:** There is no Xcode project or SPM manifest. New UI/telemetry/routing files are auto-discovered; the only exclusion is `Sources/Helper/*` (compiled separately into the privileged helper daemon). This matters when adding a new type that should be shared vs. helper-only. `Sources/Config/ConfigModels.swift` (which defines `Route`, `TargetRule`, etc.) is the de-facto "shared models" file usable from standalone test harnesses compiled against `Sources/Config/ConfigModels.swift Sources/Routing/RoutingEngine.swift ...`.

**Related:** `build.sh` (lines 16-19), `docs/testing.md`.

## Dock icon presence is a runtime activation policy, not `Info.plist`

**Summary:** A macOS app's Dock icon is controlled at runtime via `NSApp.setActivationPolicy(.accessory | .regular)`. `Info.plist`'s `LSUIElement` is static (baked in by `build.sh`) and cannot express "Dock only" (status item hidden). Hiding the menu-bar item is `NSStatusItem.isVisible`, owned by `StatusMenuController`.

**Context:** The user-selectable `system.iconMode` (Menu bar only / Menu bar + Dock / Dock only) needs two independent knobs. `.accessory` removes the Dock icon, `.regular` restores it; the status item is hidden with `statusItem.isVisible = false` (the controller keeps it as a stored property or it would vanish). `AppModel.applyIconMode()` sets the policy — dispatched to main, mirroring `applyAppearance()` — and is called from `init` and `commitConfig()`. `StatusMenuController.refresh()` sets `isVisible` from the observed `config` (it already sinks `$config`), so the two sides stay decoupled. New `SystemSettings` fields must be added to `CodingKeys` with `decodeIfPresent(...) ?? default` in the custom `init(from:)`/`encode(to:)`, or older `config.json` files fail whole-file decode.

**Related:** `Sources/Config/ConfigModels.swift` (`AppIconMode`, `SystemSettings`), `Sources/AppModel.swift` (`applyIconMode`), `Sources/UI/StatusMenuController.swift` (`refresh`), `Sources/UI/SettingsView.swift` (`AppIconModePicker`), `build.sh` (`LSUIElement`).

## SIGPIPE kills the whole app on any peer reset

**Summary:** macOS has no `MSG_NOSIGNAL`; `send()` to a peer that sent RST raises `SIGPIPE`, whose default disposition terminates the process. Nothing in the repo sets `SO_NOSIGPIPE` or calls `signal(SIGPIPE, SIG_IGN)`.

**Context:** `Socket.sendAll` (`Sources/Socks/Socket.swift:107-123`) and the relay sends (`Sources/Proxy/ProxyServer.swift:404,443`) plus the CONNECT `200` (`:209`) all write without suppression. A browser closing a tab, a probe that RSTs after `CONNECT`, or any dead-peer scenario (the exact case `docs/testing.md` says is covered) kills the app. Verified: a loopback RST peer + `send()` exits `141` (128+SIGPIPE); `Tests/CrashProbes/sigpipe_send` reproduces it, and `Tests/ProxyE2E` dies with 141 at its RST-burst stage. Fix: `setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, ...)` on every socket and/or ignore SIGPIPE at startup.

**Related:** `Sources/Socks/Socket.swift`, `Sources/Proxy/ProxyServer.swift`, `Tests/CrashProbes/sigpipe_send/main.swift`.

## `UInt16(p)` on `url.port` traps on an oversized port

**Summary:** `HTTPRequest.port` uses the non-failable `UInt16(p)` initializer (`Sources/Proxy/HTTPParser.swift:70`); `URL(string:).port` returns an `Int` and does **not** reject ports > 65535, so `UInt16(99999)` traps and kills the process.

**Context:** A single `GET http://host:99999/ HTTP/1.1` triggers it (verified: exit `133`/SIGTRAP; `Tests/CrashProbes/oversized_port`). The other conversions in the same file (`:33`, `:43`) correctly use the failable `UInt16(Substring)`. Fix: `UInt16(exactly: p) ?? defaultPort` or validate `p <= 65535`. This is the same class as the already-fixed `Dictionary(uniqueKeysWithValues:)` trap.

**Related:** `Sources/Proxy/HTTPParser.swift`, `Tests/CrashProbes/oversized_port/main.swift`.

## `networksetup -getautoproxyurl` prints `URL: (null)`

**Summary:** When no PAC is configured, `networksetup -getautoproxyurl <svc>` prints `URL: (null)`. The app stores that literal string in `ServiceProxyState.pacURL`, which `isValid` then rejects (no `http(s)` scheme), and `HelperService.restoreProxy` drops the **entire service** — with an empty command list still reported as success.

**Context:** Verified on macOS. On any helper (signed) install with the common "no PAC" configuration, `restore` silently does nothing while returning success, so disable and crash-restore both leave the system proxy dangling and then clear the snapshot + disarm the watchdog. Fix: normalize `(null)`/empty to `""` at capture time, validate per-field (not per-service), and make an empty restore an error. Also note `isValidService` rejects `/`, so real services like `USB 10/100/1000 LAN` are dropped.

**Related:** `Sources/System/SystemProxyManager.swift:39-44`, `Sources/System/HelperProtocol.swift:62-75,129-133`, `Sources/Helper/HelperService.swift:30-35`, `skills/system-proxy-safety-testing/references/dangling-proxy-audit.md`.

## Synthesized `Codable` on `AppConfig` silently wipes the user's config

**Summary:** Only `TunnelSettings` and `SystemSettings` have hand-written `init(from:)` with `decodeIfPresent(...) ?? default`. Every other config struct (`AppConfig`, `ProxySettings`, `PolicySettings`, `MonitorSettings`, `LockSettings`, `ManagedTunnelSettings`, `TargetRule`) uses synthesized `Codable`, which throws `keyNotFound` when a key is absent — even when the property has a default value.

**Context:** Adding any new field in a future build makes every existing `config.json` fail whole-file decode; `ConfigStore.load` backs it up to `.corrupt` and `ConfigStore.init` writes fresh defaults, silently losing the target allow-list and settings (and since defaults are `[]`, traffic then goes direct in the clear). Verified: a config missing `policy` fails to decode. Fix: custom `init(from:)` with `decodeIfPresent` on every config struct, or a decode strategy that tolerates missing keys.

**Related:** `Sources/Config/ConfigModels.swift`, `Sources/Config/ConfigStore.swift:39-52`, `Tests/RegressionHarness/main.swift`.

## Telemetry binds text with `SQLITE_STATIC` on a temporary `NSString`

**Summary:** `bindText` calls `sqlite3_bind_text(stmt, idx, (text as NSString).utf8String, -1, nil)`; the `nil` destructor is `SQLITE_STATIC`, which tells SQLite **not** to copy the buffer. The pointer points into a temporary bridged `NSString` that is released when the expression ends, before the later `sqlite3_step`.

**Context:** `Sources/Telemetry/TelemetryStore.swift:437` (and the inline bind at `:427`) → heap use-after-free on every `insertBatch`/`upsertMinuteStats`. Symptoms are nondeterministic: garbled host/path/route/error values in SQLite or a crash. Use `SQLITE_TRANSIENT` (`unsafeBitCast(-1, to: sqlite3_destructor_type.self)`) or keep an explicitly owned buffer. SQLite return codes are also ignored throughout (silent telemetry loss).

**Related:** `Sources/Telemetry/TelemetryStore.swift`.

## `SSHTunnelRunner` passes `-q`, so `isFatal()` never matches

**Summary:** The runner adds `-q` to `ssh` (`Sources/Tunnel/SSHTunnelRunner.swift:196`) but classifies fatal errors by substring-matching stderr (`:160-174`). `-q` suppresses all diagnostics, so stderr is always empty and `isFatal("")` is always false.

**Context:** Auth failures, bad keys, host-key changes, and DNS failures are treated as transient and retried on the 1→2→4…→60 s backoff forever (account lockout risk), and the UI only ever shows `ssh exited with code 255`. Verified against OpenSSH 9.9p2: with `-q` the captured stderr is empty. Fix: drop `-q` or use `-o LogLevel=ERROR`. Related: an orphaned `ssh` after a crash holds the SOCKS port and `bind: Address already in use` is not in the fatal set, so managed mode can never recover until the orphan is killed; and the password is written in cleartext to `$TMPDIR` (`:223-243`) until stop.

**Related:** `Sources/Tunnel/SSHTunnelRunner.swift`, `docs/tunnel-supervisor.md`.

## There is no sleep/wake or network-change handling

**Summary:** No `NSWorkspace.didWakeNotification`, `NWPathMonitor`, or `SCNetworkReachability` exists anywhere in `Sources/`. After sleep/wake or an interface/VPN change, the app neither re-applies nor re-verifies the system proxy, and never health-checks its own listener.

**Context:** New network services bypass the proxy (routing/privacy leak) while the UI says ON; if the listen socket becomes unusable the system proxy points at a dead local port with no detection. The SOCKS tunnel may also be dead post-wake (only `degraded`/fail-open, no reconnect). This is a real gap, not merely roadmap polish, because it can break or silently bypass routing.

**Related:** `Sources/AppModel.swift`, `Sources/Tunnel/TunnelSupervisor.swift`, `docs/roadmap.md`.

## App Nap can suspend the proxy

**Summary:** The app holds no `ProcessInfo.beginActivity` assertion, so macOS App Nap can throttle or suspend its timers and background threads while it is not user-visible — which is the normal state of a menu-bar proxy. When the process is napped, the system proxy still points at `127.0.0.1:<port>` but the relay/timers may not run, so connections stall and the tunnel-health probe and telemetry flusher stop ticking.

**Context:** `Sources/` has no `beginActivity`/`NSProcessInfo` activity assertion (verified by grep). Relevant affected timers: the telemetry flusher (`TelemetryStore.swift:228`, a `DispatchSourceTimer` on a utility queue), the tunnel-health `Timer` on `RunLoop.main` (`TunnelSupervisor.swift:25-28`), and the dashboard refresh. Fix: hold a `ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .suddenTerminationDisabled, .automaticTerminationDisabled], reason: ...)` token while routing is enabled and `endActivity` on disable. `.userInitiatedAllowingIdleSystemSleep` prevents App Nap while still allowing the system to sleep; `.automaticTerminationDisabled`/`.suddenTerminationDisabled` guard against macOS reclaiming the "hidden" app.

**Testing note:** App Nap cannot be forced via a public API. Verify manually: enable routing, hide the app and leave it idle a few minutes, then confirm with Activity Monitor's "App Nap" column / `powermetrics --samplers tasks` that the process is not napping, and that `log stream --predicate 'subsystem == "com.proxymanager.app"'` still shows flusher/probe activity.

**Related:** `Sources/Telemetry/TelemetryStore.swift`, `Sources/Tunnel/TunnelSupervisor.swift`, `Sources/AppModel.swift`.

## Standalone Swift harness gotchas

**Summary:** The repo has no Xcode/SPM tests; harnesses are `swiftc`-compiled `main.swift` programs. Five gotchas cost real time: top-level code must be in `main.swift`; you must pass the exact `Sources/*.swift` file list; mock servers/load must use `Thread.detachNewThread` (not `DispatchQueue.global`, which caps ~64 blocking threads); harnesses that can crash must call `setbuf(stdout, nil)` or a signal-killed process loses all buffered output; and crash probes must run as subprocesses with signal exits (`133`=SIGTRAP, `141`=SIGPIPE) treated as failures.

**Context:** `Tests/run-all.sh` is the driver and encodes the file lists. `Tests/ProxyE2E` reproduces the SIGPIPE crash live (exit 141 at the RST-burst stage). See the project skill `skills/standalone-swift-regression-harness` for the full workflow and helper snippets.

**Related:** `Tests/run-all.sh`, `Tests/RegressionHarness/main.swift`, `Tests/ProxyE2E/main.swift`, `docs/testing.md`.
