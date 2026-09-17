---
name: landing-page-maintenance
description: Refresh the ProxyManager landing page (screenshots and copy) whenever the app's UI, features, or configuration change. Use this whenever you change anything under Sources/UI/ or Sources/Config/, add or rename a feature, change settings sections, onboarding steps, presets, or the target list UI, or when asked to update the website, the landing page, the gh-pages site, product screenshots, or marketing copy. Also use when the screenshots look stale or a new screen should be shown on the site.
---

# Landing-page maintenance (ProxyManager)

The public site lives on an **orphan `gh-pages` branch** — it shares no history
or tree with `main`. The page is hand-written HTML/CSS (no build step), and every
screenshot is captured from the real app running in a sandboxed **demo mode**
with generated fake data.

- Site (gh-pages): `index.html`, `styles.css`, `assets/*` — served at
  <https://chaim-chv.github.io/proxy-manager/>.
- Demo mode (main): `Sources/Support/DemoMode.swift`, compiled only with
  `-D SCREENSHOT_MODE`.
- Tooling (main): this skill's `scripts/`.

## Golden rules (do not break these)

1. **The demo never touches the real machine.** It uses a sandboxed support dir,
   skips the system proxy, shell env, Keychain, watchdog, and auto-enable, and is
   **SIGKILLed** (never SIGTERM) between shots so no terminate handler runs. See
   `Sources/Support/DemoMode.swift` and the `#if SCREENSHOT_MODE` guards in
   `AppModel.swift` / `ConfigStore.swift` / `DashboardWindowController.swift`.
2. **Never capture against the real app or real data.** Only the
   `-D SCREENSHOT_MODE` build with `PROXYMANAGER_DEMO=1`.
3. **`gh-pages` stays isolated.** Edit it only through a `git worktree`; never
   merge `main` into it and never commit the site onto `main`.
4. **Keep assets committed.** Both the page source and the PNGs live on
   `gh-pages`; the demo mode and this skill live on `main`.

## Workflow A — refresh the screenshots (after a UI change)

```bash
# 1. Build the demo app (compiles -D SCREENSHOT_MODE into /tmp/pm-demo)
.agents/skills/landing-page-maintenance/scripts/build-demo.sh

# 2. Capture every screen in both appearances (needs Screen Recording permission
#    for your terminal; requires a real display)
.agents/skills/landing-page-maintenance/scripts/capture-screenshots.sh /tmp/shots

# 3. Look at the PNGs (both dark and light). Confirm the fake data looks right
#    and no window is blank/clipped.

# 4. Publish them to gh-pages (copies + commits; does NOT push)
.agents/skills/landing-page-maintenance/scripts/publish-screenshots.sh /tmp/shots
```

To preview and verify before committing, serve the worktree locally and check
that every image loads in both color schemes:

```bash
git worktree add /tmp/pm-pages gh-pages
python3 -m http.server 8765 --directory /tmp/pm-pages
# open http://localhost:8765/ , toggle System Settings → Appearance
```

## Workflow B — update the copy after a feature change

The page copy must match the shipped app. Read the change, then update the
relevant section in the `gh-pages` worktree's `index.html`:

| What changed | Where on the page | Source of truth |
|---|---|---|
| A feature's behavior | Features grid / screenshot caption | `README.md`, `PLAN.md`, `docs/` |
| Settings sections or labels | Screenshots + captions | `Sources/UI/SettingsView.swift` (`SettingsSection`) |
| Onboarding steps or presets | Onboarding screenshot + caption | `Sources/UI/OnboardingView.swift`, `Sources/Config/Presets.swift` |
| Target rules / wildcards | Targets screenshot + caption | `Sources/Config/ConfigModels.swift` |
| Tunnel modes (manual/managed) | Tunnel screenshot + caption | `Sources/Config/ConfigModels.swift` (`TunnelMode`) |
| Version, requirements, install | Hero meta + final CTA | `build.sh` (`MIN_MACOS`), `README.md` |

