# Screenshot inventory

Every PNG in `gh-pages/assets/` is produced by the demo build. Filenames follow
`<key>-<appearance>.png`; the page swaps appearance automatically with
`<picture>` + `prefers-color-scheme`, so both variants must always exist.

| Key | `PROXYMANAGER_SCREEN` | What it shows | Native size (px) | Used on the page |
|---|---|---|---|---|
| `dashboard` | `dashboard` | Dashboard: stats strip, request-rate chart, top tunneled hosts, live feed | 2240×1496 | Hero image |
| `dashboard-detail` | `dashboard-detail` | Dashboard with a request selected and the detail inspector open | 2240×1496 | Screenshots → “Per-request detail” |
| `targets` | `settings-targets` | Settings → Targets: rule list, wildcard, disabled rule, match preview | 1800×1280 | Screenshots → “Your allow-list, editable live” |
| `tunnel` | `settings-tunnel` | Settings → Tunnel: manual SOCKS5 config, healthy status, supervision | 1800×1280 | Screenshots → “Bring your own tunnel” |
| `tunnel-managed` | `settings-tunnel-managed` | Settings → Tunnel in “Run the tunnel for me” (SSH) mode, running | 1800×1280 | Managed-tunnel spotlight |
| `onboarding` | `onboarding` | First-run wizard, step 2 (choose targets from presets) | 1240×920 | Screenshots → “Set up in about a minute” |

Appearances: `dark`, `light` → 6 screens × 2 = **12 files**.

## Fake data used

Seeded by `Sources/Support/DemoMode.swift` (deterministic RNG, fixed seed):

- **Targets:** DeepSeek, OpenAI, Anthropic, Gemini, GitHub, NVIDIA (enabled) and
  WhatsApp (disabled) — a realistic mixed allow-list.
- **Requests:** ~260 completed over the last 5 minutes across tunneled
  (`api.deepseek.com`, `api.openai.com`, `api.anthropic.com`, `github.com`, …),
  direct (`cdn.jsdelivr.net`, `registry.npmjs.org`, `swift.org`, …), and blocked
  (`metrics.vendor.example`) hosts, plus 4 in-progress connections.
- **Stats:** Tunneled / Direct / Blocked counts, total bytes, and Active count
  are derived from the seeded events.
- **Config:** manual tunnel at `127.0.0.1:1080`, supervised, watchdog off, shell
  env off — so nothing real is ever touched. The `tunnel-managed` screen instead
  seeds MANAGED SSH mode (`bastion.example.com`, key auth) and marks SSH as
  running; no SSH process is ever spawned.

## Adding or changing a screen

1. Add the case in `Sources/Support/DemoMode.swift` → `present(_:)` (and, if the
   view needs initial state, a guarded hook like `DashboardView.onAppear`).
2. Add an entry to `SCREENS` in `scripts/capture-screenshots.sh`.
3. Add a row to the table above and reference the new images in `index.html`.
4. Re-run `build-demo.sh` and `capture-screenshots.sh`.
