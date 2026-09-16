# UI — SwiftUI menu bar, dashboard, settings, targets, onboarding

`Sources/App.swift`, `Sources/UI/*.swift`

## App shell (`App.swift` + `StatusMenuController.swift`)

- `@main ProxyManagerApp` — regular app (not `LSUIElement`) with a single-instance Dashboard window and a `Settings` scene. A `@NSApplicationDelegateAdaptor` handles termination/reopen and installs the menu-bar menu. The icon placement is configurable (`system.iconMode`, default **Menu bar + Dock**): **Menu bar only** switches the activation policy to `.accessory` (no Dock icon), **Dock only** keeps `.regular` but hides the `NSStatusItem`, and **Menu bar + Dock** is both. `AppModel.applyIconMode()` owns the activation policy; `StatusMenuController` owns the status item's `isVisible` (it observes `config`).
- The menu bar item is a **native AppKit `NSStatusItem` + `NSMenu` (`StatusMenuController`)** — not a SwiftUI `MenuBarExtra`. A `.menu`-style SwiftUI extra cannot tint status rows or show native key equivalents. **Interactive rows are plain `NSMenuItem`s** (native hover highlight + native checkmark); only the inert status/error rows are custom views (for the colored dots):
  - Status indicators (inert, colored dots, custom `NSView` rows that swallow clicks): **Routing** On/Off/Degraded/Starting…/Stopping… and **Tunnel** Up/Down; a red wrapping error line when `lastError` is set.
  - **Routing** — a regular toggle item; its native `state` checkmark shows when active and it is disabled (grayed) during starting/stopping. Selecting it toggles routing and closes the menu (standard macOS menu behavior).
  - **Launch at Login** — a regular toggle item (`state` checkmark reflects `system.launchAtLogin`; calls `setLaunchAtLogin`).
  - **Restart Tunnel** (only while `config.tunnel.supervised`).
  - **Open Dashboard… ⌘D / Settings… ⌘, / About Proxy Manager / Check for Updates… / Quit Proxy Manager ⌘Q** — key equivalents are displayed on the items; while the app is active the real ⌘Q/⌘,/⌘D handling comes from the SwiftUI main menu (`Settings` scene + `AppCommands`, which also adds Toggle Routing ⌘L). The `Check for Updates…` item's enabled state tracks `UpdaterController.canCheckForUpdates`.
  - The status-item icon is an SF Symbol picked by state (circle / circle.fill / exclamationmark.triangle.fill / hourglass).
  - Menu items are updated **in place** from Combine sinks on the model (`state`, `tunnelUp`, `lastError`, `config`) so the menu reflects live state even while it is open — never rebuilt.
  - **Settings… must front/activate the window**: clicking a status-menu item does not activate the app, and `NSApp.sendAction(showSettingsWindow:)` is a no-op (SwiftUI wires Settings as a private `menuAction:` item). `openSettings()` activates the app then fires the real SwiftUI-generated **Settings… ⌘,** menu item it finds in the app menu.
  - The status item is **hidden when `system.iconMode == .dockOnly`** (`statusItem.isVisible` set in `refresh()`).
  - The status-item icon can be **colorized** (`system.colorizeMenuIcon`, Settings → Appearance → "Menu bar icon style": Classic / Colorized, default Colorized). When colorized, the symbol is **recolored with a `SymbolConfiguration` palette** (template tinting via `contentTintColor` does not work on status items) — green = on, amber = starting/stopping, orange = degraded, red = error, gray = off; when classic it is the monochrome template icon.

## Dashboard (`DashboardView.swift` + `DashboardWindowController.swift` + `FeedTable.swift`)

- `DashboardWindowController` owns a single `NSWindow` (hosting `DashboardView`); `show()` (re)creates it and activates the app. Dock-click (via `applicationShouldHandleReopen`), ⌘D, and the menu bar all funnel here.
- **Window frame persistence**: the window uses AppKit frame autosave (`setFrameAutosaveName("ProxyManagerDashboard")`). Size, position, and screen are stored in the app defaults on every move/resize and restored on reopen; a saved frame that would land off-screen (monitor unplugged) is constrained back onto a visible screen automatically. The frame is also flushed in `windowWillClose` and on quit (`AppDelegate.applicationWillTerminate`).
- Dashboard: header (enable/disable toggle, host filter, pause, clear), stat boxes (Tunneled / Direct / Blocked / Bytes / Active), a **request-activity chart** with a 5m/1h/24h/7d range picker and a Requests/Bytes/Errors metric picker (the 5m range buckets the in-memory feed at 30 s; longer ranges load from SQLite on a 2 s cadence), top tunneled hosts (in-memory for 5m, SQLite otherwise), and the request feed as a table with column headers (Time/Route/Method/Host/Status/Bytes/Duration/Error). The feed header also has a route filter (All / Tunneled / Direct / Blocked) and a live/completed count; selecting a row opens a metadata-only detail inspector (`RequestDetailView`).
- **Feed table is a view-based `NSTableView` (`FeedTable.swift`), not SwiftUI `Table`** — SwiftUI's `Table` has no API to persist user-adjusted column widths. `NSTableView`'s `autosaveName` + `autosaveTableColumns` is the macOS-native mechanism: divider drags are written to the defaults immediately and restored on the next launch. Cells mirror the previous SwiftUI look (caption text, monospaced digits, orange live dot, route chip, inset style + alternating row backgrounds). The last column absorbs window-width changes (`lastColumnOnlyAutoresizingStyle`).
- Rows are pushed into the table via `NSViewRepresentable`; on change it does a full `reloadData()` only when the rows' identity/order changes (new connection, finish, or filter), otherwise it refreshes just the on-screen rows (live durations/bytes tick at 10 Hz — no per-cell work off-screen).
- **Live connections**: rows appear in the feed the moment a connection is established (orange dot + orange duration) and move to the completed list when it closes — see `docs/telemetry.md`. Pause freezes a snapshot of the feed.
- `computeFeedRows()` materializes only the live list + `suffix(250)` of the completed feed, then filters/sorts to ≤250 rows.