Rules for copy:
- Keep it factual and plain; no hype, no emoji, no "AI" filler. Match the tone of
  `README.md`.
- The accent color is the app's green; keep it the only accent.
- The logo is a **placeholder** (`assets/mark.svg`, `assets/favicon.svg`). When a
  real app icon exists, replace these two files and update the `<img>`s in
  `index.html` (header, footer) — nothing else references the mark.
- Download buttons point at `.../releases/latest`; never hard-code a version.

## Workflow C — publish

```bash
# Commit on the branch you're editing:
#   gh-pages worktree → page + assets
#   main              → demo mode + skill
# Then push:
git push origin gh-pages
git push origin main
```

GitHub Pages is configured to deploy from the `gh-pages` branch (root). The
`.nojekyll` file disables Jekyll processing. If Pages ever reports "not
published", re-enable it in the repo's Settings → Pages → "Deploy from a branch"
→ `gh-pages` / `/ (root)`.

## How demo mode works

`DemoMode.bootstrap()` (before `NSApplication` starts) redirects the support dir
to `/tmp/proxymanager-demo/support`, writes a seeded `config.json`, and picks the
appearance. `DemoMode.apply(to:)` (end of `AppModel.init`) seeds ~260 fake
requests, 4 live connections, and the stats, then opens the requested window.
Environment variables (set by `capture-screenshots.sh`):

| Variable | Values | Meaning |
|---|---|---|
| `PROXYMANAGER_DEMO` | `1` | enable demo mode (required) |
| `PROXYMANAGER_SCREEN` | `dashboard`, `dashboard-detail`, `settings-tunnel`, `settings-targets`, `onboarding` | which window to show |
| `PROXYMANAGER_APPEARANCE` | `dark`, `light` | forced app appearance |
| `PROXYMANAGER_ONBOARDING_STEP` | `0`–`3` | onboarding step to show (default `2`) |
| `PROXYMANAGER_SUPPORT_DIR` | path | sandbox for `WatchdogPaths` (set by the script) |
| `PROXYMANAGER_LAUNCHAGENTS_DIR` | path | sandbox for the watchdog plist (set by the script) |

**Adding a screen:** add a `case` in `DemoMode.present(_:)` and a matching entry
to `SCREENS` in `capture-screenshots.sh`, then add a row to
[`references/screenshot-inventory.md`](references/screenshot-inventory.md).

## Verification checklist

- [ ] `./build.sh 1.0.0` still succeeds (shipping build; demo code compiled out).
- [ ] `./Tests/run-all.sh` passes.
- [ ] `./build.sh` produces a binary that does **not** define `SCREENSHOT_MODE`
      (grep `DemoMode` usage is guarded; `isEnabled` is the `false` shim).
- [ ] Every screenshot in both appearances shows the intended screen and fake
      data (no empty feed, no "No data yet", tunnel status is "Tunnel is up").
- [ ] All images load on the page in both light and dark (`document.images`
      all have `naturalWidth > 0`).
- [ ] No broken links: GitHub, Releases, Issues, License.
- [ ] `git status` on `main` shows only intended files; `gh-pages` has only site
      files (no `Sources/`, no `README.md`).

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `window-id: no window for pid …` | The demo crashed or never showed a window. Run the binary directly with the env vars and read stderr. |
| Screenshot is black/empty | Terminal lacks **Screen Recording** permission (System Settings → Privacy & Security). |
| Tunnel screen says "Tunnel is down" | `model.tunnelUp` was overwritten by the supervisor's initial emission; `DemoMode.apply` sets it on the next main-queue turn — rebuild. |
| `build-demo.sh` fails with `Sparkle.framework not found` | Run from the repo root (the script `cd`s there) or set `SPARKLE_DIR`. |
| Page renders unstyled | `styles.css` wasn't copied into the worktree; check `git -C <worktree> status`. |
| Real ProxyManager state changed after capturing | A demo build without the `#if SCREENSHOT_MODE` guards ran; stop and audit `AppModel.shutdownForQuit` / `syncManagedTunnel`. |
