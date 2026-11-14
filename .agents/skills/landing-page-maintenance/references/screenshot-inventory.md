# Screenshot inventory

Every PNG in `gh-pages/assets/` is produced by the demo build. Filenames follow
`<key>-<appearance>.png`; the page swaps appearance automatically with
`<picture>` + `prefers-color-scheme`, so both variants must always exist.

| Key | `PROXYMANAGER_SCREEN` | What it shows | Native size (px) | Used on the page |
|---|---|---|---|---|
| `general` | `settings-general` | Settings → General: the Routing master switch and the Internet status with its monitor toggle, both on | 1800×1280 | Screenshots → “The master switch” |
| `dashboard` | `dashboard` | Dashboard: routing status, range-scoped stats, connections chart, top tunneled hosts, feed with Connect/Open/Result | 2240×1496 | Hero image |
| `dashboard-detail` | `dashboard-detail` | Dashboard with a request selected and the detail inspector open (captured at 720 pt; the live window is taller) | 2240×1496 | Screenshots → “Per-request detail” |
| `dashboard-targets` | `dashboard` + `PROXYMANAGER_RANGE=24h PROXYMANAGER_TOP=targets` | Dashboard at 24 h with the Targets tab: per-target traffic, last seen, app-rule tunnels, coverage warning | 2240×1496 | Screenshots → “Which targets actually carried traffic” |
| `targets` | `settings-targets` | Settings → Targets: rule list, wildcard, disabled rule, match preview | 1800×1280 | Screenshots → “Your allow-list, editable live” |
| `apps` | `settings-apps` | Settings → Apps: per-app rules (Chrome/Safari/Slack/node) with the routing detail pane open | 1800×1280 | Screenshots → “Route by app” |
| `integration` | `settings-integration` | Settings → Integration: the master switch on, per-adapter toggles, agent/socket status, and two approved apps | 1800×1280 | Screenshots → “Control it from anywhere” |
| `tunnel` | `settings-tunnel` | Settings → Tunnel: manual SOCKS5 config, healthy status, supervision | 1800×1280 | Screenshots → “Bring your own tunnel” |
| `tunnel-managed` | `settings-tunnel-managed` | Settings → Tunnel in “Run the tunnel for me” (SSH) mode, running | 1800×1280 | Managed-tunnel spotlight |
| `onboarding` | `onboarding` | First-run wizard, "Choose what to route" (presets) | 1240×976 | Screenshots → “Set up in about a minute” |

Appearances: `dark`, `light` → 10 screens × 2 = **20 files**.

Two more demo screens exist for ad-hoc capture (not part of the site set, so not
in `SCREENS`): `settings-about` (Settings → About) and `about-panel` (the
standard About panel).

## Fake data used

Seeded by `Sources/Support/DemoMode.swift` (deterministic RNG, fixed seed):

- **Targets:** DeepSeek, OpenAI, Anthropic, Gemini, GitHub, NVIDIA and
  `opencode.ai` (enabled; exact, so the Targets panel can show its wildcard
  warning) plus WhatsApp (disabled) — a realistic mixed allow-list.
- **Apps:** per-app routing on, default *Use target rules*, with Chrome → Tunnel
  all, Safari → Use target rules, Slack → Direct all, node → Direct all. Seeded
  requests carry the originating app so the dashboard App column, app filter, and
  Top apps breakdown are populated.
- **Requests:** ~140 over the last 5 minutes plus a working-day rhythm across
  seven days (~1.6k total), across tunneled (`api.deepseek.com`,
  `api.openai.com`, `api.anthropic.com`, `github.com`, `g.whatsapp.net`, …),
  direct (`cdn.jsdelivr.net`, `registry.npmjs.org`, `swift.org`, …), and blocked
  (`metrics.vendor.example`) hosts, plus 4 in-progress connections.
- **Stats:** the strip is range-scoped, so it is computed from the seeded events
  (5 m) or from SQLite (1 h/24 h/7 d); `Active` is the 4 live connections.
- **Config:** manual tunnel at `127.0.0.1:1080`, supervised, watchdog off, shell
  env off — so nothing real is ever touched. The app state is forced to `on` with
  the tunnel marked up, so the General screen's Routing switch reads **On** with a
  green status. The `tunnel-managed` screen instead seeds MANAGED SSH mode
  (`bastion.example.com`, key auth) and marks SSH as running; no SSH process is
  ever spawned.

## Adding or changing a screen

1. Add the case in `Sources/Support/DemoMode.swift` → `present(_:)` (and, if the
   view needs initial state, a guarded hook like `DashboardView.onAppear`, or one
   of the `PROXYMANAGER_*` env knobs).
2. Add an entry to `SCREENS` in `scripts/capture-screenshots.sh`; the third
   field is extra `env` for that screen (`dashboard-targets` uses it).
3. Add a row to the table above and reference the new images in `index.html`.
4. Re-run `build-demo.sh` and `capture-screenshots.sh`.
