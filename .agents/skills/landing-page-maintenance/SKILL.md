---
name: landing-page-maintenance
description: Refresh the ProxyManager landing page (screenshots and copy) whenever the app's UI, features, or configuration change. Use this whenever you change anything under Sources/UI/ or Sources/Config/, add or rename a feature, change settings sections, onboarding steps, presets, or the target list UI, or when asked to update the website, the landing page, the gh-pages site, product screenshots, or marketing copy. Also use when the screenshots look stale or a new screen should be shown on the site.
---

# Landing-page maintenance (ProxyManager)

The public site lives on an **orphan `gh-pages` branch** — it shares no history
or tree with `main`. The pages are hand-written HTML/CSS (no build step), and
every screenshot is captured from the real app running in a sandboxed **demo
mode** with generated fake data.

- Site (gh-pages): `index.html`, `privacy.html`, `support.html`, `styles.css`,
  `app.js`, `assets/*` — served at
  <https://chaim-chv.github.io/proxy-manager/>.
- **Multi-page, no templating.** `privacy.html` and `support.html` each carry a
  hand-copied header/footer. When you change the header, footer, or support band
  on `index.html`, apply the same change to the other two (only the nav/brand
  hrefs differ: subpages point at `index.html#…`).
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

## Page implementation notes (gh-pages)

- `index.html` — landing markup. `privacy.html` and `support.html` are the
  policy and help pages; both reuse `styles.css` (`.page-head`, `.prose`).
  Screenshots use `<picture>` + `prefers-color-scheme`
  for the no-JS case; each `<img>` also carries `data-dark`/`data-light` so
  `app.js` can honor a manual theme.
- `styles.css` — all styling. Theme is driven by `data-theme` on `<html>` with
  `prefers-color-scheme` as the default. Keep the single accent (green).
- `app.js` — four small, dependency-free behaviors:
  1. **Theme switch** (`system → light → dark`, persisted in `localStorage`
     under `pm-theme`).
  2. **Download** — fetches `releases/latest` (cached 1h in `sessionStorage`),
     sets every `[data-dl-main]` to the `.zip` asset, fills `[data-dl-version]`
     with the tag, and points `[data-dl-notes]` at the release page. Falls back
     to `/releases/latest` if the API fails.
  3. **Cursor tilt** — a max-1° 3D tilt on `[data-tilt]` elements, disabled
     under `prefers-reduced-motion`.
  4. **Star count** — fetches `stargazers_count` from the repo API (cached 1 h
     in `sessionStorage` under `pm-stars`) and fills `[data-star-count]` in the
     pre-footer support band; the number stays hidden if the fetch fails.
- The **support band** (`.support-band`) sits between `</main>` and the footer:
  one sentence plus `Star on GitHub` (with the live count) and `Report an issue`.
  It is on `index.html` only, not the content pages.
- The **GitHub corner ribbon** is `.github-corner`: `position: fixed` at the
  top-right, above the sticky header (`z-index: 50`), with the octocat waving on
  hover. The header reserves space via a `min-width: 721px` rule so its controls
  never collide. Below 720px the ribbon is hidden and the navbar `.github-icon`
  is shown instead — keep the two in sync if you change the repo URL.
- The **footer** has four labeled columns (brand/tagline, Product, Source,
  Privacy & help), a version filled from the release fetch (`data-dl-version`),
  and a legal line. Keep the three pages' footers identical apart from the
  Product anchors (`index.html#…` on subpages).
- The **managed-tunnel spotlight** (`#managed`) is the prominent “Run the tunnel
  for me” section — keep its screenshot current; it is a headline feature.
- The **Under the hood** block lives at the end of the `#how` section and states
  mechanisms (raw sockets, backpressure, 256 KB buffers, off-hot-path telemetry,
  watchdog, loopback/SSRF guard) — keep it factual and in sync with `docs/`.
- **No separate features grid.** Capability claims live in the screenshot
  captions, the “How it works” flow/steps, and the Under the hood block. Do not
  re-add a standalone grid — it duplicated all three and was removed on purpose.
- **ALPHA + live dot.** `.brand-alpha` is a small tilted, dashed-border “ALPHA”
  patch on the wordmark (muted, not accent) on all pages. The pulsing
  `.status-dot` lives only in the footer `.version-pill` beside the brand,
  revealed by `app.js` (`data-version-pill`) once the release resolves. Do not
  add a navbar/hero pill — it looked like a second CTA next to Download.

## Workflow B — update the copy after a feature change

The page copy must match the shipped app. Read the change, then update the
relevant section in the `gh-pages` worktree (`index.html`, and `privacy.html` /
`support.html` where the change touches privacy, support, or the shared footer):

| What changed | Where on the page | Source of truth |
|---|---|---|
| A feature's behavior | Screenshot caption / How it works / Under the hood | `README.md`, `PLAN.md`, `docs/` |
| Settings sections or labels | Screenshots + captions | `Sources/UI/SettingsView.swift` (`SettingsSection`) |
| Onboarding steps or presets | Onboarding screenshot + caption | `Sources/UI/OnboardingView.swift`, `Sources/Config/Presets.swift` |
| Target rules / wildcards | Targets screenshot + caption | `Sources/Config/ConfigModels.swift` |
| Tunnel modes (manual/managed) | Tunnel screenshot + caption | `Sources/Config/ConfigModels.swift` (`TunnelMode`) |
| Version, requirements, install | Hero meta + final CTA | `build.sh` (`MIN_MACOS`), `README.md` |
| Privacy behavior (telemetry, Keychain, shell env, watchdog, Sparkle) | `privacy.html` | `README.md`, `docs/telemetry.md`, `docs/updates.md`, `docs/system-integration.md` |
| Support channels / install help | `support.html` | `CONTRIBUTING.md`, `README.md` |

Rules for copy:
- Keep it factual and plain; no hype, no emoji, no "AI" filler. Match the tone of
  `README.md`.
- The accent color is the app's green; keep it the only accent.
- The logo is a **placeholder** (`assets/mark.svg`, `assets/favicon.svg`). When a
  real app icon exists, replace these two files and update the `<img>`s in the
  header/footer of all three pages — nothing else references the mark.
- Download buttons point at `.../releases/latest`; never hard-code a version.
- The privacy policy must stay honest about the one outbound call (the Sparkle
  appcast) and the browser storage `app.js` uses (`pm-theme`, `pm-release`,
  `pm-stars`).

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
| `PROXYMANAGER_SCREEN` | `dashboard`, `dashboard-detail`, `settings-tunnel`, `settings-tunnel-managed`, `settings-targets`, `onboarding` | which window to show |
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
- [ ] Theme switch cycles system → light → dark and swaps the screenshots.
- [ ] The download button shows the current version and links to the `.zip`
      asset (not just `/releases/latest`); the dropdown opens and closes.
- [ ] The support band shows the live star count (or hides it gracefully) and
      both buttons work; it does **not** appear on the hero.
- [ ] `privacy.html` and `support.html` render with the shared header/footer,
      the header nav/anchors resolve to `index.html#…`, and the theme toggle
      works on all three pages.
- [ ] No broken links: GitHub, Releases, Issues, Contributing, License, Privacy,
      Support, Build from source.
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
