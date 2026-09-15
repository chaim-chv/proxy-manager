# Findings

> **Status:** the critical/high findings below have been fixed; each entry keeps
> the durable "why" and points at the fix. The canonical lessons live in
> [`AGENTS.md`](AGENTS.md) §"Critical lessons learned". Regression coverage
> lives in `Tests/` and [`docs/testing.md`](docs/testing.md).

- [SwiftUI `.popover` is unusable for hover tooltips](#swiftui-popover-is-unusable-for-hover-tooltips)
- [Feed-table selection must be one-directional and order-stable](#feed-table-selection-must-be-one-directional-and-order-stable)
- [New source files are picked up automatically by `build.sh`](#new-source-files-are-picked-up-automatically-by-buildsh)
- [Dock icon presence is a runtime activation policy, not `Info.plist`](#dock-icon-presence-is-a-runtime-activation-policy-not-infoplist)
- [Suppress SIGPIPE on every socket](#suppress-sigpipe-on-every-socket)
- [Parse ports with the failable `UInt16(exactly:)`](#parse-ports-with-the-failable-uint16exactly)
- [`networksetup -getautoproxyurl` prints `URL: (null)`](#networksetup-getautoproxyurl-prints-url-null)
- [Decode config tolerantly so upgrades don't wipe it](#decode-config-tolerantly-so-upgrades-dont-wipe-it)
- [Bind telemetry text with `SQLITE_TRANSIENT`](#bind-telemetry-text-with-sqlite_transient)
- [Keep ssh errors visible in `SSHTunnelRunner`](#keep-ssh-errors-visible-in-sshtunnelrunner)
- [Re-apply the proxy after sleep/wake and network changes](#re-apply-the-proxy-after-sleepwake-and-network-changes)
- [Hold a `ProcessInfo.beginActivity` assertion while routing](#hold-a-processinfobeginactivity-assertion-while-routing)
- [Standalone Swift harness gotchas](#standalone-swift-harness-gotchas)

## SwiftUI `.popover` is unusable for hover tooltips

**Status:** Implemented (design note, not a bug).

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

**Status:** Implemented (design note, not a bug).

**Summary:** A live-updating `NSTableView` feed "jumps" when clicked unless (a) the row order is deterministic across refreshes and (b) selection is driven table→binding only, re-selected solely after a real `reloadData()`.

**Context:** The request feed refreshes at ~10 Hz. The original code re-sorted rows on every recompute (Swift's `sort` is not stable, so equal-timestamp rows reshuffled) and re-applied selection from the binding each tick, which fought the user's click and highlighted the wrong row. Fixes, in `DashboardView.swift` and `FeedTable.swift`:
- Stable sort with an index tiebreaker: `rows.enumerated().sorted { ts desc, offset asc }.map(\.element)` (`DashboardView.swift:441-448`).
- Selection is one-way: `tableViewSelectionDidChange` → `onSelect(id)` → binding (`FeedTable.swift:136-142`). The coordinator only re-selects after `reloadData()` (when row *identity* changed, tracked by comparing `[UUID]`), and only deselects when the owner clears the binding (inspector dismissed).
- Partial `reloadData(forRowIndexes:)` is used only when the id order is unchanged (pure byte/duration ticks); any identity/order change does a full `reloadData()` to avoid off-screen desync.
- The inspector resolves its event by `id` from `liveRequests`/`recentRequests`, not by table row, so it stays correct even as rows shift (`DashboardView.swift:393-394`).

**Related:** `Sources/UI/DashboardView.swift` (`computeFeedRows`, `reconcileSelection`), `Sources/UI/FeedTable.swift` (Coordinator).

## New source files are picked up automatically by `build.sh`

**Status:** Implemented (design note, not a bug).

**Summary:** `build.sh` compiles `find Sources -name '*.swift' -not -path 'Sources/Helper/*'` (NUL-delimited and sorted), so adding a new Swift file (e.g. `Sources/UI/Tooltip.swift`, `Sources/UI/RequestDetailView.swift`) requires no manifest change — it is included on the next build.

**Context:** There is no Xcode project or SPM manifest. New UI/telemetry/routing files are auto-discovered; the only exclusion is `Sources/Helper/*` (compiled separately into the privileged helper daemon). This matters when adding a new type that should be shared vs. helper-only. `Sources/Config/ConfigModels.swift` (which defines `Route`, `TargetRule`, etc.) is the de-facto "shared models" file usable from standalone test harnesses compiled against `Sources/Config/ConfigModels.swift Sources/Routing/RoutingEngine.swift ...`.

**Related:** `build.sh` (lines 38-40), `docs/testing.md`.

## Dock icon presence is a runtime activation policy, not `Info.plist`

**Status:** Implemented (design note, not a bug).

**Summary:** A macOS app's Dock icon is controlled at runtime via `NSApp.setActivationPolicy(.accessory | .regular)`. `Info.plist`'s `LSUIElement` is static (baked in by `build.sh`) and cannot express "Dock only" (status item hidden). Hiding the menu-bar item is `NSStatusItem.isVisible`, owned by `StatusMenuController`.

**Context:** The user-selectable `system.iconMode` (Menu bar only / Menu bar + Dock / Dock only) needs two independent knobs. `.accessory` removes the Dock icon, `.regular` restores it; the status item is hidden with `statusItem.isVisible = false` (the controller keeps it as a stored property or it would vanish). `AppModel.applyIconMode()` sets the policy — dispatched to main, mirroring `applyAppearance()` — and is called from `init` (`AppModel.swift:126`) and `commitConfig()` (`:365`). `StatusMenuController.refresh()` sets `isVisible` from the observed `config` (`StatusMenuController.swift:161`; it already sinks `$config`), so the two sides stay decoupled. New `SystemSettings` fields must be added to `CodingKeys` with `decodeIfPresent(...) ?? default` in the custom `init(from:)`/`encode(to:)`, or older `config.json` files fail whole-file decode.

**Related:** `Sources/Config/ConfigModels.swift` (`AppIconMode`, `SystemSettings`), `Sources/AppModel.swift` (`applyIconMode`), `Sources/UI/StatusMenuController.swift` (`refresh`), `Sources/UI/SettingsView.swift` (`AppIconModePicker`), `build.sh` (`LSUIElement`).

## Suppress SIGPIPE on every socket

**Status:** Fixed.

**Summary:** macOS has no `MSG_NOSIGNAL`; a `send()` to a peer that sent RST raises `SIGPIPE`, whose default disposition terminates the process (exit `141`). `Socket.setNoSIGPIPE` (`Sources/Socks/Socket.swift:11-14`) sets `SO_NOSIGPIPE`, and it is called on every fd the app creates or accepts: the listener (`Sources/Proxy/ProxyServer.swift:65`), each accepted client (`:130`), and every `Socket.connect` result (`Sources/Socks/Socket.swift:58`).

**Context:** A browser closing a tab, a probe that RSTs after `CONNECT`, or any dead-peer scenario previously killed the app. The regression is `Tests/CrashProbes/sigpipe_send` (must survive an RST peer) plus `Tests/ProxyE2E`'s RST-burst stage (the proxy must still serve). Canonical: [`AGENTS.md`](AGENTS.md) lesson 11.

**Related:** `Sources/Socks/Socket.swift`, `Sources/Proxy/ProxyServer.swift`, `Tests/CrashProbes/sigpipe_send/main.swift`.

## Parse ports with the failable `UInt16(exactly:)`

**Status:** Fixed.

**Summary:** `URL(string:).port` returns an `Int` and does **not** reject ports > 65535, so the non-failable `UInt16(p)` traps and kills the process (exit `133`/SIGTRAP). `HTTPRequest.port` now uses `UInt16(exactly: p)` and falls back to the default port (`Sources/Proxy/HTTPParser.swift:70`); the other conversions in the same file (`:33`, `:43`) were already failable `UInt16(Substring)`.

**Context:** A single `GET http://host:99999/ HTTP/1.1` used to trigger the trap. Regression: `Tests/CrashProbes/oversized_port`. This is the same class as the already-fixed `Dictionary(uniqueKeysWithValues:)` header trap.

**Related:** `Sources/Proxy/HTTPParser.swift`, `Tests/CrashProbes/oversized_port/main.swift`.

## `networksetup -getautoproxyurl` prints `URL: (null)`

**Status:** Fixed.

**Summary:** When no PAC is configured, `networksetup -getautoproxyurl <svc>` prints `URL: (null)`. `ServiceProxyState.normalizePAC` (`Sources/System/HelperProtocol.swift:18-22`) now maps `(null)`/`(nil)`/`null`/empty to `""` at capture time (`Sources/System/SystemProxyManager.swift:42`) and on decode, and `restore` validates PAC URLs per-field (`HelperProtocol.swift:147-149`) instead of dropping the whole service. `isValidService` also allows `/`, so real services like `USB 10/100/1000 LAN` survive (`:170-174`). An empty restore command list is reported as failure rather than success (`Sources/Helper/HelperService.swift:42-45`), so the app never clears its recovery state while the proxy stays dangling.

**Context:** The original bug stored the literal `(null)`, which `isValid` rejected, dropping the entire service from restore while reporting success — leaving the system proxy dangling and then clearing the snapshot + disarming the watchdog. Canonical: [`AGENTS.md`](AGENTS.md) lesson 14.

**Related:** `Sources/System/SystemProxyManager.swift:39-44`, `Sources/System/HelperProtocol.swift`, `Sources/Helper/HelperService.swift:30-48`, `skills/system-proxy-safety-testing/references/dangling-proxy-audit.md`.

## Decode config tolerantly so upgrades don't wipe it

**Status:** Fixed.

**Summary:** Synthesized `Codable` throws `keyNotFound` for a missing key even when the property has a default, so adding a field would make every existing `config.json` fail whole-file decode; `ConfigStore.load` backs it up to `.corrupt` and `ConfigStore.init` writes fresh defaults, silently losing the target allow-list and settings (and since defaults are `[]`, traffic then goes direct in the clear). Every config struct now has a hand-written `init(from:)` using `decodeIfPresent(...) ?? default`: `AppConfig`, `ProxySettings`, `PolicySettings`, `MonitorSettings`, `LockSettings`, `ManagedTunnelSettings`, `TargetRule`, plus `TunnelSettings` and `SystemSettings` (`Sources/Config/ConfigModels.swift`).

**Context:** `Tests/RegressionHarness` asserts a legacy config (missing `policy`/`monitor`/`lock`) and a future config (unknown keys) both decode. Canonical: [`AGENTS.md`](AGENTS.md) lesson 13.

**Related:** `Sources/Config/ConfigModels.swift`, `Sources/Config/ConfigStore.swift:39-52`, `Tests/RegressionHarness/main.swift`.

## Bind telemetry text with `SQLITE_TRANSIENT`

**Status:** Fixed.

**Summary:** `bindText` and the inline `minute_stats` bind now pass `SQLITE_TRANSIENT` (`Sources/Telemetry/TelemetryStore.swift:7`, `:454`, `:463-465`), so SQLite copies the string before the temporary bridged `NSString` is released. The old `nil` destructor was `SQLITE_STATIC`, which stored a raw pointer into that temporary and produced a use-after-free (garbled host/path/route/error values or a crash) on every `insertBatch`/`upsertMinuteStats`.

**Context:** `insertBatch` now also checks the `sqlite3_step` and `COMMIT` return codes (`:429-435`); the `upsertMinuteStats` step (`:458`) is still unchecked.

**Related:** `Sources/Telemetry/TelemetryStore.swift`.

## Keep ssh errors visible in `SSHTunnelRunner`

**Status:** Fixed.

**Summary:** The runner passes `-o LogLevel=ERROR` instead of `-q` (`Sources/Tunnel/SSHTunnelRunner.swift:223`), so stderr carries real diagnostics and `isFatal` (`:181-199`) can match auth failures, bad keys, host-key changes, and DNS failures. `address already in use` / `bind: ` are in the fatal set (`:194`, `:196`), so a stale SOCKS port is no longer retried forever. A child left by a crash/force-quit is reaped on next launch via a pid file (`killStaleProcess`, `:311-321`).

**Context:** With `-q`, stderr was always empty, every failure was treated as transient, and the backoff retried auth failures on the 1→2→4…→60 s schedule forever (account-lockout risk) while the UI only ever showed `ssh exited with code 255`. The password is written 0600 into a per-run temp dir and the askpass helper deletes it after the single prompt (`:259-280`); the dir is removed on stop/exit.

**Related:** `Sources/Tunnel/SSHTunnelRunner.swift`, `docs/tunnel-supervisor.md`.

## Re-apply the proxy after sleep/wake and network changes

**Status:** Fixed.

**Summary:** `AppModel.observeSystemEvents()` (`Sources/AppModel.swift:156-167`) observes `NSWorkspace.didWakeNotification` and runs an `NWPathMonitor`; on either event `reapplyAfterSystemChange` (`:169-195`) restarts the listener if it stopped, re-arms the watchdog, and re-applies the proxy to the current service list. It only acts while `state.isActive`.

**Context:** New network services otherwise bypass the proxy (a routing/privacy leak) while the UI says ON, and a dead listener would leave the system proxy pointing at a dead local port with no detection.

**Related:** `Sources/AppModel.swift`, `Sources/Tunnel/TunnelSupervisor.swift`, `docs/roadmap.md`.

## Hold a `ProcessInfo.beginActivity` assertion while routing

**Status:** Fixed.

**Summary:** `AppModel.beginProxyActivity()` (`Sources/AppModel.swift:198-205`) holds `ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .suddenTerminationDisabled, .automaticTerminationDisabled], reason: "Proxy routing is enabled")` while routing is active; `endProxyActivity()` (`:207-213`) releases it. Called from `enable()` (`:228`) and on disable/rollback (`:304`, `:345`).

**Context:** Without the assertion, App Nap could throttle or suspend the process while it was not user-visible — the normal state of a menu-bar proxy — so the system proxy still pointed at `127.0.0.1:<port>` while the relay and timers stalled. `.userInitiatedAllowingIdleSystemSleep` prevents App Nap while still allowing the system to sleep; the termination options guard against macOS reclaiming the hidden app.

**Testing note:** App Nap cannot be forced via a public API. Verify manually: enable routing, hide the app and leave it idle a few minutes, then confirm with Activity Monitor's "App Nap" column / `powermetrics --samplers tasks` that the process is not napping, and that `log stream --predicate 'subsystem == "com.proxymanager.app"'` still shows flusher/probe activity.

**Related:** `Sources/Telemetry/TelemetryStore.swift`, `Sources/Tunnel/TunnelSupervisor.swift`, `Sources/AppModel.swift`.

## Standalone Swift harness gotchas

**Status:** Durable workflow note (not a bug).

**Summary:** The repo has no Xcode/SPM tests; harnesses are `swiftc`-compiled `main.swift` programs. Five gotchas cost real time: top-level code must be in `main.swift`; you must pass the exact `Sources/*.swift` file list; mock servers/load must use `Thread.detachNewThread` (not `DispatchQueue.global`, which caps ~64 blocking threads); harnesses that can crash must call `setbuf(stdout, nil)` or a signal-killed process loses all buffered output; and crash probes must run as subprocesses with signal exits (`133`=SIGTRAP, `141`=SIGPIPE) treated as failures.

**Context:** `Tests/run-all.sh` is the driver and encodes the file lists. `Tests/ProxyE2E` includes the RST-burst stage that now passes as the SIGPIPE regression (it used to die with exit 141). See the project skill `skills/standalone-swift-regression-harness` for the full workflow and helper snippets.

**Related:** `Tests/run-all.sh`, `Tests/RegressionHarness/main.swift`, `Tests/ProxyE2E/main.swift`, `docs/testing.md`.