## Settings (`SettingsView.swift`)

A sidebar layout — a fixed-width `List` (left) + `Divider` + detail pane (right) — driven by `SettingsSection` (order: **General / Appearance / Tunnel / Proxy / Targets / System / Monitoring / About**). Every page opens with a `SettingsPage` header (title + one-line description) so each tab is self-explanatory (Targets renders its own equivalent header). Help is a **`HelpPopover`** (`Sources/UI/HelpPopover.swift`, inline `?` → popover with explanation + optional `example`), used **sparingly** — only on genuinely non-obvious options (icon placement, tunnel host/port, SSH auth, fail-open/closed, terminal-app env, quit behavior, bulk target entry, wildcard matching); everything else uses short captions.

- **General** — launch at login, "Run setup again", reset all.
- **Appearance** — **icon placement** (three large selectable cards — Menu bar only / Menu bar + Dock / Dock only — each with a mini screen mock showing the icon's location), color mode (System / Light / Dark), and **menu bar icon style** (Classic / Colorized, with an inline color sample in each option; disabled while the menu bar icon is hidden).
- **Tunnel** — a mode `Picker` ("I manage the tunnel" / "Run the tunnel for me"):
  - *Manual*: SOCKS5 host/port, live "Test connection", supervised toggle + launchd job label, restart.
  - *Managed*: SSH host/port/username, auth (`KEY` path with a **Browse…** `NSOpenPanel` picker, or `PASSWORD` via Keychain `SecureField`), local SOCKS bind host/port, live status + start/restart.
- **Proxy** — bind host/port, fail-open/fail-closed policy.
- **Targets** — allow-list editor with a **bulk textarea** (enter many hosts at once, separated by line breaks, commas, or semicolons), **inline edit** (double-click a rule or click the pencil next to its toggle; Return saves, Esc cancels, clicking outside discards, ✓/✕ buttons), remove/toggle, a **Presets menu** (appends, skipping duplicates) with clear-all, and a live match preview.
- **System** — shell env injection, editable managed rc-file list, restore-on-quit, crash watchdog.
- **Monitoring** — retention days, record paths, purge history.
- **About** — the version and its build date, then a plain-language explainer with a flow diagram (apps → local proxy → allow-list decision → tunnel/direct), the key concepts, privacy notes, and credits.

## Onboarding (`OnboardingView.swift` + `OnboardingWindowController`)

A 4-step first-run walk-through: **Welcome** (plain-language explanation of HTTP proxy / SOCKS5 tunnel / routing) → **Tunnel** (short intro + "I already have a tunnel" / "Run the tunnel for me"; host/port + live "Test connection" or SSH host/port/username + auth + local SOCKS bind host/port) → **Targets** (pick a preset or start empty) → **Done** (enable now, launch at login, shell env). Writes config through the same `AppModel` paths as Settings. Shown on first launch (`AppDelegate.applicationDidFinishLaunching` when `AppModel.showOnboarding`); re-openable from Settings → General ("Run setup again" shows the window directly). Completion is stored in `UserDefaults` (`hasCompletedOnboarding`). **Dismissible** via Esc or the close button — dismissing marks onboarding as seen and opens Settings instead.

The **Targets step respects existing config**: if targets are already configured it defaults to "Keep my current list" (and only overwrites them if the user picks a preset or "Start empty").

## Targets (`TargetsView.swift`)

Add rules in bulk through a multi-line textarea (split on line breaks/commas/semicolons), edit a rule inline by double-clicking it or using the pencil next to its toggle (Return saves, Esc cancels, clicking outside discards), remove/toggle, apply a **Presets menu** (`TargetPreset`, appends and skips duplicates) or clear all, and check a live match-preview (`RoutingEngine.matchingRule`).

## Bindings

`AppModel.binding`/`portBinding` wrap config key-paths; writes go through `commitConfig()` (debounced). `portBinding` uses `UInt16(clamping:)` (see `docs/roadmap.md` — silent clamping).

## Formatting (`Format.swift`)

Cached static `DateFormatter`/`ByteCountFormatter` (main-thread only) — do **not** allocate a formatter per row.

## UI principles

- Telemetry publishes to the UI at 10 Hz (batched), not per request. Only the Dashboard observes `TelemetryStore` directly (`@EnvironmentObject var telemetry`). It is deliberately **not** bridged into `AppModel.objectWillChange`: `AppModel` is the environment object for every window, including the retained offscreen `Settings` scene window, so the bridge re-laid-out the entire view tree on every tick (10–20% CPU while idle). See `docs/telemetry.md` → Observation.
- `ForEach` identity must be unique — `RequestEvent.id` is a `UUID`.
- No retain cycles: window `delegate` is weak; controllers release their hosting views on close.
